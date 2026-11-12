import Foundation
import AVFoundation
import CoreImage
import UIKit

/// What to write when a video analysis is exported.
struct ExportOptions: Equatable {
    /// Analysis video: frames + current overlay + regions + arrow (H.264, long edge ≤ 1920 px).
    var video = true
    /// One CSV with the per-frame data of the selected regions.
    var csv = true
    /// Region indices (0-based) that go into the CSV.
    var regions: Set<Int> = []
    /// Arrival time map: grid CSV + PNG.
    var arrivalMap = true
    /// Result image (last frame, overlay, arrow, summary).
    var resultImage = true

    var isEmpty: Bool { !video && !csv && !arrivalMap && !resultImage }
}

/// Result of an export, shown in the export sheet.
struct ExportOutcome {
    var files: [URL]
    var folder: URL?
    /// nil = success.
    var error: String?
    /// Status of the copy to the sync folder (nil = not copied).
    var cloud: String? = nil
}

/// Everything the exporter needs, captured from the pipeline when the export starts.
struct ExportRequest {
    let source: URL
    /// Base name of the output files.
    let name: String
    let params: GasParams
    let regions: AnalysisRegions
    let display: DisplayOptions
    /// Video time (s) where the baseline was taken.
    let baselineStart: Double
    let baselineFrames: Int
    /// Whole-file colour scale used by the playback (nil = automatic per frame).
    let videoScale: Float?
    let options: ExportOptions
}

/// Offline export of a video analysis: decodes the file from start to end, runs the same analysis as
/// the playback (baseline from the same place, same settings) and writes the requested files into
/// Documents/Exports/<name>_<time>/.
final class VideoExporter {
    static let maxDimension: CGFloat = 1920

    private let queue = DispatchQueue(label: "gascam.export", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelFlag = false
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelFlag }

    func cancel() { lock.lock(); cancelFlag = true; lock.unlock() }

    private struct Row {
        let t: Double
        let phase: UInt8
        let regions: [RGBMean]
        let ref: RGBMean?
        let reached: [Float]
        let ready: Bool
    }

    private struct Failure: Error { let message: String }

