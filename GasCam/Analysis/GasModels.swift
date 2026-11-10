import Foundation
import CoreGraphics

// MARK: - Parameters

/// Which colour signal is used as the sensor response.
enum SignalChannel: String, CaseIterable, Identifiable, Codable {
    case red, green, blue, luma, redChroma, redBlueRatio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .luma: return "Y (亮度)"
        case .redChroma: return "r = R/(R+G+B)"
        case .redBlueRatio: return "R/B (色比)"
        }
    }
    /// Short name for buttons, curve labels and reports.
    var shortName: String {
        switch self {
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .luma: return "Y"
        case .redChroma: return "r"
        case .redBlueRatio: return "R/B"
        }
    }
    /// "ΔR/R" style name of the relative change of this signal.
    var deltaLabel: String {
        self == .redBlueRatio ? "Δ(R/B)" : "Δ\(shortName)/\(shortName)"
    }
    /// Signal value of a raw (0–255) colour.
    func value(r: Float, g: Float, b: Float) -> Float {
        switch self {
        case .red: return r
        case .green: return g
        case .blue: return b
        case .luma: return 0.2126 * r + 0.7152 * g + 0.0722 * b
        case .redChroma: return 100 * r / max(r + g + b, 1)
        // colour ratio: a brightness change scales R and B alike and cancels out
        case .redBlueRatio: return min(600, 100 * r / max(b, 1))
        }
    }
}

/// How the arrival time of a pixel is decided.
enum ArrivalMode: String, CaseIterable, Identifiable, Codable {
    /// First time the response exceeds the detection threshold.
    case threshold
    /// First time the response exceeds half of the pixel's own peak (never above the detection
    /// threshold): weakly responding pixels no longer look late.
    case adaptive
    var id: String { rawValue }
    var label: String { self == .threshold ? "固定阈值" : "自适应" }
}

/// Sign of the expected optical change. The LSPR film in the test video shows R decreasing.
enum ResponsePolarity: String, CaseIterable, Identifiable, Codable {
    case decrease, increase, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .decrease: return "下降 (−ΔS)"
        case .increase: return "上升 (+ΔS)"
        case .both: return "双向 |ΔS|"
        }
    }
    /// Change in % with the sign convention of the detector (gas = positive).
    func apply(_ v: Float) -> Float {
        switch self {
        case .decrease: return -v
        case .increase: return v
        case .both: return abs(v)
        }
    }
}

/// All tunables of the detector. Defaults were validated on A001_10312104_C067.mov
/// (ethanol puff on the TPI LSPR plate, 1080p 100 fps) with tools/gas_reference.py.
struct GasParams: Equatable, Codable {
    var channel: SignalChannel = .red
    var polarity: ResponsePolarity = .decrease
    /// Box-blur radius (analysis pixels). Applied twice ≈ Gaussian.
    var blurRadius: Int = 2
    /// Duration (s) averaged for the baseline (reference) image, starting when BASELINE is pressed
    /// (or at the start / current position of a video).
    var baselineSeconds: Double = 1.0
    /// Temporal EMA weight of the newest frame (1 = no smoothing).
    var emaAlpha: Float = 0.5
    /// Pixel is "active" when response > max(minPercent, kSigma · baseline noise).
    var kSigma: Float = 4
    var minPercent: Float = 2
    /// Consecutive active frames needed before an arrival is registered.
    var confirmFrames: Int = 2
    /// Fraction of valid ROI pixels that must have been reached before a source estimate is shown.
    var minArrivedFraction: Float = 0.01
    /// Heat-map colour scale: response (%) that maps to the top colour.
    var displayMaxPercent: Float = 12
    /// Arrival map colour span (s).
    var arrivalSpan: Float = 1.0
    /// Below this asymmetry the source is reported as a point (gas came from above the plate).
    var directionConfMin: Float = 0.25
    /// Clear the arrival map after this many quiet seconds (0 = never). The last result stays as a ghost.
    var autoRearmSeconds: Double = 5
    /// Slowly follow baseline drift on pixels that are not reacting.
    var baselineTracking: Bool = false
    /// Max analysis rate (Hz). Camera may run faster; extra frames are only recorded/displayed.
    var analysisRate: Double = 30
    /// Lock AE / AWB / AF when a new baseline is taken (strongly recommended for measurements).
    var lockCameraOnBaseline: Bool = true
    /// FLOW (frame difference): compare the response now with the response `flowLagSeconds` ago.
    var flowLagSeconds: Double = 0.2
    /// FLOW colour scale: change (%) that maps to full red / full blue.
    var flowScalePercent: Float = 3
    /// Divide the signal by the reference box (white paper / grey card) every frame.
    var useReference: Bool = false
    /// Heat-map colour scale follows the data (live: slowly adapting with a floor; video: one scale
    /// for the whole file). Off = fixed `displayMaxPercent`.
    var autoScale: Bool = true
    /// A region counts as "reached" when this fraction of its pixels has been reached.
    var regionArrivalFraction: Float = 0.10
    /// Arrival time of a pixel: fixed threshold, or half of its own peak response.
    var arrivalMode: ArrivalMode = .threshold

