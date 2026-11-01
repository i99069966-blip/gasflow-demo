import Foundation
import CoreGraphics

/// Real-time gas plume detector + source localisation.
///
/// Works on a small BGRA image (e.g. 144×256) that FrameDownsampler produces from every camera frame.
/// Pipeline per frame (identical to tools/gas_reference.py):
///   1. signal S = chosen channel, box-blurred twice
///   2. baseline: per-pixel mean μ and noise σ over N frames (Welford)
///   3. response  ΔS% = polarity · 100 · (S − μ) / μ, temporal EMA
///   4. active    ΔS% > max(minPercent, kσ · σ/μ·100) inside ROI and not saturated
///   5. arrival   time of the first confirmed activation of each pixel (arrival-time map)
///   6. source    E = centroid of the earliest 5 % arrivals, C = centroid of all arrivals,
///                direction = (E − C)/|E − C|, ray from E to the ROI edge = upstream source point.
///
/// Not thread-safe: call from a single queue.
final class GasAnalyzer {
    let width: Int
    let height: Int
    let count: Int

    private(set) var params: GasParams
    private(set) var roi: NormRect

    // Per-pixel buffers
    private let sig: UnsafeMutablePointer<Float>
    private let tmp: UnsafeMutablePointer<Float>
    private let mean: UnsafeMutablePointer<Float>
    private let m2: UnsafeMutablePointer<Float>
    private let thr: UnsafeMutablePointer<Float>
    private let resp: UnsafeMutablePointer<Float>
    private let arrival: UnsafeMutablePointer<Float>      // seconds since origin, −1 = not reached
    private let lastArrival: UnsafeMutablePointer<Float>  // snapshot of the previous event
    private let run: UnsafeMutablePointer<Int32>
    private let maxRGB: UnsafeMutablePointer<UInt8>
    private let minRGB: UnsafeMutablePointer<UInt8>
    private let saturationOK: UnsafeMutablePointer<UInt8>
    private let valid: UnsafeMutablePointer<UInt8>

    private var nBaseline = 0
    private(set) var ready = false
    private(set) var validCount = 0
    private var noiseMedian: Float = 0
    private var originTime: Double = 0

    private var order: [Int32] = []
    private var sumX: Double = 0
    private var sumY: Double = 0
    private var firstArrival: Double?
    private var quietSince: Double?
    private var currentSource: GasSource?
    private(set) var lastSource: GasSource?
    private var hasLastArrival = false

