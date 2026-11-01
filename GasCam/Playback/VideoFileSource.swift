import Foundation
import AVFoundation
import CoreGraphics

/// Plays a recorded video through the same analysis pipeline as the live camera
/// (frames are rotated upright and delivered as BGRA at real-time pace × speed).
/// Use it to test on recorded experiments – and in the iOS Simulator, which has no camera.
final class VideoFileSource {
    /// Frame callback on the playback queue.
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    /// (current s, duration s) on the main thread, ~10 Hz.
    var onProgress: ((Double, Double) -> Void)?
    /// Main thread. nil = finished normally, otherwise an error message.
    var onFinish: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "gascam.file.playback", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var pausedFlag = false
    private var speedValue: Double = 1

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return pausedFlag }
        set { lock.lock(); pausedFlag = newValue; lock.unlock() }
    }

    /// Playback speed. 0 = as fast as the analysis can go.
    var speed: Double {
        get { lock.lock(); defer { lock.unlock() }; return speedValue }
        set { lock.lock(); speedValue = newValue; lock.unlock() }
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
        Task {
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    throw NSError(domain: "GasCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件中没有视频轨道"])
                }
                let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let duration = try await asset.load(.duration)
                self.queue.async {
                    self.readLoop(asset: asset, track: track, size: size, transform: transform,
                                  fps: fps, duration: duration, generation: gen)
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { self.onFinish?(msg) }
            }
        }
    }

    func stop() {
        _ = bumpGeneration()
    }

    private func readLoop(asset: AVAsset, track: AVAssetTrack, size: CGSize, transform: CGAffineTransform,
                          fps: Float, duration: CMTime, generation gen: Int) {
        // Video composition that applies the track's rotation (portrait iPhone videos).
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let renderSize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        let comp = AVMutableVideoComposition()
        comp.renderSize = renderSize
        let rate = fps > 1 ? fps : 30
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let fixed = transform.concatenating(CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        layer.setTransform(fixed, at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            let msg = error.localizedDescription
            DispatchQueue.main.async { self.onFinish?(msg) }
            return
        }
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
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

        let total = duration.seconds
        var anchorPTS: Double?
        var anchorWall = 0.0
        var anchorSpeed = -1.0
        var lastPTS = 0.0
        var lastProgress = 0.0
        let clock = { ProcessInfo.processInfo.systemUptime }

        while isCurrent(gen) {
            if paused {
                Thread.sleep(forTimeInterval: 0.05)
                anchorPTS = nil      // re-anchor after resuming
                continue
            }
            guard let sb = output.copyNextSampleBuffer() else { break }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let ts = pts.seconds
            let sp = speed
            if anchorPTS == nil || sp != anchorSpeed {
                anchorPTS = lastPTS > 0 ? lastPTS : ts
                anchorWall = clock()
                anchorSpeed = sp
            }
            if sp > 0, let a = anchorPTS {
                let wait = anchorWall + (ts - a) / sp - clock()
                if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 1)) }
            }
            frameHandler?(pb, pts)
            lastPTS = ts
            let now = clock()
            if now - lastProgress > 0.1 {
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
