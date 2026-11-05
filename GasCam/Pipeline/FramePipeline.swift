import Foundation
import AVFoundation
import CoreImage
import Combine
import Photos
import UIKit

/// Glue between frame sources (camera / video file), the gas analyzer, the preview renderer
/// and the recorder. Frames are handled on the source's queue; UI state is published on main.
final class FramePipeline: ObservableObject {
    enum SourceKind: Equatable {
        case camera
        case file(name: String)
    }

    // MARK: Published UI state (main thread)

    @Published private(set) var source: SourceKind = .camera
    @Published private(set) var result = GasFrameResult()
    @Published private(set) var histogram = Histogram()
    @Published private(set) var frameAspect: CGFloat = 9.0 / 16.0
    @Published private(set) var measuredFPS: Double = 0
    /// Live curve samples (ROI mean R/G/B and response), published ~15 Hz.
    @Published private(set) var chart: [ChartSample] = []
    /// Video mode: full-length curve from a quick pre-scan (response filled once a baseline exists).
    @Published private(set) var videoCurve: [ChartSample] = []
    /// Video pre-scan progress 0…1 (1 = done).
    @Published private(set) var scanProgress: Double = 0
    /// Video: heat-map scale for the whole file (known after the scan and a baseline). nil = not yet.
    @Published private(set) var videoScale: Float?
    /// Video mode: when the baseline was taken and when gas first arrived (video seconds).
    @Published private(set) var marks = VideoMarks()
    /// While the user drags the progress bar: the time under the finger.
    @Published private(set) var scrubTime: Double?
    /// Analysed frames per second actually used (min of analysis rate and source frame rate).
    @Published private(set) var effectiveAnalysisRate: Double = 30
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?
    @Published private(set) var playbackTime: Double = 0
    @Published private(set) var playbackDuration: Double = 0
    @Published private(set) var playbackFinished = false
    @Published var playbackPaused = false {
        didSet {
            fileSource.paused = playbackPaused
            procLock.lock(); procPaused = playbackPaused; procLock.unlock()
        }
    }
    @Published var playbackSpeed: Double = 1 { didSet { fileSource.speed = playbackSpeed } }
    @Published var toast: String?

    @Published var params: GasParams {
        didSet {
            guard params != oldValue else { return }
            Self.store(params, "gas.params")
            procLock.lock(); procParams = params; paramsDirty = true; procLock.unlock()
            updateEffectiveRate()
            if params.channel != oldValue.channel {
                if case .file = source { scheduleRescan() }
            } else if params.polarity != oldValue.polarity || params.useReference != oldValue.useReference
                        || params.autoScale != oldValue.autoScale || params.minPercent != oldValue.minPercent {
                rebuildVideoCurve()
            }
        }
    }
    /// Analysis regions + reference box. Empty = whole frame.
    @Published var regions: AnalysisRegions {
        didSet {
            guard regions != oldValue else { return }
            Self.store(regions, "gas.regions")
            procLock.lock(); procRegions = regions; regionsDirty = true; procLock.unlock()
            if case .file = source { scheduleRescan() }
        }
    }
    @Published var display: DisplayOptions {
        didSet {
            guard display != oldValue else { return }
            Self.store(display, "display.options")
            renderer?.options = display
            if display.showAudioMeter != oldValue.showAudioMeter {
                camera.setAudio(enabled: display.showAudioMeter || recordSettings.recordAudio)
            }
            procLock.lock(); procDisplay = display; procLock.unlock()
        }
    }
    @Published var recordSettings: RecordSettings {
        didSet {
            Self.store(recordSettings, "record.settings")
            if recordSettings.recordAudio != oldValue.recordAudio {
                camera.setAudio(enabled: display.showAudioMeter || recordSettings.recordAudio)
            }
        }
    }

    let camera: CameraController
    let renderer: PreviewRenderer?
    private let fileSource = VideoFileSource()
    private let recorder = VideoRecorder()
    private var currentFileURL: URL?
    private var fileFPS: Double = 30
    private var cancellables = Set<AnyCancellable>()
    private var scanRaw: [ChartSample] = []
    /// Coarse per-frame signal maps of the video (for the whole-file colour scale).
    private var scanCoarse = CoarseScan()
    private var scaleWork: DispatchWorkItem?
    private var rescanWork: DispatchWorkItem?
    private var scrubWasPaused = false
    private var lastScrubSeek: TimeInterval = 0
    private var pendingScrubTarget: Double?

    // MARK: Processing state (guarded by procLock)