    /// Changing these invalidates the baseline.
    func requiresRebaseline(comparedTo o: GasParams) -> Bool {
        channel != o.channel || blurRadius != o.blurRadius || baselineSeconds != o.baselineSeconds
            || useReference != o.useReference
    }

    /// Lowest top-of-scale for the automatic colour scale (keeps noise from filling the colour range).
    var autoScaleFloor: Float { max(2 * minPercent, 3) }
}

extension GasParams {
    /// Tolerant decoding: settings saved by an older version keep their values, new fields get defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ v: inout T) {
            if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x }
        }
        get(.channel, &channel); get(.polarity, &polarity); get(.blurRadius, &blurRadius)
        get(.baselineSeconds, &baselineSeconds); get(.emaAlpha, &emaAlpha); get(.kSigma, &kSigma)
        get(.minPercent, &minPercent); get(.confirmFrames, &confirmFrames)
        get(.minArrivedFraction, &minArrivedFraction); get(.displayMaxPercent, &displayMaxPercent)
        get(.arrivalSpan, &arrivalSpan); get(.directionConfMin, &directionConfMin)
        get(.autoRearmSeconds, &autoRearmSeconds); get(.baselineTracking, &baselineTracking)
        get(.analysisRate, &analysisRate); get(.lockCameraOnBaseline, &lockCameraOnBaseline)
        get(.flowLagSeconds, &flowLagSeconds); get(.flowScalePercent, &flowScalePercent)
        get(.useReference, &useReference); get(.autoScale, &autoScale)
        get(.regionArrivalFraction, &regionArrivalFraction); get(.arrivalMode, &arrivalMode)
    }
}

/// Normalised rectangle (0…1, origin top-left of the upright image).
struct NormRect: Equatable, Codable {
    var x0: CGFloat
    var y0: CGFloat
    var x1: CGFloat
    var y1: CGFloat

    static let full = NormRect(x0: 0, y0: 0, x1: 1, y1: 1)

    var width: CGFloat { x1 - x0 }
    var height: CGFloat { y1 - y0 }

    init(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    /// Rectangle spanned by two corner points (any order).
    init(_ a: CGPoint, _ b: CGPoint) {
        x0 = min(a.x, b.x); x1 = max(a.x, b.x)
        y0 = min(a.y, b.y); y1 = max(a.y, b.y)
    }

    func contains(_ p: CGPoint) -> Bool { p.x >= x0 && p.x < x1 && p.y >= y0 && p.y < y1 }

    func union(_ o: NormRect) -> NormRect {
        NormRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }

    func clamped(minSize: CGFloat = 0.08) -> NormRect {
        var r = self
        r.x0 = min(max(0, r.x0), 1 - minSize)
        r.y0 = min(max(0, r.y0), 1 - minSize)
        r.x1 = max(min(1, r.x1), r.x0 + minSize)
        r.y1 = max(min(1, r.y1), r.y0 + minSize)
        return r
    }
}

// MARK: - Regions

enum RegionMode: String, Codable, CaseIterable, Identifiable {
    /// Up to 6 independent boxes.
    case free
    /// One area split into rows × columns.
    case grid
    var id: String { rawValue }
}

/// Analysis regions drawn by the user, plus an optional reference box (white paper / grey card).
/// No region drawn = the whole frame is analysed.
struct AnalysisRegions: Equatable, Codable {
    var mode: RegionMode = .free
    var rects: [NormRect] = []
    var gridArea: NormRect? = nil
    var rows: Int = 2
    var cols: Int = 2
    var reference: NormRect? = nil