    /// `progress` (0…1) and `completion` (files, output folder, error message or nil) on the main thread.
    func run(_ req: ExportRequest, progress: @escaping (Double) -> Void,
             completion: @escaping ([URL], URL?, String?) -> Void) {
        Task {
            do {
                let asset = AVURLAsset(url: req.source)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw Failure(message: L("文件中没有视频轨道"))
                }
                let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let duration = try await asset.load(.duration)
                self.queue.async {
                    let out: ([URL], URL?, String?)
                    do {
                        let (files, folder) = try self.process(req, asset: asset, track: track, size: size,
                                                               transform: transform, fps: fps, duration: duration,
                                                               progress: progress)
                        out = (files, folder, nil)
                    } catch let f as Failure {
                        out = ([], nil, f.message)
                    } catch {
                        out = ([], nil, error.localizedDescription)
                    }
                    DispatchQueue.main.async { completion(out.0, out.1, out.2) }
                }
            } catch let f as Failure {
                DispatchQueue.main.async { completion([], nil, f.message) }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { completion([], nil, msg) }
            }
        }
    }

    // MARK: - Main pass (export queue)

    private func process(_ req: ExportRequest, asset: AVAsset, track: AVAssetTrack, size: CGSize,
                         transform: CGAffineTransform, fps: Float, duration: CMTime,
                         progress: @escaping (Double) -> Void) throws -> ([URL], URL) {
        let p = req.params
        let opt = req.options
        let rate = fps > 1 ? Double(fps) : 30
        let total = max(duration.seconds, 0.001)

        // reader: upright BGRA frames, long edge ≤ maxDimension, even size (H.264)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let natural = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        let scale = min(1, Self.maxDimension / max(natural.width, natural.height, 1))
        var W = Int((natural.width * scale).rounded()), H = Int((natural.height * scale).rounded())
        W -= W % 2; H -= H % 2
        guard W >= 16, H >= 16 else { throw Failure(message: L("无法读取该视频")) }
        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: W, height: H)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform
            .concatenating(CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
            .concatenating(CGAffineTransform(scaleX: CGFloat(W) / natural.width, y: CGFloat(H) / natural.height)), at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = comp
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(message: L("无法读取该视频")) }
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: L("无法读取该视频")) }
        defer { reader.cancelReading() }

        // output folder
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd_HHmmss"
            return f.string(from: Date())
        }()
        let fm = FileManager.default
        let folder = FramePipeline.documentsURL
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent("\(req.name)_\(stamp)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        var finished = false
        defer { if !finished { try? fm.removeItem(at: folder) } }

        // writer (analysis video)
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        let videoURL = folder.appendingPathComponent("\(req.name)_analysis.mov")
        if opt.video {
            let w = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
            let bitrate = min(40_000_000, max(6_000_000, Int(Double(W * H) * rate * 0.15)))
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: W,
                AVVideoHeightKey: H,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoMaxKeyFrameIntervalKey: max(1, Int(rate.rounded())),
                ],
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = false
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: W,
                kCVPixelBufferHeightKey as String: H,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            guard w.canAdd(inp) else { throw Failure(message: L("无法创建视频文件")) }
            w.add(inp)
            guard w.startWriting() else {
                throw Failure(message: L("无法创建视频文件") + ": " + (w.error?.localizedDescription ?? ""))
            }
            writer = w; input = inp; adaptor = ad
        }
        var sessionStarted = false

        // analysis state
        var analyzer: GasAnalyzer?
        var downsampler: FrameDownsampler?
        var masks: RegionMasks?
        var overlayBuf: UnsafeMutablePointer<UInt8>?
        defer { overlayBuf?.deallocate() }
        var armed = false
        var baselineStartT: Double?
        var lastAnalysisT = -1.0
        let interval = 0.9 / max(1, Double(p.analysisRate))
        var last = GasFrameResult()
        var overlay: CIImage?
        var rows: [Row] = []
        var basePB: CVPixelBuffer?
        var lastPB: CVPixelBuffer?
        var lastProgress = -1.0

        while true {
            if isCancelled { writer?.cancelWriting(); throw Failure(message: L("已取消导出")) }
            var done = false
            var failure: Failure?
            autoreleasepool {
                guard let sb = output.copyNextSampleBuffer() else { done = true; return }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let t = pts.seconds
                guard t.isFinite else { return }

                if analyzer == nil {
                    let (gw, gh) = FrameDownsampler.gridSize(forFrameWidth: CVPixelBufferGetWidth(pb),
                                                             height: CVPixelBufferGetHeight(pb))
                    let an = GasAnalyzer(width: gw, height: gh, params: p, regions: req.regions)
                    an.videoMode = true
                    an.videoScale = req.videoScale
                    an.baselineTargetFrames = req.baselineFrames
                    analyzer = an
                    downsampler = FrameDownsampler(width: gw, height: gh)
                    masks = RegionMasks(regions: req.regions, width: gw, height: gh)
                    let b = UnsafeMutablePointer<UInt8>.allocate(capacity: gw * gh * 4)
                    b.initialize(repeating: 0, count: gw * gh * 4)
                    overlayBuf = b
                }
                guard let an = analyzer, let ds = downsampler, let mk = masks else { return }

                // the baseline starts where it was taken during playback
                if !armed && t >= req.baselineStart - 0.5 / rate {
                    armed = true
                    an.resetBaseline()
                    baselineStartT = t
                    basePB = pb
                }

                // analysis (same rate limit as the playback)
                if lastAnalysisT < 0 || t < lastAnalysisT || t - lastAnalysisT >= interval {
                    lastAnalysisT = t
                    if ds.downsample(pb) {
                        var r = GasFrameResult()
                        r.time = t
                        if armed {
                            r = an.process(bgra: ds.pixels, bytesPerRow: ds.bytesPerRow, time: t, registerArrivals: true)
                        }
                        let means = mk.means(bgra: ds.pixels, bytesPerRow: ds.bytesPerRow)
                        if r.regions.count != means.regions.count {
                            r.regions = [RegionStat](repeating: RegionStat(), count: means.regions.count)
                        }
                        for k in 0..<means.regions.count { r.regions[k].raw = means.regions[k] }
                        if r.displayScale <= 0 { r.displayScale = p.autoScale ? p.autoScaleFloor : p.displayMaxPercent }
                        rows.append(Row(t: t, phase: Self.phaseCode(r.phase), regions: means.regions,
                                        ref: means.reference, reached: r.regions.map { $0.arrivedFraction },
                                        ready: an.ready))
                        if writer != nil, armed, an.ready, req.display.overlay != .live, let buf = overlayBuf {
                            an.renderOverlay(mode: req.display.overlay, opacity: req.display.overlayOpacity,
                                             scale: r.displayScale, into: buf)
                            overlay = Self.makeImage(buf, width: an.width, height: an.height)
                        } else {
                            overlay = nil
                        }
                        last = r
                    }
                }

                // video frame
                if let w = writer, let inp = input, let ad = adaptor {
                    if !sessionStarted { w.startSession(atSourceTime: pts); sessionStarted = true }
                    while !inp.isReadyForMoreMediaData {
                        if isCancelled { return }
                        usleep(2000)
                    }
                    guard let pool = ad.pixelBufferPool else { failure = Failure(message: L("无法创建视频文件")); return }
                    var outPB: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
                    guard let ob = outPB else { failure = Failure(message: L("无法创建视频文件")); return }
                    let img = Self.compose(CIImage(cvPixelBuffer: pb), overlay, req.display)
                    ciContext.render(img, to: ob, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: Self.sRGB)
                    annotate(ob, regions: req.regions, result: last, time: t, params: p,
                             analysed: armed && an.ready)
                    if !ad.append(ob, withPresentationTime: pts) {
                        failure = Failure(message: L("写入视频失败") + ": " + (w.error?.localizedDescription ?? ""))
                    }
                }
                lastPB = pb
                if t - lastProgress >= total / 100 {
                    lastProgress = t
                    let v = min(0.98, t / total)
                    DispatchQueue.main.async { progress(v) }
                }
            }
            if let failure { writer?.cancelWriting(); throw failure }
            if done { break }
        }
        if reader.status == .failed {
            writer?.cancelWriting()
            throw Failure(message: L("读取失败") + ": " + (reader.error?.localizedDescription ?? ""))
        }
        guard let an = analyzer, !rows.isEmpty else {
            writer?.cancelWriting()
            throw Failure(message: L("视频里没有可分析的画面"))
        }

        // finish the video
        if let w = writer, let inp = input {
            inp.markAsFinished()
            let sem = DispatchSemaphore(value: 0)
            w.finishWriting { sem.signal() }
            sem.wait()
            guard w.status == .completed else {
                throw Failure(message: L("写入视频失败") + ": " + (w.error?.localizedDescription ?? ""))
            }
            files.append(videoURL)
        }
        if isCancelled { throw Failure(message: L("已取消导出")) }

        let origin: Double? = an.ready ? an.arrivalOrigin : nil
        if opt.csv {
            let url = folder.appendingPathComponent("\(req.name)_regions.csv")
            try writeRegionCSV(url, req: req, rows: rows, result: last, baselineStart: baselineStartT, baselineEnd: origin)
            files.append(url)
        }
        if opt.arrivalMap, let origin {
            let csv = folder.appendingPathComponent("\(req.name)_arrival.csv")
            try writeArrivalCSV(csv, req: req, analyzer: an, origin: origin)
            files.append(csv)
            let png = folder.appendingPathComponent("\(req.name)_arrival.png")
            if let bg = basePB ?? lastPB, writeArrivalPNG(png, background: bg, req: req, analyzer: an, result: last, origin: origin) {
                files.append(png)
            }
        }
        if opt.resultImage, let pb = lastPB {
            let png = folder.appendingPathComponent("\(req.name)_result.png")
            var finalOverlay: CIImage?
            if an.ready, req.display.overlay != .live, let buf = overlayBuf {
                an.renderOverlay(mode: req.display.overlay, opacity: req.display.overlayOpacity,
                                 scale: last.displayScale, into: buf)
                finalOverlay = Self.makeImage(buf, width: an.width, height: an.height)
            }
            let img = Self.compose(CIImage(cvPixelBuffer: pb), finalOverlay, req.display)
            if let cg = ciContext.createCGImage(img, from: img.extent) {
                let sz = CGSize(width: cg.width, height: cg.height)
                let data = Self.renderPNG(size: sz) { ctx in
                    UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: sz))
                    ResultDrawing.draw(in: ctx, size: sz, regions: req.regions, result: last)
                }
                if let data { try data.write(to: png); files.append(png) }
            }
        }
        if opt.arrivalMap && origin == nil && files.isEmpty {
            throw Failure(message: L("没有取完基线，无法生成到达时间图"))
        }
        finished = true
        DispatchQueue.main.async { progress(1) }
        return (files, folder)
    }

    // MARK: - Frames

    private static func phaseCode(_ ph: GasPhase) -> UInt8 {
        switch ph {
        case .waiting: return 0
        case .baseline: return 1
        case .monitoring: return 2
        case .detected: return 3
        }
    }

    /// Frame + overlay (and the black background option), like the preview without the shooting aids.
    private static func compose(_ f: CIImage, _ o: CIImage?, _ opt: DisplayOptions) -> CIImage {
        let extent = f.extent
        var img = f
        if opt.blackBackground && opt.overlay != .live && o != nil {
            img = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }
        if let o, opt.overlay != .live {
            let oe = o.extent
            let sx = extent.width / max(oe.width, 1), sy = extent.height / max(oe.height, 1)
            let scaled = o.samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
                .cropped(to: extent)
            img = scaled.composited(over: img)
        }
        return img.cropped(to: extent)
    }

    private static func makeImage(_ rgba: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> CIImage? {
        guard let cg = makeCGImage(Data(bytes: rgba, count: width * height * 4), width: width, height: height) else { return nil }
        return CIImage(cgImage: cg)
    }

    private static func makeCGImage(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Regions, arrow and a small time / response label drawn into a video frame.
    private func annotate(_ pb: CVPixelBuffer, regions: AnalysisRegions, result r: GasFrameResult, time t: Double,
                          params p: GasParams, analysed: Bool) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: Self.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // UIKit coordinates (origin top-left)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let size = CGSize(width: w, height: h)
        ResultDrawing.draw(in: ctx, size: size, regions: regions, result: r, summary: false)
        var lines = [String(format: "t = %.2f s", t)]
        switch r.phase {
        case .waiting: lines.append(L("基线之前"))
        case .baseline: lines.append(L("正在取基线…"))
        case .monitoring: lines.append(L("监测中"))
        case .detected: lines.append(L("检测到气体"))
        }
        if analysed {
            lines.append(String(format: "%@ %.2f%%  max %.1f%%", p.channel.deltaLabel, r.meanResponse, r.maxResponse))
        }
        if let s = r.source, s.mode == .direction {
            lines.append(String(format: L("气源方向：%.0f°（0° = 右，90° = 上） · 置信度 %.2f"), s.angleDeg, s.confidence))
        }
        ResultDrawing.drawStamp(in: ctx, size: size, lines: lines)
    }

    private static func renderPNG(size: CGSize, _ draw: (CGContext) -> Void) -> Data? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).pngData { ctx in draw(ctx.cgContext) }
    }

    // MARK: - CSV

    private static func csvLine(_ cells: [String]) -> String { cells.joined(separator: ",") + "\n" }

    private static func num(_ v: Double, _ digits: Int) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : ""
    }

    private static func headerLines(_ req: ExportRequest) -> [String] {
        let p = req.params
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return [
            "# GasCam \(CrashReporter.appVersion) analysis export",
            "# video,\(req.source.lastPathComponent.replacingOccurrences(of: ",", with: " "))",
            "# exported,\(f.string(from: Date()))",
            "# channel,\(p.channel.csvName)",
            "# polarity,\(p.polarity.rawValue)",
            "# threshold_pct,\(num(Double(p.minPercent), 2))",
            "# k_sigma,\(num(Double(p.kSigma), 1))",
            "# arrival_rule,\(p.arrivalMode.rawValue)",
            "# reference_correction,\(p.useReference && req.regions.reference != nil ? "on" : "off")",
        ]
    }

    /// One row per analysed frame, the selected regions side by side.
    private func writeRegionCSV(_ url: URL, req: ExportRequest, rows: [Row], result last: GasFrameResult,
                                baselineStart b0: Double?, baselineEnd b1: Double?) throws {
        let p = req.params
        let ch = p.channel
        let nReg = rows.first?.regions.count ?? 0
        var sel = req.options.regions.filter { $0 < nReg }.sorted()
        if sel.isEmpty { sel = Array(0..<nReg) }
        let hasRef = req.regions.reference != nil && rows.contains { $0.ref != nil }
        func pol(_ v: Double) -> Double {
            switch p.polarity {
            case .decrease: return -v
            case .increase: return v
            case .both: return abs(v)
            }
        }
        // reference correction, as in the playback curve: factor = reference at the baseline start / now
        var anchor: Double?
        if p.useReference, let b0, let first = rows.first(where: { $0.t >= b0 - 1e-6 }), let rf = first.ref {
            anchor = Double(ch.value(r: rf.r, g: rf.g, b: rf.b))
        }
        func factor(_ row: Row) -> Double {
            guard let a = anchor, let rf = row.ref else { return 1 }
            let now = Double(ch.value(r: rf.r, g: rf.g, b: rf.b))
            return now > 1 ? a / now : 1
        }
        func value(_ c: RGBMean) -> Double { Double(ch.value(r: c.r, g: c.g, b: c.b)) }
        // baseline mean of every region
        var base = [Double](repeating: 0, count: nReg)
        var haveBase = false
        if let b0, let b1 {
            let rs = rows.filter { $0.t >= b0 - 1e-6 && $0.t <= b1 + 1e-6 }
            if !rs.isEmpty {
                for row in rs {
                    let f = factor(row)
                    for k in 0..<min(nReg, row.regions.count) { base[k] += value(row.regions[k]) * f }
                }
                for k in 0..<nReg { base[k] /= Double(rs.count) }
                haveBase = true
            }
        }

        var text = "\u{FEFF}"
        for l in Self.headerLines(req) { text += l + "\n" }
        text += "# baseline_start_s,\(b0.map { Self.num($0, 3) } ?? "none")\n"
        text += "# baseline_end_s,\(b1.map { Self.num($0, 3) } ?? "none")\n"
        let list = req.regions.list
        for k in sel {
            let q = k < list.count ? list[k] : NormRect.full
            let at: String = {
                guard let b1, k < last.regions.count, let a = last.regions[k].arrivalTime else { return "none" }
                return Self.num(b1 + Double(a), 3)
            }()
            text += "# region_\(k + 1),x0=\(Self.num(Double(q.x0), 4));y0=\(Self.num(Double(q.y0), 4));x1=\(Self.num(Double(q.x1), 4));y1=\(Self.num(Double(q.y1), 4)),arrival_s=\(at)\n"
        }
        if let s = last.source ?? last.lastSource, let b1 {
            text += "# first_arrival_s,\(Self.num(b1 + s.firstArrival, 3))\n"
            if s.mode == .direction {
                text += "# direction_deg,\(Self.num(s.angleDeg, 1)),confidence,\(Self.num(Double(s.confidence), 2)),(0 = right; 90 = up)\n"
            } else {
                text += "# direction,none (spreads from the middle),confidence,\(Self.num(Double(s.confidence), 2))\n"
            }
        }
        text += "# region rectangles are fractions of the frame (origin top-left); times are video time in seconds\n"
        text += "# phase: 0 before baseline / 1 baseline / 2 after baseline / 3 gas detected\n"
        text += "# dS_pct = polarity x 100 x (S - S_baseline) / S_baseline, S = \(ch.csvName) of the region mean colour\n"
        text += "# reached_pct = share of the region's analysed pixels the gas has reached so far\n"

        var head = ["time_s", "phase"]
        for k in sel {
            let n = "r\(k + 1)_"
            head += [n + "R", n + "G", n + "B", n + ch.csvName, n + "dS_pct", n + "reached_pct"]
        }
        if hasRef { head += ["ref_R", "ref_G", "ref_B"] }
        text += Self.csvLine(head)
        for row in rows {
            var cells = [Self.num(row.t, 3), "\(row.phase)"]
            let f = factor(row)
            for k in sel {
                guard k < row.regions.count else { cells += ["", "", "", "", "", ""]; continue }
                let c = row.regions[k]
                let v = value(c)
                cells.append(Self.num(Double(c.r), 2))
                cells.append(Self.num(Double(c.g), 2))
                cells.append(Self.num(Double(c.b), 2))
                cells.append(Self.num(v, 3))
                cells.append(haveBase && base[k] > 0 ? Self.num(pol(100 * (v * f - base[k]) / base[k]), 4) : "")
                cells.append(row.ready && k < row.reached.count ? Self.num(Double(row.reached[k]) * 100, 2) : "")
            }
            if hasRef {
                if let rf = row.ref {
                    cells += [Self.num(Double(rf.r), 2), Self.num(Double(rf.g), 2), Self.num(Double(rf.b), 2)]
                } else {
                    cells += ["", "", ""]
                }
            }
            text += Self.csvLine(cells)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Arrival time of every grid cell (video time, s): one CSV row per grid row, top to bottom.
    private func writeArrivalCSV(_ url: URL, req: ExportRequest, analyzer an: GasAnalyzer, origin: Double) throws {
        let arr = an.arrivalSnapshot()
        let valid = an.validSnapshot()
        let w = an.width, h = an.height
        var text = "\u{FEFF}"
        for l in Self.headerLines(req) { text += l + "\n" }
        text += "# baseline_end_s,\(Self.num(origin, 3))\n"
        text += "# arrival time map: video time in seconds; \(h) rows (top to bottom) x \(w) columns (left to right) covering the whole frame\n"
        text += "# empty = not reached / not analysed (outside the regions, saturated or too dark)\n"
        for y in 0..<h {
            var cells = [String]()
            cells.reserveCapacity(w)
            for x in 0..<w {
                let i = y * w + x
                cells.append(valid[i] != 0 && arr[i] >= 0 ? Self.num(origin + Double(arr[i]), 3) : "")
            }
            text += Self.csvLine(cells)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Arrival map over the frame where the baseline was taken: early = red, late = blue, with a
    /// colour bar (video time) at the top and the summary at the bottom.
    private func writeArrivalPNG(_ url: URL, background pb: CVPixelBuffer, req: ExportRequest,
                                 analyzer an: GasAnalyzer, result last: GasFrameResult, origin: Double) -> Bool {
        let arr = an.arrivalSnapshot()
        let valid = an.validSnapshot()
        let w = an.width, h = an.height
        let reached = arr.indices.filter { valid[$0] != 0 && arr[$0] >= 0 }.map { arr[$0] }.sorted()
        guard let t0 = reached.first else { return false }
        let t1 = max(reached[min(reached.count - 1, Int(Double(reached.count) * 0.95))], t0 + 0.05)
        let lut = Colormap.turbo
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where valid[i] != 0 {
            let o = i * 4
            if arr[i] >= 0 {
                let v = 1 - max(0, min(1, (arr[i] - t0) / (t1 - t0)))        // early = red, late = blue
                let li = Int(v * 255) * 3
                rgba[o] = lut[li]; rgba[o + 1] = lut[li + 1]; rgba[o + 2] = lut[li + 2]; rgba[o + 3] = 255
            } else {
                rgba[o] = 30; rgba[o + 1] = 30; rgba[o + 2] = 30; rgba[o + 3] = 120
            }
        }
        guard let grid = Self.makeCGImage(Data(rgba), width: w, height: h) else { return false }
        let frame = CIImage(cvPixelBuffer: pb)
        guard let bg = ciContext.createCGImage(frame, from: frame.extent) else { return false }
        let size = CGSize(width: bg.width, height: bg.height)
        let data = Self.renderPNG(size: size) { ctx in
            let r = CGRect(origin: .zero, size: size)
            UIImage(cgImage: bg).draw(in: r)
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fill(r)
            ctx.interpolationQuality = .high
            UIImage(cgImage: grid).draw(in: r)
            ResultDrawing.draw(in: ctx, size: size, regions: req.regions, result: last)
            // colour bar
            let barW = size.width * 0.5, barH = max(10, size.height / 90)
            let x0 = size.width - barW - 16, y0: CGFloat = 16 + barH * 1.8
            let steps = 64
            for k in 0..<steps {
                let v = 1 - Double(k) / Double(steps - 1)
                let li = Int(v * 255) * 3
                ctx.setFillColor(UIColor(red: CGFloat(lut[li]) / 255, green: CGFloat(lut[li + 1]) / 255,
                                         blue: CGFloat(lut[li + 2]) / 255, alpha: 1).cgColor)
                ctx.fill(CGRect(x: x0 + barW * CGFloat(k) / CGFloat(steps), y: y0, width: barW / CGFloat(steps) + 1, height: barH))
            }
            let font = UIFont.monospacedSystemFont(ofSize: max(12, size.width / 55), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            UIGraphicsPushContext(ctx)
            (L("到达时间（视频时间）") as NSString).draw(at: CGPoint(x: x0, y: 12), withAttributes: attrs)
            (String(format: "%.2f s", origin + Double(t0)) as NSString).draw(at: CGPoint(x: x0, y: y0 + barH + 4), withAttributes: attrs)
            let endText = String(format: "%.2f s", origin + Double(t1)) as NSString
            let ew = endText.size(withAttributes: attrs).width
            endText.draw(at: CGPoint(x: x0 + barW - ew, y: y0 + barH + 4), withAttributes: attrs)
            UIGraphicsPopContext()
        }
        guard let data else { return false }
        return (try? data.write(to: url)) != nil
    }
}

extension SignalChannel {
    /// ASCII name for CSV headers.
    var csvName: String {
        switch self {
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .luma: return "Y"
        case .redChroma: return "r"
        case .redBlueRatio: return "RB"
        }
    }
}
