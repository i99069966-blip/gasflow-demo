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
    /// Microphone sample buffers, also on `videoQueue` (so the recorder sees audio and video in order).
    var audioHandler: ((CMSampleBuffer) -> Void)?
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var lastMeterPublish: Double = 0
    private var lastAutoStep: Double = 0
    /// Read on the video queue to skip work when nothing is automatic.
    private var autoLoopActive = false
    /// Main thread: a user-initiated change that alters the image (analysis must re-baseline).
    var onSettingsChanged: (() -> Void)?

    private struct Desired {
        var resolution: VideoResolution = .hd1080
        var fps: Double = 30
        /// ISO (and the shutter while `shutterAuto`) follow the brightness of the analysis regions.
        var exposureAuto = true
        var shutterAuto = true
        var iso: Float = 100
        var shutter: Double = 1.0 / 60
        var bias: Float = 0
        var wbAuto = true
        var temperature: Float = 5600
        var tint: Float = 0
        var focusAuto = true
        var lensPosition: Float = 0.5
        var torch: Float = 0
        var zoom: CGFloat = 1
        var torchAuto = false
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
    /// The shutter is chosen by AUTO (false after the user picks a shutter by hand).
    @Published var shutterAuto = true
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

    /// Digital zoom on the current lens (1 = native field of view of that lens).
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoom: CGFloat = 1
    /// Optical factor of the current lens relative to the 1x wide camera (0.5 for ultra-wide).
    var lensFactor: Double { lenses.first(where: { $0.id == currentLensID })?.sortKey ?? 1 }
    /// What the user sees: lens factor × digital zoom ("1.4x").
    var effectiveZoom: Double { lensFactor * Double(zoomFactor) }

    /// Resolution / frame-rate combinations of the current lens, e.g. "1080p：最高 240 fps".
    @Published var capabilities: [String] = []
    static let modelIdentifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }()

    @Published var statusMessage: String?

    /// Torch brightness follows the scene until the camera is locked (BASELINE / LOCK).
    @Published var torchAuto = false
    /// Mains frequency of the room lights (lights flicker at twice this).
    @Published var mainsHz: Double = 60 {
        didSet { UserDefaults.standard.set(mainsHz, forKey: "cam.mainsHz") }
    }
    /// LOCK moves an automatic shutter to the nearest flicker-free value (ISO keeps the brightness).
    @Published var fixShutterOnLock = true {
        didSet { UserDefaults.standard.set(fixShutterOnLock, forKey: "cam.fixShutterOnLock") }
    }
    /// Values frozen by the last LOCK, e.g. "ISO 100 · 1/120 · 闪光 45% · 5200K".
    @Published var lockSummary: String?
    /// Brightness the AUTO loop aims for: brightest channel of the regions, 0–255.
    static let autoTarget: Float = 0.70 * 255
    /// Upper limit of the torch while it is automatic.
    static let autoTorchCap: Float = 0.70
    /// Microphone level (dBFS, −160…0) for the 声源 meter.
    @Published var audioLevel: Float = -160
    @Published var audioPeak: Float = -160
    /// The microphone is part of the capture session.
    @Published var audioActive = false

    var shutterAngle: Double { 360 * shutter * frameRate }
    var isFullyLocked: Bool { !exposureAuto && !wbAuto && !focusAuto && !torchAuto }

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
        let hz = d.double(forKey: "cam.mainsHz")
        if hz == 50 || hz == 60 { mainsHz = hz }
        if d.object(forKey: "cam.fixShutterOnLock") != nil { fixShutterOnLock = d.bool(forKey: "cam.fixShutterOnLock") }
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
        var devs = discovery.devices
        if !devs.contains(where: { $0.position == .front }) {
            if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                devs.append(front)
            }
        }
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

        if let first = wide ?? devs.first(where: { $0.position == .back }) ?? devs.first {
            switchInput(to: first)
        } else {
            DispatchQueue.main.async { self.statusMessage = L("没有可用的摄像头（模拟器请用“导入视频”测试）") }
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
            report(L("切换镜头失败") + ": \(error.localizedDescription)")
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
        // Front camera: mirror image everywhere (preview, recording and analysis).
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = device?.position == .front
        }
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
                report(L("格式设置失败") + ": \(error.localizedDescription)")
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
        applyZoom()
    }

    private func applyZoom() {
        guard let dev = device else { return }
        let maxZ = min(dev.maxAvailableVideoZoomFactor, dev.activeFormat.videoMaxZoomFactor, 10)
        let z = min(max(desired.zoom, dev.minAvailableVideoZoomFactor), maxZ)
        desired.zoom = z
        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = z
            dev.unlockForConfiguration()
        } catch {
            report(L("变焦设置失败") + ": \(error.localizedDescription)")
        }
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
        let maxZ = max(1, min(dev.maxAvailableVideoZoomFactor, fmt.videoMaxZoomFactor, 10))
        var caps: [String] = []
        for r in VideoResolution.allCases {
            let rates = dev.formats
                .filter { Self.dims($0) == (r.width, r.height) }
                .flatMap { $0.videoSupportedFrameRateRanges.map { $0.maxFrameRate } }
            if let m = rates.max() { caps.append(String(format: L("%@：最高 %d fps"), r.label, Int(m.rounded()))) }
        }
        DispatchQueue.main.async {
            self.maxZoom = maxZ
            self.capabilities = caps
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
            self.shutterAuto = s.exposureAuto && s.shutterAuto
            self.iso = s.iso
            self.shutter = s.shutter
            self.exposureBias = s.bias
            self.wbAuto = s.wbAuto
            self.temperature = s.temperature
            self.tint = s.tint
            self.focusAuto = s.focusAuto
            self.lensPosition = s.lensPosition
            self.torchLevel = s.torch
            self.torchAuto = s.torchAuto
            self.autoLoopActive = s.torchAuto || s.exposureAuto
            self.zoomFactor = s.zoom
        }
    }

    // MARK: - Apply (sessionQueue)

    private func applyExposure() {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            // AUTO is driven by GasCam itself (autoExposureStep) so that it meters the analysis
            // regions and can keep the shutter fixed; the device always runs in custom mode.
            if !dev.isExposureModeSupported(.custom) {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            } else {
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
            report(L("曝光设置失败") + ": \(error.localizedDescription)")
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
            report(L("白平衡设置失败") + ": \(error.localizedDescription)")
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
            report(L("对焦设置失败") + ": \(error.localizedDescription)")
        }
    }

    private func applyTorch() {
        guard let dev = device, dev.hasTorch else { return }
        do {
            try dev.lockForConfiguration()
        } catch {
            report(L("闪光灯设置失败") + ": \(error.localizedDescription)")
            return
        }
        defer { dev.unlockForConfiguration() }
        if desired.torch <= 0.001 {
            if dev.isTorchModeSupported(.off) { dev.torchMode = .off }
        } else {
            do {
                try dev.setTorchModeOn(level: min(desired.torch, AVCaptureDevice.maxAvailableTorchLevel))
            } catch {
                report(L("闪光灯不可用（可能过热）") + ": \(error.localizedDescription)")
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
            self.desired.zoom = 1
            self.switchInput(to: dev)
        }
        onSettingsChanged?()
    }

    func setExposureAuto(_ auto: Bool) {
        exposureAuto = auto
        shutterAuto = auto
        lockSummary = nil
        sessionQueue.async {
            if let dev = self.device, dev.exposureDuration.seconds > 0 {
                self.desired.iso = dev.iso
                self.desired.shutter = dev.exposureDuration.seconds
            }
            self.desired.exposureAuto = auto
            self.desired.shutterAuto = auto
            self.applyExposure()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    /// Manual ISO: exposure becomes fully manual.
    func setISO(_ value: Float) {
        iso = value
        exposureAuto = false
        shutterAuto = false
        sessionQueue.async {
            if let dev = self.device, dev.exposureDuration.seconds > 0 { self.desired.shutter = dev.exposureDuration.seconds }
            self.desired.exposureAuto = false
            self.desired.shutterAuto = false
            self.desired.iso = value
            self.applyExposure()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    /// Manual shutter. If AUTO is on, ISO (and torch) keep following the brightness; AUTO no
    /// longer touches the shutter until AUTO is pressed again.
    func setShutter(_ seconds: Double) {
        shutter = seconds
        shutterAuto = false
        sessionQueue.async {
            if let dev = self.device { self.desired.iso = dev.iso }
            self.desired.shutterAuto = false
            self.desired.shutter = seconds
            self.applyExposure()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    /// Is `seconds` a whole number of light-flicker periods (no flicker under mains lighting)?
    func isFlickerFree(_ seconds: Double) -> Bool {
        let k = seconds * 2 * mainsHz
        return k >= 0.98 && abs(k - k.rounded()) < 0.02
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

    func setZoom(_ z: CGFloat) {
        zoomFactor = z
        sessionQueue.async {
            self.desired.zoom = z
            self.applyZoom()
        }
        onSettingsChanged?()
    }

    /// Longest shutter that integrates whole flicker periods of mains-powered lights
    /// (lights flicker at 2 × mains frequency) and still fits in one frame. nil if impossible.
    func flickerFreeShutter(mainsHz: Double) -> Double? {
        let period = 1 / (2 * mainsHz)
        let maxDur = min(1 / max(frameRate, 1), shutterRange.upperBound)
        let k = (maxDur / period + 1e-6).rounded(.down)
        return k >= 1 ? k * period : nil
    }

    func setTorch(_ level: Float) {
        torchLevel = level
        torchAuto = false
        sessionQueue.async {
            self.desired.torchAuto = false
            self.autoLoopActive = self.desired.exposureAuto
            self.desired.torch = level
            self.applyTorch()
        }
        onSettingsChanged?()
    }

    /// Stop the auto torch at its current brightness (no re-baseline: the picture does not change).
    func freezeTorch() {
        guard torchAuto else { return }
        torchAuto = false
        sessionQueue.async {
            self.desired.torchAuto = false
            self.autoLoopActive = self.desired.exposureAuto
        }
    }

    func setTorchAuto(_ on: Bool) {
        let enable = on && hasTorch
        torchAuto = enable
        sessionQueue.async {
            self.desired.torchAuto = enable
            self.autoLoopActive = enable || self.desired.exposureAuto
            if enable && self.desired.torch < 0.02 {
                self.desired.torch = 0.1
                self.applyTorch()
                self.publishDesired()
            }
        }
        onSettingsChanged?()
    }

    /// One tap: exposure, white balance, focus and torch back to automatic (zoom is left alone).
    func setAllAuto() {
        exposureAuto = true
        shutterAuto = true
        wbAuto = true
        focusAuto = true
        let torch = hasTorch
        torchAuto = torch
        lockSummary = nil
        sessionQueue.async {
            self.desired.exposureAuto = true
            self.desired.shutterAuto = true
            self.autoLoopActive = true
            self.desired.wbAuto = true
            self.desired.focusAuto = true
            self.desired.torchAuto = torch
            if torch && self.desired.torch < 0.02 { self.desired.torch = 0.1 }
            self.applyExposure()
            self.applyWhiteBalance()
            self.applyFocus()
            self.applyTorch()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    /// AUTO control loop, called from the frame queue with the brightest channel (0–255) of the
    /// analysis regions (whole frame when none is drawn). One small step every ~0.3 s.
    ///  dark  : torch ↑ (up to 70 %) → shutter ↑ (up to 1/fps) → ISO ↑
    ///  bright: ISO ↓ (down to minimum) → torch ↓ (→ off) → shutter ↓
    func autoExposureStep(level: Float) {
        guard autoLoopActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAutoStep >= 0.3 else { return }
        lastAutoStep = now
        sessionQueue.async { self.runAutoStep(level: level) }
    }

    private func runAutoStep(level: Float) {
        guard let dev = device else { return }
        let s = desired
        guard s.exposureAuto || s.torchAuto else { return }
        let target = Self.autoTarget * powf(2, s.bias)
        let lv = max(level, 1)
        var ratio = target / lv
        if abs(logf(ratio)) < logf(1.08) { return }                 // close enough
        ratio = min(max(powf(ratio, 0.7), 0.5), 2.0)              // damped, at most one stop per step
        if level >= 250 { ratio = min(ratio, 0.6) }

        let fmt = dev.activeFormat
        let minISO = fmt.minISO, maxISO = fmt.maxISO
        let minDur = fmt.minExposureDuration.seconds
        let maxDur = min(fmt.maxExposureDuration.seconds, 1 / max(s.fps, 1))
        let torchOK = s.torchAuto && dev.hasTorch
        var iso = s.iso, dur = s.shutter, torch = s.torch
        var expoChanged = false, torchChanged = false

        if ratio > 1 {
            if torchOK && torch < Self.autoTorchCap - 0.005 {
                torch = min(Self.autoTorchCap, max(0.05, torch * ratio))
                torchChanged = true
            } else if s.exposureAuto {
                var r = Double(ratio)
                if s.shutterAuto && dur < maxDur * 0.999 {
                    let nd = min(maxDur, dur * r)
                    r *= dur / nd
                    dur = nd
                    expoChanged = true
                }
                if r > 1.01 && iso < maxISO {
                    iso = min(maxISO, iso * Float(r))
                    expoChanged = true
                }
            }
        } else {
            var r = ratio
            if s.exposureAuto && iso > minISO * 1.001 {
                let ni = max(minISO, iso * r)
                r *= iso / ni
                iso = ni
                expoChanged = true
            }
            if r < 0.99 && torchOK && torch > 0 {
                torch *= r
                if torch < 0.03 { torch = 0 }
                torchChanged = true
            } else if r < 0.99 && s.exposureAuto && s.shutterAuto && dur > minDur * 1.001 {
                dur = max(minDur, dur * Double(r))
                expoChanged = true
            }
        }
        if expoChanged {
            desired.iso = iso
            desired.shutter = dur
            applyExposure()
        }
        if torchChanged {
            desired.torch = torch
            applyTorch()
        }
        if expoChanged || torchChanged { publishDesired() }
    }

    /// Add or remove the microphone (level meter + audio track). Asks for permission when needed.
    func setAudio(enabled: Bool) {
        guard enabled else {
            sessionQueue.async { self.configureAudio(false) }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            sessionQueue.async { self.configureAudio(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                self.sessionQueue.async { self.configureAudio(granted) }
            }
        default:
            DispatchQueue.main.async {
                self.audioActive = false
                self.statusMessage = L("没有麦克风权限：声源电平和录音不可用（可在 设置 → GasCam 中打开）")
            }
        }
    }

    private func configureAudio(_ on: Bool) {
        session.beginConfiguration()
        if on {
            if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let inp = try? AVCaptureDeviceInput(device: mic), session.canAddInput(inp) {
                session.addInput(inp)
                audioInput = inp
            }
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
                session.addOutput(audioOutput)
            }
        } else {
            if let inp = audioInput { session.removeInput(inp); audioInput = nil }
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        }
        session.commitConfiguration()
        let active = audioInput != nil
        DispatchQueue.main.async {
            self.audioActive = active
            if !active { self.audioLevel = -160; self.audioPeak = -160 }
        }
    }

    /// Tap to focus. `p` is normalised in the upright portrait image. (Exposure is metered on the
    /// analysis regions, not on the tap point.)
    func focus(at p: CGPoint) {
        sessionQueue.async {
            guard let dev = self.device else { return }
            // portrait (rotated 90°) → sensor landscape coordinates; the front image is mirrored
            let devPoint = dev.position == .front ? CGPoint(x: p.y, y: p.x) : CGPoint(x: p.y, y: 1 - p.x)
            do {
                try dev.lockForConfiguration()
                if self.desired.focusAuto && dev.isFocusPointOfInterestSupported {
                    dev.focusPointOfInterest = devPoint
                    dev.focusMode = .continuousAutoFocus
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    /// Freeze exposure, white balance, focus and torch at their current values (measurement mode).
    /// An automatic shutter is first moved to the nearest flicker-free value (if enabled) and the ISO
    /// is scaled so the brightness stays the same. `completion` gets a summary of the locked values.
    func lockAll(completion: ((String) -> Void)? = nil) {
        let mains = mainsHz
        let fixShutter = fixShutterOnLock
        sessionQueue.async {
            guard let dev = self.device else {
                DispatchQueue.main.async { completion?("") }
                return
            }
            let fmt = dev.activeFormat
            var iso = dev.iso
            var dur = dev.exposureDuration.seconds
            if dur <= 0 { dur = self.desired.shutter }
            var flickerNote = ""
            if fixShutter && self.desired.exposureAuto && self.desired.shutterAuto {
                let period = 1 / (2 * mains)
                let maxDur = min(fmt.maxExposureDuration.seconds, 1 / max(self.desired.fps, 1))
                let kMax = Int((maxDur / period + 1e-6).rounded(.down))
                if kMax >= 1 {
                    let best = (1...kMax).map { Double($0) * period }
                        .min { abs(log($0 / dur)) < abs(log($1 / dur)) } ?? dur
                    iso = min(max(iso * Float(dur / best), fmt.minISO), fmt.maxISO)
                    dur = best
                } else {
                    flickerNote = " · " + String(format: L("%d fps 无法防频闪"), Int(self.desired.fps))
                }
            }
            self.desired.iso = iso
            self.desired.shutter = dur
            self.desired.exposureAuto = false
            self.desired.shutterAuto = false
            let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
            self.desired.temperature = tt.temperature
            self.desired.tint = tt.tint
            self.desired.wbAuto = false
            self.desired.lensPosition = dev.lensPosition
            self.desired.focusAuto = false
            self.desired.torchAuto = false
            self.autoLoopActive = false
            do {
                try dev.lockForConfiguration()
                if dev.isExposureModeSupported(.custom) {
                    dev.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000_000),
                                              iso: iso, completionHandler: nil)
                }
                if dev.isWhiteBalanceModeSupported(.locked) {
                    dev.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
                }
                if dev.isLockingFocusWithCustomLensPositionSupported {
                    dev.setFocusModeLocked(lensPosition: AVCaptureDevice.currentLensPosition, completionHandler: nil)
                }
                dev.unlockForConfiguration()
            } catch {
                self.report(L("锁定失败") + ": \(error.localizedDescription)")
            }
            self.publishDesired()
            let torchText = dev.hasTorch ? " · " + L("闪光") + " \(Int((self.desired.torch * 100).rounded()))%" : ""
            let summary = "ISO \(Int(iso.rounded())) · \(dur.shutterLabel)\(torchText) · \(Int(tt.temperature.rounded()))K" + flickerNote
            DispatchQueue.main.async { self.lockSummary = summary }
            // give the ISP a moment to settle before the baseline is taken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion?(summary) }
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
            "shutter_auto": shutterAuto,
            "mains_hz": mainsHz,
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
            "digital_zoom": Double(zoomFactor),
            "effective_zoom": effectiveZoom,
            "device_model": Self.modelIdentifier,
        ]
    }
}

// MARK: - Frame delivery

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            audioHandler?(sampleBuffer)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMeterPublish >= 1.0 / 15 {
                lastMeterPublish = now
                let chs = connection.audioChannels
                let avg = chs.map { $0.averagePowerLevel }.max() ?? -160
                let peak = chs.map { $0.peakHoldLevel }.max() ?? -160
                DispatchQueue.main.async {
                    self.audioLevel = avg
                    self.audioPeak = peak
                }
            }
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