    init(width: Int, height: Int, params: GasParams, roi: NormRect) {
        self.width = width
        self.height = height
        self.count = width * height
        self.params = params
        self.roi = roi
        func f() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: width * height)
            p.initialize(repeating: 0, count: width * height)
            return p
        }
        func u() -> UnsafeMutablePointer<UInt8> {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
            p.initialize(repeating: 0, count: width * height)
            return p
        }
        sig = f(); tmp = f(); mean = f(); m2 = f(); thr = f(); resp = f()
        arrival = f(); lastArrival = f()
        run = UnsafeMutablePointer<Int32>.allocate(capacity: width * height)
        run.initialize(repeating: 0, count: width * height)
        maxRGB = u(); minRGB = u(); saturationOK = u(); valid = u()
        resetBaseline()
    }

    deinit {
        for p in [sig, tmp, mean, m2, thr, resp, arrival, lastArrival] { p.deallocate() }
        run.deallocate()
        for p in [maxRGB, minRGB, saturationOK, valid] { p.deallocate() }
    }

    // MARK: - Control

    func update(params newParams: GasParams) {
        let old = params
        params = newParams
        if newParams.requiresRebaseline(comparedTo: old) {
            resetBaseline()
        } else if ready && (newParams.kSigma != old.kSigma || newParams.minPercent != old.minPercent) {
            computeThresholds()
        }
    }

    func update(roi newROI: NormRect) {
        guard newROI != roi else { return }
        roi = newROI
        if ready {
            computeValidMask()
            resetArrivals(keepGhost: false)
        }
    }

    /// Start collecting a new reference image.
    func resetBaseline() {
        nBaseline = 0
        ready = false
        mean.update(repeating: 0, count: count)
        m2.update(repeating: 0, count: count)
        maxRGB.update(repeating: 0, count: count)
        minRGB.update(repeating: 255, count: count)
        resp.update(repeating: 0, count: count)
        lastSource = nil
        hasLastArrival = false
        resetArrivals(keepGhost: false)
    }

    /// Clear the arrival map but keep the baseline.
    func resetArrivals(keepGhost: Bool) {
        if keepGhost, let s = currentSource {
            lastSource = s
            lastArrival.update(from: arrival, count: count)
            hasLastArrival = true
        } else if !keepGhost {
            lastSource = nil
            hasLastArrival = false
        }
        arrival.update(repeating: -1, count: count)
        run.update(repeating: 0, count: count)
        order.removeAll(keepingCapacity: true)
        sumX = 0
        sumY = 0
        firstArrival = nil
        quietSince = nil
        currentSource = nil
    }

    // MARK: - Per frame

    func process(bgra: UnsafePointer<UInt8>, bytesPerRow: Int, time: Double) -> GasFrameResult {
        extractSignal(bgra: bgra, bytesPerRow: bytesPerRow)
        let r = max(0, params.blurRadius)
        if r > 0 {
            boxBlur(sig, r)
            boxBlur(sig, r)
        }

        var result = GasFrameResult()
        result.time = time

        if !ready {
            accumulateBaseline(bgra: bgra, bytesPerRow: bytesPerRow)
            if nBaseline >= params.baselineFrames {
                finishBaseline(time: time)
                result.phase = .monitoring
            } else {
                result.phase = .baseline(progress: Float(nBaseline) / Float(max(1, params.baselineFrames)))
            }
            result.validPixels = validCount
            return result
        }

        let t = Float(time - originTime)
        let a = params.emaAlpha
        let b = 1 - a
        let confirm = Int32(max(1, params.confirmFrames))
        let track = params.baselineTracking
        let beta: Float = 0.002
        var sum: Float = 0
        var maxV: Float = -Float.greatestFiniteMagnitude
        var maxIdx = -1
        var activeN = 0

        for i in 0..<count {
            if valid[i] == 0 {
                resp[i] = 0
                continue
            }
            let mu = max(mean[i], 1e-3)
            var v = 100 * (sig[i] - mean[i]) / mu
            switch params.polarity {
            case .decrease: v = -v
            case .increase: break
            case .both: v = abs(v)
            }
            let e = a * v + b * resp[i]
            resp[i] = e
            sum += e
            if e > maxV { maxV = e; maxIdx = i }
            if e > thr[i] {
                activeN += 1
                run[i] += 1
                if run[i] == confirm && arrival[i] < 0 {
                    arrival[i] = t
                    order.append(Int32(i))
                    sumX += Double(i % width) + 0.5
                    sumY += Double(i / width) + 0.5
                    if firstArrival == nil { firstArrival = Double(t) }
                }
            } else {
                run[i] = 0
                if track && e < 0.5 * thr[i] {
                    mean[i] += beta * (sig[i] - mean[i])
                }
            }
        }

        let vc = max(1, validCount)
        result.meanResponse = sum / Float(vc)
        result.maxResponse = maxIdx >= 0 ? maxV : 0
        result.activeFraction = Float(activeN) / Float(vc)
        result.validPixels = validCount
        result.noiseMedianPercent = noiseMedian
        if maxIdx >= 0 && maxV >= params.minPercent {
            result.hotspot = CGPoint(x: (Double(maxIdx % width) + 0.5) / Double(width),
                                     y: (Double(maxIdx / width) + 0.5) / Double(height))
        }

        currentSource = estimateSource()

        // Auto re-arm after the plume has gone.
        if !order.isEmpty && params.autoRearmSeconds > 0 {
            if result.activeFraction < 0.002 {
                if quietSince == nil { quietSince = time }
                if let q = quietSince, time - q >= params.autoRearmSeconds {
                    resetArrivals(keepGhost: true)
                }
            } else {
                quietSince = nil
            }
        }

        result.source = currentSource
        result.lastSource = lastSource
        result.phase = order.isEmpty ? .monitoring : .detected
        return result
    }

    // MARK: - Source estimate

    private func estimateSource() -> GasSource? {
        let n = order.count
        let need = max(20, Int(params.minArrivedFraction * Float(validCount)))
        guard n >= need, n > 0 else { return nil }

        // E: earliest 5 % (≥10 px). `order` is chronological, ties at the cut are included.
        let k = min(n, max(10, Int(0.05 * Double(n))))
        let tk = arrival[Int(order[k - 1])]
        var ex = 0.0, ey = 0.0, ne = 0.0
        for idx in order {
            let i = Int(idx)
            if arrival[i] > tk { break }
            ex += Double(i % width) + 0.5
            ey += Double(i / width) + 0.5
            ne += 1
        }
        ex /= ne
        ey /= ne

        // C: centroid of all reached pixels.
        let cx = sumX / Double(n)
        let cy = sumY / Double(n)
        let vx = ex - cx, vy = ey - cy
        let dist = (vx * vx + vy * vy).squareRoot()
        let plumeR = (Double(n) / Double.pi).squareRoot()
        let conf = Float(dist / max(plumeR, 1e-6))
        let dx = dist > 1e-6 ? vx / dist : 0
        let dy = dist > 1e-6 ? vy / dist : 0

        let mode: GasSource.Mode = conf >= params.directionConfMin ? .direction : .point
        var sx = ex, sy = ey
        if mode == .direction {
            // Extend the ray E + s·d to the ROI boundary.
            let bx0 = Double(roi.x0) * Double(width), bx1 = Double(roi.x1) * Double(width)
            let by0 = Double(roi.y0) * Double(height), by1 = Double(roi.y1) * Double(height)
            var hits: [Double] = []
            if dx > 1e-9 { hits.append((bx1 - ex) / dx) } else if dx < -1e-9 { hits.append((bx0 - ex) / dx) }
            if dy > 1e-9 { hits.append((by1 - ey) / dy) } else if dy < -1e-9 { hits.append((by0 - ey) / dy) }
            let s = max(0, hits.min() ?? 0)
            sx = ex + dx * s
            sy = ey + dy * s
        }

        let W = Double(width), H = Double(height)
        return GasSource(
            earliest: CGPoint(x: ex / W, y: ey / H),
            centroid: CGPoint(x: cx / W, y: cy / H),
            direction: CGVector(dx: dx, dy: dy),
            confidence: conf,
            sourcePoint: CGPoint(x: sx / W, y: sy / H),
            mode: mode,
            angleDeg: atan2(-dy, dx) * 180 / Double.pi,
            arrivedCount: n,
            firstArrival: firstArrival ?? 0)
    }

    // MARK: - Baseline

    private func accumulateBaseline(bgra: UnsafePointer<UInt8>, bytesPerRow: Int) {
        nBaseline += 1
        let n = Float(nBaseline)
        for y in 0..<height {
            let row = bgra + y * bytesPerRow
            for x in 0..<width {
                let i = y * width + x
                let s = sig[i]
                let d = s - mean[i]
                mean[i] += d / n
                m2[i] += d * (s - mean[i])
                let p = row + x * 4
                let hi = max(p[0], max(p[1], p[2]))
                let lo = min(p[0], min(p[1], p[2]))
                if hi > maxRGB[i] { maxRGB[i] = hi }
                if lo < minRGB[i] { minRGB[i] = lo }
            }
        }
    }

    private func finishBaseline(time: Double) {
        for i in 0..<count {
            saturationOK[i] = (maxRGB[i] < 250 && minRGB[i] > 8 && mean[i] > 5) ? 1 : 0
        }
        computeThresholds()
        computeValidMask()
        originTime = time
        ready = true
        resetArrivals(keepGhost: false)
    }

    private func computeThresholds() {
        let n = max(1, nBaseline - 1)
        var noise: [Float] = []
        noise.reserveCapacity(count / 4)
        for i in 0..<count {
            let mu = max(mean[i], 1e-3)
            let sigmaPct = 100 * (max(m2[i], 0) / Float(n)).squareRoot() / mu
            thr[i] = max(params.minPercent, params.kSigma * sigmaPct)
            if i % 4 == 0 { noise.append(sigmaPct) }
        }
        noise.sort()
        noiseMedian = noise.isEmpty ? 0 : noise[noise.count / 2]
    }

    private func computeValidMask() {
        let x0 = Double(roi.x0) * Double(width), x1 = Double(roi.x1) * Double(width)
        let y0 = Double(roi.y0) * Double(height), y1 = Double(roi.y1) * Double(height)
        var c = 0
        for y in 0..<height {
            let fy = Double(y)
            let inY = fy >= y0 && fy < y1
            for x in 0..<width {
                let i = y * width + x
                let fx = Double(x)
                let ok = inY && fx >= x0 && fx < x1 && saturationOK[i] != 0
                valid[i] = ok ? 1 : 0
                if ok { c += 1 }
            }
        }
        validCount = c
    }

    // MARK: - Signal

    private func extractSignal(bgra: UnsafePointer<UInt8>, bytesPerRow: Int) {
        let ch = params.channel
        for y in 0..<height {
            let row = bgra + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                let B = Float(p[0]), G = Float(p[1]), R = Float(p[2])
                let v: Float
                switch ch {
                case .red: v = R
                case .green: v = G
                case .blue: v = B
                case .luma: v = 0.2126 * R + 0.7152 * G + 0.0722 * B
                case .redChroma: v = 100 * R / max(R + G + B, 1)
                }
                sig[y * width + x] = v
            }
        }
    }

    /// Separable box blur with clamped edges (running sums), in place on `buf`.
    private func boxBlur(_ buf: UnsafeMutablePointer<Float>, _ r: Int) {
        let w = width, h = height
        let inv = 1 / Float(2 * r + 1)
        // horizontal: buf -> tmp
        for y in 0..<h {
            let row = y * w
            var acc: Float = 0
            for k in -r...r { acc += buf[row + min(max(k, 0), w - 1)] }
            for x in 0..<w {
                tmp[row + x] = acc * inv
                acc += buf[row + min(x + r + 1, w - 1)] - buf[row + max(x - r, 0)]
            }
        }
        // vertical: tmp -> buf
        for x in 0..<w {
            var acc: Float = 0
            for k in -r...r { acc += tmp[min(max(k, 0), h - 1) * w + x] }
            for y in 0..<h {
                buf[y * w + x] = acc * inv
                acc += tmp[min(y + r + 1, h - 1) * w + x] - tmp[max(y - r, 0) * w + x]
            }
        }
    }

    // MARK: - Overlay rendering

    /// Fills `rgba` (width×height, premultiplied RGBA8) with the heat or arrival map.
    func renderOverlay(mode: OverlayMode, opacity: Float, into rgba: UnsafeMutablePointer<UInt8>) {
        let lut = Colormap.turbo
        let op = max(0, min(1, opacity))
        switch mode {
        case .live:
            rgba.update(repeating: 0, count: count * 4)
        case .heat:
            let scale = 1 / max(params.displayMaxPercent, 0.1)
            for i in 0..<count {
                let o = i * 4
                guard ready, valid[i] != 0 else {
                    rgba[o] = 0; rgba[o + 1] = 0; rgba[o + 2] = 0; rgba[o + 3] = 0
                    continue
                }
                let v = max(0, min(1, resp[i] * scale))
                let alpha = min(1, v * 1.4) * op
                let li = Int(v * 255) * 3
                rgba[o] = UInt8(Float(lut[li]) * alpha)
                rgba[o + 1] = UInt8(Float(lut[li + 1]) * alpha)
                rgba[o + 2] = UInt8(Float(lut[li + 2]) * alpha)
                rgba[o + 3] = UInt8(255 * alpha)
            }
        case .arrival:
            let useLast = order.isEmpty && hasLastArrival
            let src = useLast ? lastArrival : arrival
            var t0: Float = .greatestFiniteMagnitude
            for i in 0..<count where valid[i] != 0 && src[i] >= 0 { t0 = min(t0, src[i]) }
            let span = max(params.arrivalSpan, 0.01)
            for i in 0..<count {
                let o = i * 4
                guard ready, valid[i] != 0 else {
                    rgba[o] = 0; rgba[o + 1] = 0; rgba[o + 2] = 0; rgba[o + 3] = 0
                    continue
                }
                let ta = src[i]
                if ta < 0 {
                    let alpha = 0.35 * op
                    let g = UInt8(40 * alpha)
                    rgba[o] = g; rgba[o + 1] = g; rgba[o + 2] = g; rgba[o + 3] = UInt8(255 * alpha)
                } else {
                    let v = 1 - max(0, min(1, (ta - t0) / span))   // early = red, late = blue
                    let li = Int(v * 255) * 3
                    let alpha = op * (useLast ? 0.6 : 1)
                    rgba[o] = UInt8(Float(lut[li]) * alpha)
                    rgba[o + 1] = UInt8(Float(lut[li + 1]) * alpha)
                    rgba[o + 2] = UInt8(Float(lut[li + 2]) * alpha)
                    rgba[o + 3] = UInt8(255 * alpha)
                }
            }
        }
    }
}