    static let maxFree = 6
    static let maxGridCells = 16
    static let maxGridLines = 8

    /// Analysis regions in display order (numbered 1…n). Empty = whole frame.
    var list: [NormRect] {
        switch mode {
        case .free:
            return Array(rects.prefix(Self.maxFree))
        case .grid:
            guard let a = gridArea else { return [] }
            let r = max(1, rows), c = max(1, cols)
            var out: [NormRect] = []
            for i in 0..<r {
                for j in 0..<c {
                    out.append(NormRect(x0: a.x0 + a.width * CGFloat(j) / CGFloat(c),
                                        y0: a.y0 + a.height * CGFloat(i) / CGFloat(r),
                                        x1: a.x0 + a.width * CGFloat(j + 1) / CGFloat(c),
                                        y1: a.y0 + a.height * CGFloat(i + 1) / CGFloat(r)))
                }
            }
            return out
        }
    }

    var isEmpty: Bool { list.isEmpty }

    /// Number of analysed regions (1 when the whole frame is used).
    var regionCount: Int { max(1, list.count) }

    /// Bounding box of everything analysed (whole frame when nothing is drawn).
    var bounds: NormRect {
        let l = list
        guard var b = l.first else { return .full }
        for r in l.dropFirst() { b = b.union(r) }
        return b
    }

    /// Region colours (RGB 0…1), cycled when there are more regions than colours.
    static let palette: [(Double, Double, Double)] = [
        (1.00, 0.27, 0.23), (0.25, 0.55, 1.00), (0.25, 0.85, 0.35), (1.00, 0.62, 0.10),
        (0.75, 0.40, 1.00), (0.15, 0.85, 0.90), (1.00, 0.45, 0.75), (0.80, 0.85, 0.20),
        (0.55, 0.35, 0.20), (0.60, 0.75, 1.00), (0.10, 0.55, 0.40), (1.00, 0.85, 0.55),
        (0.50, 0.20, 0.60), (0.40, 0.60, 0.60), (0.85, 0.20, 0.45), (0.70, 0.70, 0.70),
    ]
    static func color(_ i: Int) -> (Double, Double, Double) { palette[((i % palette.count) + palette.count) % palette.count] }
}

/// Pixel membership of the regions on an analysis grid.
struct RegionMasks {
    let width: Int
    let height: Int
    /// Number of regions (≥ 1; one region covering the frame when nothing is drawn).
    let count: Int
    let wholeFrame: Bool
    /// Per pixel: bit k set = pixel belongs to region k. The reference box is excluded.
    let bits: [UInt32]
    /// Pixel indices of each region.
    let regionIndices: [[Int32]]
    /// Pixel indices of the reference box (empty if none).
    let refIndices: [Int32]

    /// AUTO metering over the analysed pixels and the reference box: 98th percentile of the
    /// brightest channel (0–255) and the fraction of pixels at ≥ 250.
    func brightness(bgra: UnsafePointer<UInt8>, bytesPerRow: Int) -> (p98: Float, saturated: Float) {
        var hist = [Int](repeating: 0, count: 256)
        var n = 0
        func add(_ i: Int) {
            let p = bgra + (i / width) * bytesPerRow + (i % width) * 4
            hist[Int(max(p[0], p[1], p[2]))] += 1
            n += 1
        }
        for i in 0..<(width * height) where bits[i] != 0 { add(i) }
        for i in refIndices { add(Int(i)) }
        guard n > 0 else { return (0, 0) }
        var sat = 0
        for v in 250...255 { sat += hist[v] }
        let need = Int(Double(n) * 0.98)
        var acc = 0
        var p98 = 255
        for v in 0...255 {
            acc += hist[v]
            if acc >= need { p98 = v; break }
        }
        return (Float(p98), Float(sat) / Float(n))
    }
    let bounds: NormRect

