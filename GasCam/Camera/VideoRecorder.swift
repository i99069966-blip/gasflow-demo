import Foundation
import AVFoundation

/// AVAssetWriter-based recorder with explicit codec + bitrate.
/// All methods must be called on the same serial queue that delivers frames.
final class VideoRecorder {
    struct Config {
        var url: URL
        var fps: Double
        var codec: VideoCodec
        var bitrateMbps: Double
    }

    private var config: Config?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private(set) var startTime: CMTime?
    private(set) var framesWritten = 0
    private(set) var framesDropped = 0
    private(set) var lastError: String?

    var isRecording: Bool { config != nil }

    func begin(_ cfg: Config) {
        config = cfg
        writer = nil
        input = nil
        adaptor = nil
        sessionStarted = false
        startTime = nil
        framesWritten = 0
        framesDropped = 0
        lastError = nil
    }

    func append(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let cfg = config else { return }
        if writer == nil {
            setupWriter(cfg, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let w = writer, let inp = input, let ad = adaptor, w.status == .writing else { return }
        if !sessionStarted {
            w.startSession(atSourceTime: time)
            sessionStarted = true
            startTime = time
        }
        if inp.isReadyForMoreMediaData {
            if ad.append(pixelBuffer, withPresentationTime: time) {
                framesWritten += 1
            } else {
                lastError = w.error?.localizedDescription
            }
        } else {
            framesDropped += 1
        }
    }

    func finish(completion: @escaping (URL?, String?) -> Void) {
        guard let cfg = config else {
            completion(nil, nil)
            return
        }
        config = nil
        guard let w = writer, sessionStarted else {
            writer?.cancelWriting()
            writer = nil
            completion(nil, lastError ?? "没有写入任何帧")
            return
        }
        input?.markAsFinished()
        w.finishWriting {
            completion(w.status == .completed ? cfg.url : nil, w.error?.localizedDescription)
        }
        writer = nil
        input = nil
        adaptor = nil
    }

    private func setupWriter(_ cfg: Config, width: Int, height: Int) {
        do {
            let w = try AVAssetWriter(outputURL: cfg.url, fileType: .mov)
            let fpsInt = max(1, Int(cfg.fps.rounded()))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(cfg.bitrateMbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: fpsInt,
                AVVideoMaxKeyFrameIntervalKey: fpsInt,
            ]
            if cfg.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let settings: [String: Any] = [
                AVVideoCodecKey: cfg.codec.avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: nil)
            guard w.canAdd(inp) else {
                lastError = "无法添加视频轨道"
                config = nil
                return
            }
            w.add(inp)
            guard w.startWriting() else {
                lastError = w.error?.localizedDescription ?? "startWriting 失败"
                config = nil
                return
            }
            writer = w
            input = inp
            adaptor = ad
        } catch {
            lastError = error.localizedDescription
            config = nil
        }
    }
}

/// Per-analysis-frame CSV log written next to the recording.
final class AnalysisLogger {
    let url: URL
    private let handle: FileHandle
    private var buffer = ""
    private var rows = 0

    static let header = "t_s,phase,mean_resp_pct,max_resp_pct,active_frac,hotspot_x,hotspot_y,arrived_px,src_mode,src_angle_deg,src_conf,entry_x,entry_y,src_x,src_y\n"

    init?(url: URL, comment: String) {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        buffer = comment.split(separator: "\n").map { "# \($0)" }.joined(separator: "\n") + "\n" + Self.header
    }

    func log(t: Double, result r: GasFrameResult) {
        let phase: String
        switch r.phase {
        case .waiting: phase = "waiting"
        case .baseline: phase = "baseline"
        case .monitoring: phase = "monitoring"
        case .detected: phase = "detected"
        }
        var fields: [String] = [
            String(format: "%.4f", t), phase,
            String(format: "%.3f", r.meanResponse), String(format: "%.3f", r.maxResponse),
            String(format: "%.4f", r.activeFraction),
            r.hotspot.map { String(format: "%.4f", $0.x) } ?? "",
            r.hotspot.map { String(format: "%.4f", $0.y) } ?? "",
        ]
        if let s = r.source {
            fields += ["\(s.arrivedCount)", s.mode.rawValue, String(format: "%.1f", s.angleDeg),
                       String(format: "%.3f", s.confidence),
                       String(format: "%.4f", s.earliest.x), String(format: "%.4f", s.earliest.y),
                       String(format: "%.4f", s.sourcePoint.x), String(format: "%.4f", s.sourcePoint.y)]
        } else {
            fields += ["0", "", "", "", "", "", "", ""]
        }
        buffer += fields.joined(separator: ",") + "\n"
        rows += 1
        if rows % 60 == 0 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty, let d = buffer.data(using: .utf8) else { return }
        try? handle.write(contentsOf: d)
        buffer = ""
    }

    func close() {
        flush()
        try? handle.close()
    }
}