    private let procLock = NSLock()
    private var analyzer: GasAnalyzer?
    private var downsampler: FrameDownsampler?
    private var overlayBuffer: UnsafeMutablePointer<UInt8>?
    private var overlayCount = 0
    private var procParams: GasParams
    private var procRegions: AnalysisRegions
    private var procMasks: RegionMasks?
    private var procDisplay: DisplayOptions
    private var paramsDirty = false
    private var regionsDirty = false
    private var procVideoScale: Float?
    private var pendingRebaseline = false
    private var pendingResetArrivals = false
    private var armed = false
    private var acceptCamera = true
    private var acceptFile = false
    private var lastAnalysisT: Double = -1
    private var lastPublishT: Double = -1
    private var fpsT0: Double = -1
    private var fpsN = 0
    private var fpsValue: Double = 0
    private var frameW = 0
    private var frameH = 0
    private var logger: AnalysisLogger?
    private var recordingT0: Double?
    private var chartBuf: [ChartSample] = []
    private var chartT0: Double?
    private var lastChartT: Double = -1
    private var pendingSeekReset = false
    private var forceAnalyze = false
    private var procPaused = false
    private var lastDisplayT: Double = -1
    private var procBaselineTarget = 30
    private var procMarks = VideoMarks()

    init(camera: CameraController) {
        self.camera = camera
        self.renderer = PreviewRenderer()
        let p = FramePipeline.load("gas.params", default: GasParams())
        let r = FramePipeline.load("gas.regions", default: AnalysisRegions())
        let d = FramePipeline.load("display.options", default: DisplayOptions())
        params = p
        regions = r
        display = d
        recordSettings = FramePipeline.load("record.settings", default: RecordSettings())
        procParams = p
        procRegions = r
        procDisplay = d
        renderer?.options = d

        camera.frameHandler = { [weak self] pb, pts in self?.handle(pb, pts, fromCamera: true, preroll: false) }
        camera.audioHandler = { [weak self] sb in self?.recorder.appendAudio(sb) }
        camera.onSettingsChanged = { [weak self] in self?.settingsChanged() }
        fileSource.frameHandler = { [weak self] pb, pts, pre in self?.handle(pb, pts, fromCamera: false, preroll: pre) }
        fileSource.onLoaded = { [weak self] fps, dur in
            guard let self else { return }
            self.fileFPS = fps
            self.playbackDuration = dur
            self.updateEffectiveRate()
            self.startScan()
        }
        camera.$frameRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateEffectiveRate() }
            .store(in: &cancellables)
        camera.setAudio(enabled: d.showAudioMeter || recordSettings.recordAudio)
        updateEffectiveRate()
        fileSource.onProgress = { [weak self] cur, total in
            self?.playbackTime = cur
            self?.playbackDuration = total
        }
        fileSource.onFinish = { [weak self] err in
            self?.playbackFinished = true
            if let err { self?.toast = L("播放结束") + ": \(err)" }
        }
    }

    deinit { overlayBuffer?.deallocate() }

    // MARK: - Commands (main thread)

    func startCamera() {
        guard source == .camera else { return }
        camera.start()
    }

    /// Take a new reference image and start detecting. Locks the camera first if configured.
    func startBaseline() {
        if case .file = source {
            marks = VideoMarks()
            procLock.lock(); procMarks = VideoMarks(); procLock.unlock()
            rebuildVideoCurve()
            // the baseline is built from the frames that follow: keep playing from here
            if playbackPaused && !playbackFinished { playbackPaused = false }
        }
        if source == .camera { camera.freezeTorch() }
        let queue = { [weak self] in
            guard let self else { return }
            self.procLock.lock()
            self.armed = true
            self.pendingRebaseline = true
            self.procLock.unlock()
        }
        if source == .camera && params.lockCameraOnBaseline && !camera.isFullyLocked {
            camera.lockAll { [weak self] summary in
                if !summary.isEmpty { self?.toast = L("已锁定") + "：" + summary }
                queue()
            }
        } else {
            queue()
        }
    }

    /// Stop detection (back to the waiting state).
    func disarm() {
        procLock.lock()
        armed = false
        pendingRebaseline = true
        procLock.unlock()
    }

    func resetArrivals() {
        procLock.lock()
        pendingResetArrivals = true
        procMarks.firstArrival = nil
        procLock.unlock()
        marks.firstArrival = nil
        rebuildVideoCurve()
    }

    /// One tap: freeze exposure, white balance, focus and torch at their current values.
    func lockAllCamera() {
        camera.lockAll { [weak self] summary in
            if !summary.isEmpty { self?.toast = L("已锁定") + "：" + summary }
        }
    }

    /// One tap: exposure, white balance, focus and torch back to automatic.
    func autoAllCamera() {
        camera.setAllAuto()
    }

    /// Frames ↔ seconds for the baseline (uses the effective analysis rate).
    var baselineFrameCount: Int {
        max(3, Int((params.baselineSeconds * effectiveAnalysisRate).rounded()))
    }

    func setBaselineFrames(_ n: Int) {
        params.baselineSeconds = Double(max(3, n)) / max(1, effectiveAnalysisRate)
    }

    private func updateEffectiveRate() {
        let src: Double
        if case .file = source { src = fileFPS } else { src = max(1, camera.frameRate) }
        let rate = min(params.analysisRate, src)
        if effectiveAnalysisRate != rate { effectiveAnalysisRate = rate }
        let target = max(3, Int((params.baselineSeconds * rate).rounded()))
        procLock.lock(); procBaselineTarget = target; procLock.unlock()
    }

    private func settingsChanged() {
        // Any manual camera change invalidates the reference image.
        procLock.lock()
        if armed { pendingRebaseline = true }
        procLock.unlock()
    }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func startRecording() {
        guard source == .camera, !isRecording else { return }
        let stamp = Self.stampFormatter.string(from: Date())
        let base = Self.documentsURL.appendingPathComponent("GasCam_\(stamp)")
        let movURL = base.appendingPathExtension("mov")
        let cfg = VideoRecorder.Config(url: movURL, fps: camera.frameRate,
                                       codec: recordSettings.codec, bitrateMbps: recordSettings.bitrateMbps,
                                       recordAudio: recordSettings.recordAudio && camera.audioActive)

        // Metadata: camera + analysis settings, for reproducibility.
        var meta: [String: Any] = camera.settingsSnapshot()
        meta["codec"] = recordSettings.codec.label
        meta["bitrate_mbps"] = recordSettings.bitrateMbps
        meta["recorded_at"] = ISO8601DateFormatter().string(from: Date())
        if let pd = try? JSONEncoder().encode(params), let pj = try? JSONSerialization.jsonObject(with: pd) {
            meta["gas_params"] = pj
        }
        func rectDict(_ r: NormRect) -> [String: Double] {
            ["x0": Double(r.x0), "y0": Double(r.y0), "x1": Double(r.x1), "y1": Double(r.y1)]
        }
        meta["region_mode"] = regions.mode.rawValue
        meta["regions"] = regions.isEmpty ? [rectDict(.full)] : regions.list.map(rectDict)
        if regions.mode == .grid { meta["grid_rows"] = regions.rows; meta["grid_cols"] = regions.cols }
        if let ref = regions.reference { meta["reference"] = rectDict(ref) }
        meta["reference_correction"] = params.useReference
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: base.appendingPathExtension("json"))
        }

        var newLogger: AnalysisLogger?
        if recordSettings.writeCSV {
            let comment = "GasCam analysis log for \(movURL.lastPathComponent)\nt_s = seconds since recording start; coordinates normalised (0..1, origin top-left of upright frame)"
            newLogger = AnalysisLogger(url: base.appendingPathExtension("csv"), comment: comment,
                                       regionCount: regions.regionCount)
        }
        procLock.lock()
        logger = newLogger
        recordingT0 = nil
        procLock.unlock()

        camera.videoQueue.async { self.recorder.begin(cfg) }
        isRecording = true
        recordingStart = Date()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingStart = nil
        procLock.lock()
        let lg = logger
        logger = nil
        procLock.unlock()
        lg?.close()

        let toPhotos = recordSettings.saveToPhotos
        camera.videoQueue.async {
            let dropped = self.recorder.framesDropped
            let written = self.recorder.framesWritten
            let duration = self.recorder.recordedDuration
            self.recorder.finish { url, err in
                DispatchQueue.main.async {
                    if let url {
                        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
                        let mbps = duration > 0 ? bytes * 8 / duration / 1_000_000 : 0
                        let fps = duration > 0 ? Double(written) / duration : 0
                        self.toast = L("已保存") + " \(url.lastPathComponent)\n"
                            + String(format: L("实际码率 %.1f Mb/s · 实际帧率 %.1f fps · 丢帧 %d"), mbps, fps, dropped)
                        if toPhotos { self.saveVideoToPhotos(url) }
                    } else {
                        self.toast = L("录制失败") + ": \(err ?? L("未知错误"))"
                    }
                }
            }
        }
    }

    private func saveVideoToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.toast = L("未获得相册权限，录像保存在“文件”App → GasCam") }
                return
            }
            var localID: String?
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = false
                opts.originalFilename = url.lastPathComponent
                req.addResource(with: .video, fileURL: url, options: opts)
                localID = req.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { ok, error in
                if ok, let id = localID { PhotoLinks.set(id, for: url.lastPathComponent) }
                DispatchQueue.main.async {
                    self.toast = ok ? L("已存入相册（原文件也在“文件”App → GasCam）")
                        : L("存入相册失败") + ": \(error?.localizedDescription ?? "")"
                }
            })
        }
    }

    // MARK: - Video file analysis

    func openVideo(url: URL) {
        if isRecording { stopRecording() }
        fileSource.stop()
        camera.stop()
        procLock.lock()
        acceptCamera = false
        acceptFile = true
        analyzer = nil
        downsampler = nil
        armed = true            // recorded video: baseline = its first frames
        pendingRebaseline = true
        lastAnalysisT = -1
        lastPublishT = -1
        lastDisplayT = -1
        chartBuf.removeAll()
        chartT0 = nil
        lastChartT = -1
        procMarks = VideoMarks()
        procVideoScale = nil
        procLock.unlock()
        renderer?.clear()
        chart = []
        fileSource.cancelScan()
        scanRaw = []
        scanCoarse = CoarseScan()
        videoCurve = []
        videoScale = nil
        scanProgress = 0
        marks = VideoMarks()
        scrubTime = nil
        currentFileURL = url
        source = .file(name: url.lastPathComponent)
        playbackFinished = false
        playbackPaused = false
        playbackTime = 0
        result = GasFrameResult()
        fileSource.speed = playbackSpeed
        fileSource.start(url: url)
    }

    func restartVideo() {
        if let url = currentFileURL { openVideo(url: url) }
    }

    /// Jump to a position in the video. Baseline, arrival map and the full curve are kept; the
    /// picture, heat map and FLOW show the new position (a short pre-roll warms up the analysis).
    /// Press BASELINE to take a new reference image from here.
    func seekVideo(to t: Double) {
        guard case .file = source else { return }
        let target = min(max(0, t), max(0, playbackDuration))
        procLock.lock()
        pendingSeekReset = true
        forceAnalyze = true
        lastAnalysisT = -1
        lastPublishT = -1
        lastDisplayT = -1
        procLock.unlock()
        playbackFinished = false
        playbackTime = target
        fileSource.seek(to: target, preroll: params.flowLagSeconds + 0.15)
    }

    // Live scrubbing from the progress bar.
    func beginScrub() {
        guard case .file = source else { return }
        if scrubTime == nil { scrubWasPaused = playbackPaused }
        playbackPaused = true
    }

    func scrub(to t: Double) {
        guard case .file = source else { return }
        scrubTime = t
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastScrubSeek >= 0.08 {
            lastScrubSeek = now
            pendingScrubTarget = nil
            seekVideo(to: t)
        } else {
            let first = pendingScrubTarget == nil
            pendingScrubTarget = t
            if first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                    guard let self, let p = self.pendingScrubTarget, self.scrubTime != nil else { return }
                    self.pendingScrubTarget = nil
                    self.lastScrubSeek = ProcessInfo.processInfo.systemUptime
                    self.seekVideo(to: p)
                }
            }
        }
    }

    func endScrub(at t: Double) {
        guard case .file = source else { return }
        pendingScrubTarget = nil
        scrubTime = nil
        seekVideo(to: t)
        playbackPaused = scrubWasPaused
    }

    // MARK: - Full-length curve of a video

    private func startScan() {
        guard case .file = source else { return }
        scanProgress = 0
        let regs = regions
        let channel = params.channel
        var local: [ChartSample] = []
        var coarse = CoarseScan()
        var ds: FrameDownsampler?
        var masks: RegionMasks?
        var lastCoarseT = -Double.infinity
        fileSource.scan(handler: { pb, t in
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if ds == nil {
                let (gw, gh) = FrameDownsampler.gridSize(forFrameWidth: w, height: h)
                ds = FrameDownsampler(width: gw, height: gh)
                masks = RegionMasks(regions: regs, width: gw, height: gh)
                coarse = CoarseScan(gridWidth: gw, gridHeight: gh, regions: regs, channel: channel)
            }
            guard let d = ds, let m = masks, d.downsample(pb) else { return }
            let means = m.means(bgra: d.pixels, bytesPerRow: d.bytesPerRow)
            local.append(ChartSample(t: t, r: means.union.r, g: means.union.g, b: means.union.b,
                                     response: 0, phase: 0, regions: means.regions, ref: means.reference))
            if t - lastCoarseT >= 1.0 / 15 {
                lastCoarseT = t
                coarse.add(d, time: t, sampleIndex: local.count - 1)
            }
        }, progress: { [weak self] p in
            self?.scanProgress = p
        }, completion: { [weak self] ok in
            guard let self else { return }
            if ok {
                self.scanRaw = local
                self.scanCoarse = coarse
                self.scanProgress = 1
                self.rebuildVideoCurve()
            }
        })
    }

    private func scheduleRescan() {
        rescanWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.startScan() }
        rescanWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Fill phase bands and ΔS% (all regions together and per region) of the scanned curve from the
    /// current baseline / arrival marks, and work out the whole-file heat-map scale.
    private func rebuildVideoCurve() {
        guard case .file = source, !scanRaw.isEmpty else { return }
        let m = marks
        let p = params
        let ch = p.channel
        func pol(_ v: Float) -> Float {
            switch p.polarity {
            case .decrease: return -v
            case .increase: return v
            case .both: return abs(v)
            }
        }
        // reference correction: factor = reference at baseline start / reference now
        var refAnchor: Float?
        if p.useReference, let b0 = m.baselineStart,
           let first = scanRaw.first(where: { $0.t >= b0 - 1e-6 }), let rf = first.ref {
            refAnchor = ch.value(r: rf.r, g: rf.g, b: rf.b)
        }
        func factor(_ s: ChartSample) -> Float {
            guard let a = refAnchor, let rf = s.ref else { return 1 }
            let now = ch.value(r: rf.r, g: rf.g, b: rf.b)
            return now > 1 ? a / now : 1
        }
        let nReg = scanRaw.first?.regions.count ?? 0
        var ref: Float = 0
        var regRef = [Float](repeating: 0, count: nReg)
        if let b0 = m.baselineStart, let b1 = m.baselineEnd {
            let base = scanRaw.filter { $0.t >= b0 - 1e-6 && $0.t <= b1 + 1e-6 }
            if !base.isEmpty {
                for s in base {
                    let f = factor(s)
                    ref += ch.value(r: s.r, g: s.g, b: s.b) * f
                    for k in 0..<min(nReg, s.regions.count) {
                        let c = s.regions[k]
                        regRef[k] += ch.value(r: c.r, g: c.g, b: c.b) * f
                    }
                }
                ref /= Float(base.count)
                for k in 0..<nReg { regRef[k] /= Float(base.count) }
            }
        }
        videoCurve = scanRaw.map { s in
            var o = s
            if let b0 = m.baselineStart, s.t >= b0 {
                if let b1 = m.baselineEnd, s.t > b1 {
                    o.phase = (m.firstArrival.map { s.t >= $0 } ?? false) ? 3 : 2
                } else {
                    o.phase = 1
                }
            }
            if ref > 0 && o.phase >= 2 {
                let f = factor(s)
                o.response = pol(100 * (ch.value(r: s.r, g: s.g, b: s.b) * f - ref) / ref)
                o.regionResponse = (0..<min(nReg, s.regions.count)).map { k in
                    let c = s.regions[k]
                    let r0 = regRef[k]
                    return r0 > 0 ? pol(100 * (ch.value(r: c.r, g: c.g, b: c.b) * f - r0) / r0) : 0
                }
            }
            return o
        }
        computeVideoScale()
    }

    /// One heat-map scale for the whole video: 99th-percentile response of every frame after the
    /// baseline (coarse grid), robust maximum over time.
    private func computeVideoScale() {
        scaleWork?.cancel()
        let m = marks
        let p = params
        let coarse = scanCoarse
        let raw = scanRaw
        guard p.autoScale, let b0 = m.baselineStart, let b1 = m.baselineEnd, coarse.frames > 0,
              coarse.channel == p.channel else {
            setVideoScale(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            let v = coarse.scale(baseline: b0...b1, params: p, samples: raw)
            DispatchQueue.main.async { self?.setVideoScale(v) }
        }
        scaleWork = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    private func setVideoScale(_ v: Float?) {
        videoScale = v
        procLock.lock(); procVideoScale = v; procLock.unlock()
    }

    /// Pause and move by `frames` frames (negative = backwards).
    func stepFrame(_ frames: Int) {
        guard case .file = source else { return }
        playbackPaused = true
        seekVideo(to: playbackTime + Double(frames) / fileSource.frameRate)
    }

    func closeVideo() {
        fileSource.stop()
        procLock.lock()
        acceptFile = false
        acceptCamera = true
        analyzer = nil
        downsampler = nil
        armed = false
        lastAnalysisT = -1
        lastPublishT = -1
        lastDisplayT = -1
        chartBuf.removeAll()
        chartT0 = nil
        lastChartT = -1
        procLock.unlock()
        renderer?.clear()
        chart = []
        fileSource.cancelScan()
        scanRaw = []
        videoCurve = []
        scrubTime = nil
        currentFileURL = nil
        source = .camera
        updateEffectiveRate()
        result = GasFrameResult()
        camera.start()
    }

    // MARK: - Result image

    /// Saves the current frame + overlay + arrow as PNG to Documents (and Photos).
    func saveResultImage() {
        guard let renderer, let composite = renderer.currentComposite() else {
            toast = L("还没有画面")
            return
        }
        let r = result
        let regs = regions
        let stamp = Self.stampFormatter.string(from: Date())
        let toPhotos = recordSettings.saveToPhotos
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cg = renderer.ciContext.createCGImage(composite, from: composite.extent) else { return }
            let size = CGSize(width: cg.width, height: cg.height)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
                ResultDrawing.draw(in: ctx.cgContext, size: size, regions: regs, result: r)
            }
            let url = Self.documentsURL.appendingPathComponent("GasCam_result_\(stamp).png")
            if let png = image.pngData() { try? png.write(to: url) }
            DispatchQueue.main.async { self.toast = L("结果图已保存") + ": \(url.lastPathComponent)" }
            if toPhotos {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else { return }
                    PHPhotoLibrary.shared().performChanges({
                        _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }, completionHandler: nil)
                }
            }
        }
    }

    // MARK: - Frame handling (camera queue or playback queue)

    private func handle(_ pb: CVPixelBuffer, _ pts: CMTime, fromCamera: Bool, preroll: Bool) {
        procLock.lock()
        defer { procLock.unlock() }
        guard fromCamera ? acceptCamera : acceptFile else { return }

        if fromCamera { recorder.append(pb, time: pts) }
        if !preroll { renderer?.enqueue(pb) }

        let t = pts.seconds
        guard t.isFinite else { return }

        // measured frame rate
        if fpsT0 < 0 || t < fpsT0 {
            fpsT0 = t
            fpsN = 0
        }
        fpsN += 1
        if t - fpsT0 >= 1 {
            fpsValue = Double(fpsN - 1) / (t - fpsT0)
            fpsT0 = t
            fpsN = 1
        }

        // (re)create the analysis grid for this frame size
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if analyzer == nil || w != frameW || h != frameH {
            frameW = w
            frameH = h
            let (gw, gh) = FrameDownsampler.gridSize(forFrameWidth: w, height: h)
            downsampler = FrameDownsampler(width: gw, height: gh)
            analyzer = GasAnalyzer(width: gw, height: gh, params: procParams, regions: procRegions)
            procMasks = RegionMasks(regions: procRegions, width: gw, height: gh)
            overlayBuffer?.deallocate()
            overlayBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: gw * gh * 4)
            overlayBuffer?.initialize(repeating: 0, count: gw * gh * 4)
            overlayCount = gw * gh * 4
            paramsDirty = false
            regionsDirty = false
            let aspect = CGFloat(w) / CGFloat(max(h, 1))
            DispatchQueue.main.async { self.frameAspect = aspect }
        }
        guard let an = analyzer, let ds = downsampler, let masks = procMasks else { return }

        if paramsDirty { an.update(params: procParams); paramsDirty = false }
        if regionsDirty {
            an.update(regions: procRegions)
            procMasks = RegionMasks(regions: procRegions, width: an.width, height: an.height)
            regionsDirty = false
        }
        an.videoMode = !fromCamera
        an.videoScale = procVideoScale
        an.baselineTargetFrames = procBaselineTarget
        if pendingRebaseline { an.resetBaseline(); pendingRebaseline = false }
        if pendingResetArrivals { an.resetArrivals(keepGhost: false); pendingResetArrivals = false }
        if pendingSeekReset { an.seekReset(); pendingSeekReset = false }

        // Video: arrivals are only registered during continuous forward playback,
        // never while scrubbing, stepping or pre-rolling.
        var register = fromCamera
        if !fromCamera && !preroll {
            let continuous = lastDisplayT >= 0 && t > lastDisplayT && t - lastDisplayT < 0.25
            register = continuous && !procPaused
            lastDisplayT = t
        }

        // analysis rate limit (the frame shown after a seek is always analysed)
        let forced = !preroll && forceAnalyze
        if !forced && lastAnalysisT >= 0 && t >= lastAnalysisT && t - lastAnalysisT < 0.9 / max(1, procParams.analysisRate) {
            return
        }
        if forced { forceAnalyze = false }
        lastAnalysisT = t
        guard ds.downsample(pb) else { return }

        var r = GasFrameResult()
        r.time = t
        if armed {
            r = an.process(bgra: ds.pixels, bytesPerRow: ds.bytesPerRow, time: t, registerArrivals: register)
        }
        if preroll { return }       // pre-roll only warms up EMA / FLOW history
        let means = masks.means(bgra: ds.pixels, bytesPerRow: ds.bytesPerRow)
        let mr = means.union.r, mg = means.union.g, mb = means.union.b
        r.roiMeanR = mr
        r.roiMeanG = mg
        r.roiMeanB = mb
        r.refMean = means.reference
        if r.regions.count != means.regions.count {
            r.regions = [RegionStat](repeating: RegionStat(), count: means.regions.count)
        }
        for k in 0..<means.regions.count { r.regions[k].raw = means.regions[k] }
        if r.displayScale <= 0 { r.displayScale = procParams.autoScale ? procParams.autoScaleFloor : procParams.displayMaxPercent }

        if fromCamera {
            camera.autoExposureStep(level: means.union.maxChannel)
        } else {
            // remember when the baseline was taken / gas arrived, in video time
            var changed = false
            if case .baseline = r.phase, r.baselineFrames <= 1 {
                procMarks = VideoMarks(baselineStart: t, baselineEnd: nil, firstArrival: nil); changed = true
            }
            if case .monitoring = r.phase, procMarks.baselineStart != nil, procMarks.baselineEnd == nil {
                procMarks.baselineEnd = t; changed = true
            }
            if case .detected = r.phase, register, procMarks.firstArrival == nil, procMarks.baselineEnd != nil {
                procMarks.firstArrival = t; changed = true
            }
            if changed {
                let m = procMarks
                DispatchQueue.main.async {
                    self.marks = m
                    self.rebuildVideoCurve()
                }
            }
        }

        // live curve for the camera (≤ 30 points/s, last 125 s); videos use the pre-scanned curve
        let tc: Double
        if fromCamera {
            if chartT0 == nil { chartT0 = t }
            tc = t - (chartT0 ?? t)
        } else {
            tc = t
        }
        if tc < lastChartT { chartBuf.removeAll(); lastChartT = -1 }
        if fromCamera && (lastChartT < 0 || tc - lastChartT >= 1.0 / 30) {
            let code: UInt8
            switch r.phase {
            case .waiting: code = 0
            case .baseline: code = 1
            case .monitoring: code = 2
            case .detected: code = 3
            }
            chartBuf.append(ChartSample(t: tc, r: mr, g: mg, b: mb, response: r.meanResponse, phase: code,
                                        regions: means.regions, regionResponse: r.regions.map { $0.meanResponse },
                                        ref: means.reference))
            lastChartT = tc
            if let cut = chartBuf.firstIndex(where: { tc - $0.t <= 125 }), cut > 0 {
                chartBuf.removeFirst(cut)
            }
        }

        // overlay
        if armed && an.ready && procDisplay.overlay != .live, let buf = overlayBuffer {
            an.renderOverlay(mode: procDisplay.overlay, opacity: procDisplay.overlayOpacity,
                             scale: r.displayScale, into: buf)
            renderer?.setOverlay(Self.makeImage(buf, width: an.width, height: an.height))
        } else {
            renderer?.setOverlay(nil)
        }

        if let lg = logger {
            if recordingT0 == nil { recordingT0 = t }
            lg.log(t: t - (recordingT0 ?? t), result: r)
        }

        // publish ~15 Hz
        if lastPublishT < 0 || t < lastPublishT || t - lastPublishT >= 1.0 / 15 {
            lastPublishT = t
            let hist: Histogram? = procDisplay.showHistogram
                ? Histogram.compute(bgra: ds.pixels, width: ds.width, height: ds.height, bytesPerRow: ds.bytesPerRow)
                : nil
            let fps = fpsValue
            let curve: [ChartSample]? = procDisplay.showChart ? chartBuf : nil
            DispatchQueue.main.async {
                self.result = r
                if let hist { self.histogram = hist }
                if let curve { self.chart = curve }
                self.measuredFPS = fps
            }
        }
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func makeImage(_ rgba: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> CIImage? {
        let data = Data(bytes: rgba, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: sRGB,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: - Persistence

    private static func load<T: Decodable>(_ key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return v
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Draws ROI, arrow and markers into a bitmap (used for the saved result image).
enum ResultDrawing {
    static func draw(in ctx: CGContext, size: CGSize, regions: AnalysisRegions, result r: GasFrameResult) {
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        func box(_ q: NormRect) -> CGRect {
            CGRect(x: q.x0 * size.width, y: q.y0 * size.height, width: q.width * size.width, height: q.height * size.height)
        }
        let lw = max(2, size.width / 250)
        ctx.setLineWidth(lw)
        let font = UIFont.monospacedSystemFont(ofSize: max(14, size.width / 45), weight: .bold)
        UIGraphicsPushContext(ctx)
        for (k, q) in regions.list.enumerated() {
            let c = AnalysisRegions.color(k)
            let col = UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.setStrokeColor(col.cgColor)
            ctx.stroke(box(q))
            ("\(k + 1)" as NSString).draw(at: CGPoint(x: q.x0 * size.width + lw * 2, y: q.y0 * size.height + lw),
                                         withAttributes: [.font: font, .foregroundColor: col])
        }
        if let ref = regions.reference {
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineDash(phase: 0, lengths: [lw * 3, lw * 2])
            ctx.stroke(box(ref))
            ctx.setLineDash(phase: 0, lengths: [])
            ("REF" as NSString).draw(at: CGPoint(x: ref.x0 * size.width + lw * 2, y: ref.y0 * size.height + lw),
                                     withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
        UIGraphicsPopContext()
        let roi = regions.bounds
        guard let s = r.source ?? r.lastSource else { return }
        let e = pt(s.earliest), c = pt(s.centroid), src = pt(s.sourcePoint)
        if s.mode == .direction {
            for (color, width) in [(UIColor.black, lw * 4), (UIColor.white, lw * 2.2)] {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.move(to: c)
                ctx.addLine(to: src)
                let ang = atan2(src.y - c.y, src.x - c.x)
                let head = lw * 10
                ctx.move(to: src)
                ctx.addLine(to: CGPoint(x: src.x - head * cos(ang - 0.45), y: src.y - head * sin(ang - 0.45)))
                ctx.move(to: src)
                ctx.addLine(to: CGPoint(x: src.x - head * cos(ang + 0.45), y: src.y - head * sin(ang + 0.45)))
                ctx.strokePath()
            }
        }
        ctx.setStrokeColor(UIColor.yellow.cgColor)
        ctx.setLineWidth(lw * 1.5)
        let rr = lw * 6
        ctx.strokeEllipse(in: CGRect(x: e.x - rr, y: e.y - rr, width: rr * 2, height: rr * 2))
        ctx.setStrokeColor(UIColor.red.cgColor)
        ctx.setLineWidth(lw * 2)
        ctx.move(to: CGPoint(x: src.x - rr, y: src.y - rr)); ctx.addLine(to: CGPoint(x: src.x + rr, y: src.y + rr))
        ctx.move(to: CGPoint(x: src.x + rr, y: src.y - rr)); ctx.addLine(to: CGPoint(x: src.x - rr, y: src.y + rr))
        ctx.strokePath()

        let text = String(format: "source %@ %.0f°  conf %.2f  first contact (%.2f, %.2f)",
                          s.mode == .direction ? "dir" : "point", s.angleDeg, s.confidence,
                          s.earliest.x, s.earliest.y)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: max(14, size.width / 40), weight: .semibold),
            .foregroundColor: UIColor.white,
            .backgroundColor: UIColor.black.withAlphaComponent(0.6),
        ]
        UIGraphicsPushContext(ctx)
        (text as NSString).draw(at: CGPoint(x: 12, y: roi.y1 * size.height + 12), withAttributes: attrs)
        UIGraphicsPopContext()
    }
}

/// Coarse (1/4 grid) per-frame signal maps of a video, used for the whole-file colour scale.
struct CoarseScan {
    static let block = 4
    private(set) var width = 0
    private(set) var height = 0
    private(set) var channel: SignalChannel = .red
    /// Signal × 100 per cell, frame after frame.
    private(set) var data: [UInt16] = []
    private(set) var times: [Double] = []
    private(set) var sampleIndex: [Int] = []
    /// Cells inside the analysis regions.
    private(set) var cells: [Int32] = []
    var frames: Int { times.count }

    init() {}

    init(gridWidth gw: Int, gridHeight gh: Int, regions: AnalysisRegions, channel: SignalChannel) {
        width = max(1, gw / Self.block)
        height = max(1, gh / Self.block)
        self.channel = channel
        let m = RegionMasks(regions: regions, width: width, height: height)
        cells = (0..<(width * height)).filter { m.bits[$0] != 0 }.map { Int32($0) }
    }

    mutating func add(_ ds: FrameDownsampler, time: Double, sampleIndex idx: Int) {
        guard width > 0 else { return }
        let px = ds.pixels
        let b = Self.block
        let inv = 1 / Float(b * b)
        for cy in 0..<height {
            for cx in 0..<width {
                var sum: Float = 0
                for y in (cy * b)..<min(ds.height, cy * b + b) {
                    let row = px + y * ds.bytesPerRow
                    for x in (cx * b)..<min(ds.width, cx * b + b) {
                        let p = row + x * 4
                        sum += channel.value(r: Float(p[2]), g: Float(p[1]), b: Float(p[0]))
                    }
                }
                data.append(UInt16(max(0, min(65535, sum * inv * 100))))
            }
        }
        times.append(time)
        sampleIndex.append(idx)
    }

    /// Robust maximum (over time) of the 99th-percentile response, × 1.1, never below the floor.
    func scale(baseline: ClosedRange<Double>, params p: GasParams, samples: [ChartSample]) -> Float? {
        let n = width * height
        guard n > 0, !cells.isEmpty else { return nil }
        func refValue(_ f: Int) -> Float? {
            guard p.useReference, sampleIndex[f] < samples.count, let rf = samples[sampleIndex[f]].ref else { return nil }
            return channel.value(r: rf.r, g: rf.g, b: rf.b)
        }
        var anchor: Float?
        var mean = [Float](repeating: 0, count: n)
        var nb: Float = 0
        for f in 0..<frames where baseline.contains(times[f]) {
            let rv = refValue(f)
            if anchor == nil { anchor = rv }
            let k = (anchor != nil && (rv ?? 0) > 1) ? anchor! / rv! : 1
            let base = f * n
            for c in cells { mean[Int(c)] += Float(data[base + Int(c)]) * k }
            nb += 1
        }
        guard nb > 0 else { return nil }
        for c in cells { mean[Int(c)] /= nb }
        var perFrame: [Float] = []
        var vals = [Float](repeating: 0, count: cells.count)
        for f in 0..<frames where times[f] > baseline.upperBound {
            let rv = refValue(f)
            let k = (anchor != nil && (rv ?? 0) > 1) ? anchor! / rv! : 1
            let base = f * n
            var m = 0
            for c in cells {
                let mu = mean[Int(c)]
                guard mu > 500 else { continue }          // signal > 5 (dark / invalid cells skipped)
                var v = 100 * (Float(data[base + Int(c)]) * k - mu) / mu
                switch p.polarity {
                case .decrease: v = -v
                case .increase: break
                case .both: v = abs(v)
                }
                vals[m] = v
                m += 1
            }
            guard m > 0 else { continue }
            var slice = Array(vals[0..<m])
            slice.sort()
            perFrame.append(slice[min(m - 1, Int(Float(m) * 0.99))])
        }
        guard !perFrame.isEmpty else { return nil }
        perFrame.sort()
        let robust = perFrame[min(perFrame.count - 1, Int(Float(perFrame.count) * 0.995))]
        return max(p.autoScaleFloor, robust * 1.1)
    }
}

/// Recording file name → Photos asset (so a rename can replace the Photos copy).
enum PhotoLinks {
    private static let key = "photos.links"
    static func id(for name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[name]
    }
    static func set(_ id: String?, for name: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[name] = id
        UserDefaults.standard.set(d, forKey: key)
    }
}