    init(regions: AnalysisRegions, width: Int, height: Int) {
        self.width = width
        self.height = height
        let list = regions.list
        wholeFrame = list.isEmpty
        let rects = wholeFrame ? [NormRect.full] : list
        count = rects.count
        bounds = regions.bounds
        var b = [UInt32](repeating: 0, count: width * height)
        var idx = [[Int32]](repeating: [], count: rects.count)
        var ref: [Int32] = []
        let W = CGFloat(width), H = CGFloat(height)
        for y in 0..<height {
            let py = (CGFloat(y) + 0.5) / H
            for x in 0..<width {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / W, y: py)
                let i = y * width + x
                if let r = regions.reference, r.contains(p) {
                    ref.append(Int32(i))
                    continue
                }
                var m: UInt32 = 0
                for (k, r) in rects.enumerated() where k < 32 && r.contains(p) {
                    m |= 1 << UInt32(k)
                    idx[k].append(Int32(i))
                }
                b[i] = m
            }
        }
        bits = b
        regionIndices = idx
        refIndices = ref
    }

    /// Mean raw R, G, B (0–255) of each region, of all regions together and of the reference box.
    func means(bgra: UnsafePointer<UInt8>, bytesPerRow: Int)
        -> (regions: [RGBMean], union: RGBMean, reference: RGBMean?) {
        var regs = [RGBMean]()
        regs.reserveCapacity(count)
        func mean(_ list: [Int32]) -> RGBMean {
            var sr = 0, sg = 0, sb = 0
            for i32 in list {
                let i = Int(i32)
                let p = bgra + (i / width) * bytesPerRow + (i % width) * 4
                sb += Int(p[0]); sg += Int(p[1]); sr += Int(p[2])
            }
            let n = Float(max(1, list.count))
            return RGBMean(r: Float(sr) / n, g: Float(sg) / n, b: Float(sb) / n)
        }
        for l in regionIndices { regs.append(mean(l)) }
        var ur = 0, ug = 0, ub = 0, un = 0
        for i in 0..<(width * height) where bits[i] != 0 {
            let p = bgra + (i / width) * bytesPerRow + (i % width) * 4
            ub += Int(p[0]); ug += Int(p[1]); ur += Int(p[2]); un += 1
        }
        let n = Float(max(1, un))
        let u = RGBMean(r: Float(ur) / n, g: Float(ug) / n, b: Float(ub) / n)
        return (regs, u, refIndices.isEmpty ? nil : mean(refIndices))
    }
}

struct RGBMean: Equatable {
    var r: Float
    var g: Float
    var b: Float
    var maxChannel: Float { max(r, g, b) }
}

/// Per-region detection result.
struct RegionStat: Equatable {
    var meanResponse: Float = 0
    /// Fraction of the region's valid pixels already reached by the gas.
    var arrivedFraction: Float = 0
    /// Seconds after the baseline when the region counted as reached (nil = not yet).
    var arrivalTime: Float? = nil
    /// Raw mean colour (0–255), filled by the pipeline.
    var raw = RGBMean(r: 0, g: 0, b: 0)
}

// MARK: - Results

