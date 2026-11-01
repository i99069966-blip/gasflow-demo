import Foundation
import AVFoundation
import Combine
import CoreGraphics

/// Owns the AVCaptureSession and every manual control (Blackmagic-style).
///
/// Threading: all AVCaptureDevice configuration runs on `sessionQueue`; `desired` is the
/// sessionQueue-owned source of truth. @Published properties are only touched on the main thread.
final class CameraController: NSObject, ObservableObject {

    // MARK: Session

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "gascam.camera.session")
    let videoQueue = DispatchQueue(label: "gascam.camera.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var isConfigured = false
    private var pollTimer: Timer?

    /// Every frame (BGRA, upright portrait) on `videoQueue`.
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    /// Main thread: a user-initiated change that alters the image (analysis must re-baseline).
    var onSettingsChanged: (() -> Void)?

    private struct Desired {
        var resolution: VideoResolution = .hd1080
        var fps: Double = 30
        var exposureAuto = true
        var iso: Float = 100
        var shutter: Double = 1.0 / 60
        var bias: Float = 0
        var wbAuto = true
        var temperature: Float = 5600
        var tint: Float = 0
        var focusAuto = true
        var lensPosition: Float = 0.5
        var torch: Float = 0
    }
    private var desired = Desired()

    // MARK: Published state (main thread)

    @Published var authorization: AVAuthorizationStatus = .notDetermined
    @Published var isRunning = false
    @Published var lenses: [LensOption] = []
    @Published var currentLensID = ""
    @Published var resolution: VideoResolution = .hd1080
    @Published var frameRate: Double = 30
    @Published var supportedResolutions: [VideoResolution] = [.hd1080]
    @Published var supportedFrameRates: [Double] = [30]

    @Published var exposureAuto = true
    @Published var iso: Float = 100
    @Published var isoRange: ClosedRange<Float> = 25...3200
    @Published var shutter: Double = 1.0 / 60
    @Published var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    @Published var exposureBias: Float = 0
    @Published var biasRange: ClosedRange<Float> = -3...3

    @Published var wbAuto = true
    @Published var temperature: Float = 5600
    @Published var tint: Float = 0

    @Published var focusAuto = true
    @Published var lensPosition: Float = 0.5
    @Published var canManualFocus = true

    @Published var hasTorch = false
    @Published var torchLevel: Float = 0

    @Published var statusMessage: String?

    var shutterAngle: Double { 360 * shutter * frameRate }
    var isFullyLocked: Bool { !exposureAuto && !wbAuto && !focusAuto }

    override init() {
        super.init()
        let d = UserDefaults.standard
        if let r = d.string(forKey: "cam.resolution"), let res = VideoResolution(rawValue: r) {
            resolution = res
            desired.resolution = res
        }
        let f = d.double(forKey: "cam.fps")
        if f > 0 {
            frameRate = f
            desired.fps = f
        }
    }

    // MARK: - Lifecycle

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorization = status
        switch status {
        case .authorized:
            configureIfNeededAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorization = granted ? .authorized : .denied
                    if granted { self.configureIfNeededAndRun() }
                }
            }
        default:
            break
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            // the torch turns itself off with the session; keep the desired level for restart
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configureIfNeededAndRun() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
                if let dev = self.device { self.reapplyManual(dev) }
            }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.isRunning = running
                self.startPolling()
            }
        }
    }

    // MARK: - Configuration (sessionQueue)

    private func configureSession() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified)
        let devs = discovery.devices
        let wide = devs.first { $0.deviceType == .builtInWideAngleCamera && $0.position == .back }
        let wideFOV = Double(wide?.activeFormat.videoFieldOfView ?? 70)
        var options: [LensOption] = []
        for d in devs {
            devicesByID[d.uniqueID] = d
            if d.position == .front {
                options.append(LensOption(id: d.uniqueID, label: "FRONT", sortKey: 1000))
                continue
            }
            let fov = max(1, Double(d.activeFormat.videoFieldOfView))
            let factor = tan(wideFOV / 2 * .pi / 180) / tan(fov / 2 * .pi / 180)
            let label: String
            if factor < 0.8 { label = "0.5x" }
            else if abs(factor - 1) < 0.25 { label = "1x" }
            else { label = "\(Int(factor.rounded()))x" }
            options.append(LensOption(id: d.uniqueID, label: label, sortKey: factor))
        }
        options.sort { $0.sortKey < $1.sortKey }

        session.beginConfiguration()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        if let first = wide ?? devs.first {
            switchInput(to: first)
        } else {
            DispatchQueue.main.async { self.statusMessage = "没有可用的摄像头（模拟器请用“导入视频”测试）" }
        }
        DispatchQueue.main.async { self.lenses = options }
    }

    private func switchInput(to newDevice: AVCaptureDevice) {
        session.beginConfiguration()
        let old = input
        if let old { session.removeInput(old) }
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
                device = newDevice
            } else if let old, session.canAddInput(old) {
                session.addInput(old)
            }
        } catch {
            if let old, session.canAddInput(old) { session.addInput(old) }
            report("切换镜头失败: \(error.localizedDescription)")
        }
        applyConnectionSettings()
        session.commitConfiguration()

        guard let dev = device else { return }
        applyFormat(dev)
        reapplyManual(dev)
        publishDeviceState(dev)
    }

    private func applyConnectionSettings() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        // Portrait buffers: what you see is what is analysed and recorded.
        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        // Stabilisation shifts/warps the image and creates false differences → off.
        if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off }
    }

    private static func dims(_ f: AVCaptureDevice.Format) -> (Int, Int) {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return (Int(d.width), Int(d.height))
    }

    private func bestFormat(_ dev: AVCaptureDevice, _ res: VideoResolution, _ fps: Double) -> AVCaptureDevice.Format? {
        let candidates = dev.formats.filter { f in
            let (w, h) = Self.dims(f)
            guard w == res.width && h == res.height else { return false }
            return f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps + 0.01 && fps <= $0.maxFrameRate + 0.01 }
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            var s = 0
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            if sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { s += 4 }
            else if sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { s += 2 }
            if !f.isVideoBinned { s += 1 }
            return s
        }
        return candidates.max { score($0) < score($1) }
    }

    private func applyFormat(_ dev: AVCaptureDevice) {
        let supportedRes = VideoResolution.allCases.filter { r in
            dev.formats.contains { Self.dims($0) == (r.width, r.height) }
        }
        var res = desired.resolution
        if !supportedRes.contains(res) {
            res = supportedRes.contains(.hd1080) ? .hd1080 : (supportedRes.first ?? .hd1080)
        }
        let rates = CameraPresets.frameRates.filter { bestFormat(dev, res, $0) != nil }
        var fps = desired.fps
        if !rates.contains(fps) {
            fps = rates.filter { $0 <= fps }.max() ?? rates.first ?? 30
        }
        desired.resolution = res
        desired.fps = fps

        if let format = bestFormat(dev, res, fps) {
            session.beginConfiguration()
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = format
                let dur = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                // Keep the pixel values "honest" for measurement.
                if format.isVideoHDRSupported {
                    dev.automaticallyAdjustsVideoHDREnabled = false
                    dev.isVideoHDREnabled = false
                }
                if format.isGlobalToneMappingSupported { dev.isGlobalToneMappingEnabled = false }
                if dev.isLowLightBoostSupported { dev.automaticallyEnablesLowLightBoostWhenAvailable = false }
                dev.unlockForConfiguration()
            } catch {
                report("格式设置失败: \(error.localizedDescription)")
            }
            session.commitConfiguration()
        }

        DispatchQueue.main.async {
            self.supportedResolutions = supportedRes.isEmpty ? [res] : supportedRes
            self.supportedFrameRates = rates.isEmpty ? [fps] : rates
            self.resolution = res
            self.frameRate = fps
        }
    }

    private func reapplyManual(_ dev: AVCaptureDevice) {
        applyExposure()
        applyWhiteBalance()
        applyFocus()
        applyTorch()
    }

    private func publishDeviceState(_ dev: AVCaptureDevice) {
        let fmt = dev.activeFormat
        let isoR = Self.safeRange(fmt.minISO, fmt.maxISO)
        let maxShutter = min(fmt.maxExposureDuration.seconds, 1 / max(desired.fps, 1))
        let shR = Self.safeRange(fmt.minExposureDuration.seconds, maxShutter)
        let biasR = Self.safeRange(dev.minExposureTargetBias, dev.maxExposureTargetBias)
        let torch = dev.hasTorch
        let manualFocus = dev.isLockingFocusWithCustomLensPositionSupported
        let id = dev.uniqueID
        DispatchQueue.main.async {
            self.isoRange = isoR
            self.shutterRange = shR
            self.biasRange = biasR
            self.hasTorch = torch
            self.canManualFocus = manualFocus
            self.currentLensID = id
        }
        publishDesired()
    }

    private func publishDesired() {
        let s = desired
        DispatchQueue.main.async {
            self.resolution = s.resolution
            self.frameRate = s.fps
            self.exposureAuto = s.exposureAuto
            self.iso = s.iso
            self.shutter = s.shutter
            self.exposureBias = s.bias
            self.wbAuto = s.wbAuto
            self.temperature = s.temperature
            self.tint = s.tint
            self.focusAuto = s.focusAuto
            self.lensPosition = s.lensPosition
            self.torchLevel = s.torch
        }
    }

    // MARK: - Apply (sessionQueue)

    private func applyExposure() {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            if desired.exposureAuto {
                if dev.isExposureModeSupported(.continuousAutoExposure) {
                    dev.exposureMode = .continuousAutoExposure
                }
                let b = min(max(desired.bias, dev.minExposureTargetBias), dev.maxExposureTargetBias)
                dev.setExposureTargetBias(b, completionHandler: nil)
            } else if dev.isExposureModeSupported(.custom) {
                let fmt = dev.activeFormat
                let frameDur = 1 / max(desired.fps, 1)
                let maxDur = min(fmt.maxExposureDuration.seconds, frameDur)
                let dur = min(max(desired.shutter, fmt.minExposureDuration.seconds), maxDur)
                let iso = min(max(desired.iso, fmt.minISO), fmt.maxISO)
                desired.shutter = dur
                desired.iso = iso
                dev.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000_000),
                                          iso: iso, completionHandler: nil)
            }
            dev.unlockForConfiguration()
        } catch {
            report("曝光设置失败: \(error.localizedDescription)")
        }
    }

    private func normalizedGains(_ gains: AVCaptureDevice.WhiteBalanceGains, _ dev: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var g = gains
        let m = dev.maxWhiteBalanceGain
        g.redGain = min(max(1, g.redGain), m)
        g.greenGain = min(max(1, g.greenGain), m)
        g.blueGain = min(max(1, g.blueGain), m)
        return g
    }

    private func applyWhiteBalance() {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            if desired.wbAuto {
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    dev.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } else if dev.isWhiteBalanceModeSupported(.locked) && dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: desired.temperature, tint: desired.tint)
                let g = normalizedGains(dev.deviceWhiteBalanceGains(for: tt), dev)
                dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            }
            dev.unlockForConfiguration()
        } catch {
            report("白平衡设置失败: \(error.localizedDescription)")
        }
    }

    private func applyFocus() {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            if desired.focusAuto {
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            } else if dev.isLockingFocusWithCustomLensPositionSupported {
                dev.setFocusModeLocked(lensPosition: min(max(desired.lensPosition, 0), 1), completionHandler: nil)
            }
            dev.unlockForConfiguration()
        } catch {
            report("对焦设置失败: \(error.localizedDescription)")
        }
    }

    private func applyTorch() {
        guard let dev = device, dev.hasTorch else { return }
        do {
            try dev.lockForConfiguration()
        } catch {
            report("闪光灯设置失败: \(error.localizedDescription)")
            return
        }
        defer { dev.unlockForConfiguration() }
        if desired.torch <= 0.001 {
            if dev.isTorchModeSupported(.off) { dev.torchMode = .off }
        } else {
            do {
                try dev.setTorchModeOn(level: min(desired.torch, AVCaptureDevice.maxAvailableTorchLevel))
            } catch {
                report("闪光灯不可用（可能过热）: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Public setters (main thread)

    func setResolution(_ r: VideoResolution) {
        resolution = r
        UserDefaults.standard.set(r.rawValue, forKey: "cam.resolution")
        sessionQueue.async {
            self.desired.resolution = r
            guard let dev = self.device else { return }
            self.applyFormat(dev)
            self.reapplyManual(dev)
            self.publishDeviceState(dev)
        }
        onSettingsChanged?()
    }

    func setFrameRate(_ fps: Double) {
        frameRate = fps
        UserDefaults.standard.set(fps, forKey: "cam.fps")
        sessionQueue.async {
            self.desired.fps = fps
            guard let dev = self.device else { return }
            self.applyFormat(dev)
            self.reapplyManual(dev)
            self.publishDeviceState(dev)
        }
        onSettingsChanged?()
    }

    func selectLens(_ id: String) {
        currentLensID = id
        sessionQueue.async {
            guard let dev = self.devicesByID[id], dev != self.device else { return }
            self.switchInput(to: dev)
        }
        onSettingsChanged?()
    }

    func setExposureAuto(_ auto: Bool) {
        exposureAuto = auto
        sessionQueue.async {
            if !auto, let dev = self.device {
                // start manual mode from the current auto values
                self.desired.iso = dev.iso
                self.desired.shutter = dev.exposureDuration.seconds
            }
            self.desired.exposureAuto = auto
            self.applyExposure()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    func setISO(_ value: Float) {
        iso = value
        let wasAuto = exposureAuto
        exposureAuto = false
        sessionQueue.async {
            if wasAuto, let dev = self.device { self.desired.shutter = dev.exposureDuration.seconds }
            self.desired.exposureAuto = false
            self.desired.iso = value
            self.applyExposure()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    func setShutter(_ seconds: Double) {
        shutter = seconds
        let wasAuto = exposureAuto
        exposureAuto = false
        sessionQueue.async {
            if wasAuto, let dev = self.device { self.desired.iso = dev.iso }
            self.desired.exposureAuto = false
            self.desired.shutter = seconds
            self.applyExposure()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    func setExposureBias(_ ev: Float) {
        exposureBias = ev
        sessionQueue.async {
            self.desired.bias = ev
            self.applyExposure()
        }
        onSettingsChanged?()
    }

    func setWhiteBalanceAuto(_ auto: Bool) {
        wbAuto = auto
        sessionQueue.async {
            if !auto, let dev = self.device {
                let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
                self.desired.temperature = tt.temperature
                self.desired.tint = tt.tint
            }
            self.desired.wbAuto = auto
            self.applyWhiteBalance()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    func setWhiteBalance(temperature: Float, tint: Float) {
        self.temperature = temperature
        self.tint = tint
        wbAuto = false
        sessionQueue.async {
            self.desired.wbAuto = false
            self.desired.temperature = temperature
            self.desired.tint = tint
            self.applyWhiteBalance()
        }
        onSettingsChanged?()
    }

    /// Gray-world white balance from the current scene, then lock.
    func whiteBalanceFromScene() {
        sessionQueue.async {
            guard let dev = self.device else { return }
            let g = self.normalizedGains(dev.grayWorldDeviceWhiteBalanceGains, dev)
            let tt = dev.temperatureAndTintValues(for: g)
            self.desired.wbAuto = false
            self.desired.temperature = tt.temperature
            self.desired.tint = tt.tint
            self.applyWhiteBalance()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    func setFocusAuto(_ auto: Bool) {
        focusAuto = auto
        sessionQueue.async {
            if !auto, let dev = self.device { self.desired.lensPosition = dev.lensPosition }
            self.desired.focusAuto = auto
            self.applyFocus()
            self.publishDesired()
        }
    }

    func setLensPosition(_ p: Float) {
        lensPosition = p
        focusAuto = false
        sessionQueue.async {
            self.desired.focusAuto = false
            self.desired.lensPosition = p
            self.applyFocus()
        }
        onSettingsChanged?()
    }

    func setTorch(_ level: Float) {
        torchLevel = level
        sessionQueue.async {
            self.desired.torch = level
            self.applyTorch()
        }
        onSettingsChanged?()
    }

    /// Tap-to-focus/expose. `p` is normalised in the upright portrait image.
    func focusAndExpose(at p: CGPoint) {
        // portrait (rotated 90°) → sensor landscape coordinates
        let devPoint = CGPoint(x: p.y, y: 1 - p.x)
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if self.desired.focusAuto && dev.isFocusPointOfInterestSupported {
                    dev.focusPointOfInterest = devPoint
                    dev.focusMode = .continuousAutoFocus
                }
                if self.desired.exposureAuto && dev.isExposurePointOfInterestSupported {
                    dev.exposurePointOfInterest = devPoint
                    dev.exposureMode = .continuousAutoExposure
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    /// Freeze exposure, white balance and focus at their current values (measurement mode).
    func lockAll(completion: (() -> Void)? = nil) {
        sessionQueue.async {
            guard let dev = self.device else {
                DispatchQueue.main.async { completion?() }
                return
            }
            self.desired.iso = dev.iso
            self.desired.shutter = dev.exposureDuration.seconds
            self.desired.exposureAuto = false
            let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
            self.desired.temperature = tt.temperature
            self.desired.tint = tt.tint
            self.desired.wbAuto = false
            self.desired.lensPosition = dev.lensPosition
            self.desired.focusAuto = false
            do {
                try dev.lockForConfiguration()
                if dev.isExposureModeSupported(.custom) {
                    dev.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration,
                                              iso: AVCaptureDevice.currentISO, completionHandler: nil)
                }
                if dev.isWhiteBalanceModeSupported(.locked) {
                    dev.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
                }
                if dev.isLockingFocusWithCustomLensPositionSupported {
                    dev.setFocusModeLocked(lensPosition: AVCaptureDevice.currentLensPosition, completionHandler: nil)
                }
                dev.unlockForConfiguration()
            } catch {
                self.report("锁定失败: \(error.localizedDescription)")
            }
            self.publishDesired()
            // give the ISP a moment to settle before the baseline is taken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion?() }
        }
    }

    // MARK: - Live readout of auto values

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollLiveValues()
        }
    }

    private func pollLiveValues() {
        sessionQueue.async {
            guard let dev = self.device else { return }
            let s = self.desired
            let iso = dev.iso
            let dur = dev.exposureDuration.seconds
            let lens = dev.lensPosition
            let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
            DispatchQueue.main.async {
                if s.exposureAuto {
                    self.iso = iso
                    if dur > 0 { self.shutter = dur }
                }
                if s.focusAuto { self.lensPosition = lens }
                if s.wbAuto {
                    self.temperature = tt.temperature
                    self.tint = tt.tint
                }
            }
        }
    }

    // MARK: - Helpers

    private func report(_ msg: String) {
        DispatchQueue.main.async { self.statusMessage = msg }
    }

    private static func safeRange<T: Comparable>(_ a: T, _ b: T) -> ClosedRange<T> {
        a <= b ? a...b : b...a
    }

    /// Snapshot of the current camera settings for the recording metadata file.
    func settingsSnapshot() -> [String: Any] {
        [
            "lens": lenses.first { $0.id == currentLensID }?.label ?? currentLensID,
            "resolution": resolution.label,
            "fps": frameRate,
            "exposure_auto": exposureAuto,
            "iso": iso,
            "shutter_s": shutter,
            "shutter_angle_deg": shutterAngle,
            "exposure_bias_ev": exposureBias,
            "wb_auto": wbAuto,
            "wb_temperature_K": temperature,
            "wb_tint": tint,
            "focus_auto": focusAuto,
            "lens_position": lensPosition,
            "torch_level": torchLevel,
        ]
    }
}

// MARK: - Frame delivery

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
