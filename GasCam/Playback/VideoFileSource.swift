import Foundation
import AVFoundation
import CoreGraphics

/// Plays a recorded video through the same analysis pipeline as the live camera
/// (frames are rotated upright and delivered as BGRA at real-time pace × speed).
/// Supports seeking and single-frame stepping. Works in the iOS Simulator (no camera needed).
final class VideoFileSource {
    /// Frame callback on the playback queue.
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    /// (current s, duration s) on the main thread, ~10 Hz.
    var onProgress: ((Double, Double) -> Void)?
    /// Main thread. nil = finished normally, otherwise an error message.
    var onFinish: ((String?) -> Void)?

    private struct Loaded {
        let asset: AVAsset
        let track: AVAssetTrack
        let size: CGSize
        let transform: CGAffineTransform
        let fps: Float
        let duration: CMTime
    }

    private let queue = DispatchQueue(label: "gascam.file.playback", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var pausedFlag = false
    private var speedValue: Double = 1
    private var loaded: Loaded?

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return pausedFlag }
        set { lock.lock(); pausedFlag = newValue; lock.unlock() }
    }

    /// Playback speed. 0 = as fast as the analysis can go.
    var speed: Double {
        get { lock.lock(); defer { lock.unlock() }; return speedValue }
        set { lock.lock(); speedValue = newValue; lock.unlock() }
    }

    /// Nominal frame rate of the loaded file (30 until a file is loaded).
    var frameRate: Double {
        lock.lock(); defer { lock.unlock() }
        if let l = loaded, l.fps > 1 { return Double(l.fps) }
        return 30
    }

    private func bumpGeneration() -> Int {
        lock.lock()
        generation += 1
        let g = generation
        lock.unlock()
        return g
    }

    private func isCurrent(_ g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return g == generation
    }

    func start(url: URL) {
        let gen = bumpGeneration()
        paused = false
        lock.lock(); loaded = nil; lock.unlock()
        Task {
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    throw NSError(domain: "GasCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件中没有视频轨道"])
                }
                let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let duration = try await asset.load(.duration)
                let l = Loaded(asset: asset, track: track, size: size, transform: transform, fps: fps, duration: duration)
                self.lock.lock(); self.loaded = l; self.lock.unlock()
                self.queue.async { self.readLoop(l, from: 0, generation: gen) }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { self.onFinish?(msg) }
            }
        }
    }

    /// Jump to `seconds`. When paused, exactly one frame (the one at the new position) is delivered.
    func seek(to seconds: Double) {
        lock.lock()
        let l = loaded
        generation += 1
        let gen = generation
        lock.unlock()
        guard let l else { return }
        queue.async { self.readLoop(l, from: seconds, generation: gen) }
    }

    func stop() {
        _ = bumpGeneration()
    }

    private func readLoop(_ l: Loaded, from startSeconds: Double, generation gen: Int) {
        guard isCurrent(gen) else { return }
        // Video composition that applies the track's rotation (portrait iPhone videos).
        let rect = CGRect(origin: .zero, size: l.size).applying(l.transform)
        let renderSize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        let comp = AVMutableVideoComposition()
        comp.renderSize = renderSize
        let rate = l.fps > 1 ? l.fps : 30
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: l.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: l.track)
        let fixed = l.transform.concatenating(CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        layer.setTransform(fixed, at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: l.asset)
        } catch {
            let msg = error.localizedDescription
            DispatchQueue.main.async { self.onFinish?(msg) }
            return
        }
        let total = l.duration.seconds
        let lastFrame = max(0, total - 1 / Double(rate))
        let start = min(max(0, startSeconds), lastFrame)
        if start > 0 {
            let s = CMTime(seconds: start, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(start: s, end: l.duration)
        }
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [l.track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = comp
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            DispatchQueue.main.async { self.onFinish?("无法读取该视频") }
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "无法读取该视频"
            DispatchQueue.main.async { self.onFinish?(msg) }
            return
        }

        var anchorPTS: Double?
        var anchorWall = 0.0
        var anchorSpeed = -1.0
        var lastPTS = -1.0
        var lastProgress = 0.0
        var delivered = 0
        let clock = { ProcessInfo.processInfo.systemUptime }

        while isCurrent(gen) {
            // While paused, keep showing the frame at the current position (the first one is always delivered).
            if paused && delivered > 0 {
                Thread.sleep(forTimeInterval: 0.03)
                anchorPTS = nil
                continue
            }
            guard let sb = output.copyNextSampleBuffer() else { break }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let ts = pts.seconds
            let sp = speed
            if anchorPTS == nil || sp != anchorSpeed {
                anchorPTS = lastPTS >= 0 ? lastPTS : ts
                anchorWall = clock()
                anchorSpeed = sp
            }
            if sp > 0, let a = anchorPTS, delivered > 0 {
                let wait = anchorWall + (ts - a) / sp - clock()
                if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 1)) }
            }
            guard isCurrent(gen) else { break }
            frameHandler?(pb, pts)
            delivered += 1
            lastPTS = ts
            let now = clock()
            if delivered == 1 || now - lastProgress > 0.1 {
                lastProgress = now
                DispatchQueue.main.async { self.onProgress?(ts, total) }
            }
        }
        let failed = reader.status == .failed ? (reader.error?.localizedDescription ?? "读取失败") : nil
        reader.cancelReading()
        if isCurrent(gen) {
            DispatchQueue.main.async {
                self.onProgress?(total, total)
                self.onFinish?(failed)
            }
        }
    }
}