struct GasSource: Equatable {
    enum Mode: String {
        /// Gas entered the plate from one side: arrow from plume centroid through the entry point.
        case direction
        /// Plume spread radially: the source is above/at the entry point.
        case point
    }
    /// Centroid of the earliest-reached pixels (where gas first touched the plate), normalised.
    var earliest: CGPoint
    /// Centroid of every pixel reached so far, normalised.
    var centroid: CGPoint
    /// Unit vector (image coords, y down) pointing towards the source.
    var direction: CGVector
    /// |E − C| / plume radius. 0 = radial spreading, ~1 = one-sided entry.
    var confidence: Float
    /// Upstream point on the ROI edge (direction mode) or the entry point (point mode), normalised.
    var sourcePoint: CGPoint
    var mode: Mode
    /// Screen angle in degrees: 0 = right, 90 = up, 180 = left, −90 = down.
    var angleDeg: Double
    var arrivedCount: Int
    /// Seconds since the baseline finished.
    var firstArrival: Double
}

enum GasPhase: Equatable {
    case waiting
    case baseline(progress: Float)
    case monitoring
    case detected
}

struct GasFrameResult: Equatable {
    var phase: GasPhase = .waiting
    var time: Double = 0
    var meanResponse: Float = 0
    var maxResponse: Float = 0
    var activeFraction: Float = 0
    var hotspot: CGPoint? = nil
    var source: GasSource? = nil
    /// Result of the previous event, kept after auto re-arm.
    var lastSource: GasSource? = nil
    var validPixels: Int = 0
    var noiseMedianPercent: Float = 0
    /// Raw mean colour of the ROI (0–255), filled by the pipeline every analysed frame.
    /// While taking the baseline: frames collected / frames needed.
    var baselineFrames: Int = 0
    var baselineTarget: Int = 0
    var roiMeanR: Float = 0
    var roiMeanG: Float = 0
    var roiMeanB: Float = 0
    /// One entry per region (one for the whole frame when nothing is drawn).
    var regions: [RegionStat] = []
    /// Heat-map response (%) shown as the top colour.
    var displayScale: Float = 0
    /// Reference correction factor applied to the signal this frame (1 = none).
    var refFactor: Float = 1
    /// Raw mean colour of the reference box.
    var refMean: RGBMean? = nil
    /// Change (%) of the reference box since the baseline (same sign convention as the response).
    var refResponse: Float? = nil
    /// Gas is on the plate right now (arrivals recorded and pixels still above threshold).
    var gasPresent = false
}

/// Video analysis: where (in video seconds) the baseline was taken and the gas first arrived.
struct VideoMarks: Equatable {
    var baselineStart: Double?
    var baselineEnd: Double?
    var firstArrival: Double?
}

/// One point of the live curve.
struct ChartSample: Equatable {
    var t: Double            // seconds (video time, or seconds since the camera session started)
    var r: Float             // ROI mean R, raw 0–255
    var g: Float
    var b: Float
    var response: Float      // mean ΔS% in ROI (0 before a baseline exists)
    /// 0 waiting, 1 taking baseline, 2 monitoring, 3 gas detected
    var phase: UInt8
    /// Raw mean colour of each region.
    var regions: [RGBMean] = []
    /// ΔS% of each region.
    var regionResponse: [Float] = []
    /// Raw mean colour of the reference box.
    var ref: RGBMean? = nil
    /// Change (%) of the reference box since the baseline.
    var refResponse: Float? = nil
    /// `response` / `regionResponse` / `refResponse` are relative to a baseline. Live: only after the
    /// baseline. Video: the whole file once a baseline exists (also before it, drawn fainter).
    var hasResponse = false
}

enum ChartMode: String, CaseIterable, Identifiable, Codable {
    case raw, response
    var id: String { rawValue }
    var label: String { self == .raw ? L("原始值") : "ΔS/S %" }
    /// Label naming the signal channel in use ("ΔR/R %").
    func label(_ channel: SignalChannel) -> String { self == .raw ? L("原始值") : channel.deltaLabel + " %" }
}

enum OverlayMode: String, CaseIterable, Identifiable, Codable {
    case live, heat, flow, arrival
    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: return "LIVE"
        case .heat: return "HEAT"
        case .flow: return "FLOW"
        case .arrival: return "ARRIVAL"
        }
    }
}
