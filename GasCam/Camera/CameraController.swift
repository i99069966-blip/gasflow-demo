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

    /// AUTO loop state (sessionQueue).
    private struct AutoState {
        /// Measurements before this time still show the previous settings.
        var settleUntil: Double = 0
        /// (torch level, linear brightness per unit exposure) at up to two torch levels → torch model.
        var points: [(t: Float, e: Float)] = []
        var warning: String?
    }
    private var autoState = AutoState()
    private var mainsQ: Double = 60
    private var isoCapQ: Float = 800
    private var torchCapQ: Float = 1
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
    /// Exposure time the sensor really uses (read back; it is rounded to the sensor line time and can
    /// differ slightly from the value that was set). 0 = unknown.
    @Published var actualShutter: Double = 0
    /// The device takes custom exposure values (always true on the back cameras). sessionQueue.
    private var customExposure = true

    /// Torch brightness follows the scene until the camera is locked (BASELINE / LOCK).
    @Published var torchAuto = false
    /// Mains frequency of the room lights (lights flicker at twice this).
    @Published var mainsHz: Double = 60 {
        didSet {
            UserDefaults.standard.set(mainsHz, forKey: "cam.mainsHz")
            let v = mainsHz
            sessionQueue.async { self.mainsQ = v; self.restartAuto() }
        }
    }
    /// Highest ISO the AUTO loop may use (manual ISO is not limited).
    @Published var autoISOCap: Float = 800 {
        didSet {
            UserDefaults.standard.set(autoISOCap, forKey: "cam.autoISOCap")
            let v = autoISOCap
            sessionQueue.async { self.isoCapQ = v }
        }
    }
    /// Highest torch level the AUTO loop may use (0…1).
    @Published var autoTorchLimit: Float = 1 {
        didSet {
            UserDefaults.standard.set(autoTorchLimit, forKey: "cam.autoTorchLimit")
            let v = autoTorchLimit
            sessionQueue.async { self.torchCapQ = v }
        }
    }
    /// AUTO could not reach the target ("光线不足" …). nil = fine.
    @Published var autoWarning: String?
    /// The phone is hot: iOS may dim the torch, the baseline may drift. nil = fine.
    @Published var thermalWarning: String?
    /// Values frozen by the last LOCK, e.g. "ISO 100 · 1/120 · 闪光 45% · 5200K".
    @Published var lockSummary: String?
    /// AUTO aims the brightest 2 % of the analysed pixels (brightest channel) at this level (0–255).
    static let autoTarget: Float = 0.85 * 255
    /// Microphone level (dBFS, −160…0) for the 声源 meter.
    @Published var audioLevel: Float = -160
    @Published var audioPeak: Float = -160
    /// The microphone is part of the capture session.
    @Published var audioActive = false

    var shutterAngle: Double { 360 * shutter * frameRate }
    var isFullyLocked: Bool { !exposureAuto && !wbAuto && !focusAuto && !torchAuto }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.updateThermal()
        }
        updateThermal()
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
        if hz == 50 || hz == 60 { mainsHz = hz; mainsQ = hz }
        let ic = d.float(forKey: "cam.autoISOCap")
        if ic > 0 { autoISOCap = ic; isoCapQ = ic }
        if d.object(forKey: "cam.autoTorchLimit") != nil {
            let tl = d.float(forKey: "cam.autoTorchLimit")
            autoTorchLimit = tl; torchCapQ = tl
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
        restartAuto()
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
            customExposure = dev.isExposureModeSupported(.custom)
            if !customExposure {
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
            self.restartAuto()
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
            // in custom mode the set values are the truth; the read-back is rounded by the sensor
            if !self.customExposure, let dev = self.device, dev.exposureDuration.seconds > 0 {
                self.desired.iso = dev.iso
                self.desired.shutter = dev.exposureDuration.seconds
            }
            self.desired.exposureAuto = auto
            self.desired.shutterAuto = auto
            self.applyExposure()
            if auto { self.restartAuto() }
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
            if !self.customExposure, let dev = self.device, dev.exposureDuration.seconds > 0 {
                self.desired.shutter = dev.exposureDuration.seconds
            }
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
            if !self.customExposure, let dev = self.device { self.desired.iso = dev.iso }
            self.desired.shutterAuto = false
            self.desired.shutter = seconds
            self.applyExposure()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    private func updateThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            thermalWarning = L("手机发热：闪光灯可能被系统调暗，基线可能漂移")
        default:
            thermalWarning = nil
        }
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
                if tt.temperature.isFinite { self.desired.temperature = tt.temperature }
                if tt.tint.isFinite { self.desired.tint = tt.tint }
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
            if tt.temperature.isFinite { self.desired.temperature = tt.temperature }
            if tt.tint.isFinite { self.desired.tint = tt.tint }
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

    /// One tap: exposure, white balance and focus back to automatic. The torch is never automatic:
    /// it stays at the level set by hand (zoom is left alone too).
    func setAllAuto() {
        exposureAuto = true
        shutterAuto = true
        wbAuto = true
        focusAuto = true
        torchAuto = false
        lockSummary = nil
        sessionQueue.async {
            self.desired.exposureAuto = true
            self.desired.shutterAuto = true
            self.autoLoopActive = true
            self.desired.wbAuto = true
            self.desired.focusAuto = true
            self.desired.torchAuto = false
            self.applyWhiteBalance()
            self.applyFocus()
            self.restartAuto()
            self.publishDesired()
        }
        onSettingsChanged?()
    }

    /// AUTO control loop, called from the frame queue with the brightness of the analysed pixels:
    /// `p98` = 98th percentile of the brightest channel (0–255), `saturated` = fraction ≥ 250.
    func autoExposureStep(p98: Float, saturated: Float) {
        guard autoLoopActive, p98.isFinite, saturated.isFinite else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAutoStep >= 0.1 else { return }
        lastAutoStep = now
        sessionQueue.async { self.runAutoStep(p98: p98, saturated: saturated, now: now) }
    }

    /// (Re)start AUTO from a known state: shutter = longest flicker-free value (unless set by hand),
    /// lowest ISO, torch off — the first measurement is then the ambient light alone. sessionQueue.
    private func restartAuto() {
        autoState = AutoState()
        publishWarning(nil)
        guard let dev = device, desired.exposureAuto || desired.torchAuto else { return }
        let fmt = dev.activeFormat
        if desired.exposureAuto {
            if desired.shutterAuto { desired.shutter = homeShutter(fmt) }
            desired.iso = fmt.minISO
            applyExposure()
        }
        if desired.torchAuto && dev.hasTorch {
            desired.torch = 0
            applyTorch()
        }
        autoState.settleUntil = ProcessInfo.processInfo.systemUptime + 0.5
        autoLoopActive = true
        publishDesired()
    }

    /// Longest flicker-free shutter that fits in one frame (1/fps if none exists).
    private func homeShutter(_ fmt: AVCaptureDevice.Format) -> Double {
        let maxDur = min(fmt.maxExposureDuration.seconds, 1 / max(desired.fps, 1))
        let period = 1 / (2 * mainsQ)
        let k = (maxDur / period + 1e-6).rounded(.down)
        return k >= 1 ? k * period : maxDur
    }

    private func publishWarning(_ w: String?) {
        DispatchQueue.main.async { if self.autoWarning != w { self.autoWarning = w } }
    }

    /// Video output is gamma-encoded; exposure arithmetic is done on linear light.
    private static func linear(_ v: Float) -> Float { powf(max(v, 0.5) / 255, 2.2) }

    ///  too dark  : shortened shutter back to its home value → torch ↑ (up to the limit) → ISO ↑ (up to the limit)
    ///  too bright: ISO ↓ (to the minimum) → torch ↓ (to off) → shutter ↓ (flicker-free steps first)
    private func runAutoStep(p98: Float, saturated: Float, now: Double) {
        guard let dev = device, now >= autoState.settleUntil else { return }
        let s = desired
        guard s.exposureAuto || s.torchAuto else { return }
        let fmt = dev.activeFormat
        let minISO = fmt.minISO
        let isoCap = min(fmt.maxISO, max(minISO, isoCapQ))
        let minDur = fmt.minExposureDuration.seconds
        let home = homeShutter(fmt)
        let period = 1 / (2 * mainsQ)
        let torchOK = s.torchAuto && dev.hasTorch && dev.isTorchAvailable
        let torchCap: Float = torchOK ? min(1, max(0.05, torchCapQ)) : 0
        let target = min(245, max(40, Self.autoTarget * powf(2, s.bias)))
        let clipped = saturated >= 0.005 || p98 >= 252
        var iso = s.iso, dur = s.shutter, torch = s.torch
        let gain = max(iso * Float(dur), 1e-9)

        // brightness per unit exposure at this torch level (for the torch model)
        if !clipped && p98 > 4 {
            let e = Self.linear(p98) / gain
            if let i = autoState.points.firstIndex(where: { abs($0.t - torch) < 0.05 }) {
                autoState.points[i] = (torch, e)
            } else {
                autoState.points.append((torch, e))
                if autoState.points.count > 2 { autoState.points.removeFirst() }
            }
        }
        var r: Float                                   // wanted change of (linear) brightness
        if clipped {
            r = 0.35
        } else {
            if abs(p98 - target) / target < 0.05 {
                // keep the flicker warning while the shutter stays shorter than flicker-free
                let shortShutter = s.exposureAuto && s.shutterAuto && dur < period * 0.999
                if autoState.warning != nil && !shortShutter { autoState.warning = nil; publishWarning(nil) }
                return
            }
            r = min(8, max(0.125, Self.linear(target) / Self.linear(p98)))
        }
        // torch model: light(t) = a + k·t (k = what full torch adds)
        var model: (a: Float, k: Float)?
        if autoState.points.count == 2 {
            let p0 = autoState.points[0], p1 = autoState.points[1]
            let k = (p1.e - p0.e) / (p1.t - p0.t)
            if k.isFinite && k > 0 { model = (max(0, p0.e - k * p0.t), k) }
        }
        let torchUseless = model.map { $0.k * max(torchCap, 0.05) < 0.1 * $0.a } ?? false
        func light(_ t: Float) -> Float { model.map { $0.a + $0.k * t } ?? 1 }

        var warn: String?
        var torchChanged = false
        if r > 1 {
            // 1. a shortened shutter goes back towards its home value (more light, no extra noise)
            if s.exposureAuto && s.shutterAuto && dur < home * 0.999 {
                var nd = dur < period * 0.999 ? min(period, dur * Double(r))
                                               : ((dur / period).rounded() + 1) * period
                nd = min(nd, home)
                if nd > dur && Double(r) >= nd / dur * 0.95 {
                    r *= Float(dur / nd)
                    dur = nd
                }
            }
            // 2. torch
            if r > 1.02 && torchCap > 0 && !torchUseless && torch < torchCap - 0.005 {
                if let m = model {
                    let need = light(torch) * r
                    let nt = min(torchCap, max(0, (need - m.a) / m.k))
                    r = need / max(light(nt), 1e-12)
                    torch = nt
                } else {
                    // not known yet how much the torch adds: switch it on and measure
                    torch = torch < 0.02 ? min(torchCap, p98 < 30 ? 0.5 : 0.25) : min(torchCap, torch + 0.25)
                    r = 1
                }
                torchChanged = true
            }
            // 3. ISO, up to the AUTO limit
            if r > 1.02 && s.exposureAuto && iso < isoCap {
                let ni = min(isoCap, iso * r)
                r *= iso / ni
                iso = ni
            }
            if r > 1.15 { warn = s.torchAuto ? L("光线不足：闪光灯和 ISO 已到上限") : L("光线不足：ISO 已到上限，请调亮闪光灯") }
        } else {
            // 1. ISO down to its minimum
            if s.exposureAuto && iso > minISO * 1.001 {
                let ni = max(minISO, iso * r)
                r *= iso / ni
                iso = ni
            }
            // 2. torch down, to off
            if r < 0.98 && s.torchAuto && torch > 0 {
                if let m = model, !clipped {
                    let need = light(torch) * r
                    var nt = (need - m.a) / m.k
                    if nt < 0.03 { nt = need <= m.a ? 0 : 0.03 }
                    nt = min(max(nt, 0), max(torchCap, 0.03))
                    r = need / max(light(nt), 1e-12)
                    torch = nt
                } else {
                    torch = torch * r < 0.03 ? 0 : torch * r
                    r = 1
                }
                torchChanged = true
            }
            // 3. shutter shorter (only when AUTO owns it): whole flicker periods first
            if r < 0.98 && s.exposureAuto && s.shutterAuto && dur > minDur * 1.001 {
                let want = dur * Double(r)
                var nd = want >= period * 0.999 ? max(1, (want / period + 1e-6).rounded(.down)) * period
                                                : max(minDur, want)
                nd = min(nd, dur)
                r *= Float(dur / nd)              // > 1 if the flicker-free step went further than needed
                dur = nd
                if r > 1.02 { iso = min(isoCap, iso * r); r = 1 }
            }
            if s.exposureAuto && s.shutterAuto && dur < period * 0.999 {
                warn = L("光线太强：快门已短于防频闪值，画面可能闪烁")
            } else if r < 0.85 {
                warn = L("光线太强：已无法再降低亮度")
            }
        }

        let expoChanged = iso != s.iso || dur != s.shutter
        if expoChanged {
            desired.iso = iso
            desired.shutter = dur
            applyExposure()
        }
        if torchChanged && torch != s.torch {
            desired.torch = torch
            applyTorch()
        }
        if expoChanged || torchChanged {
            autoState.settleUntil = ProcessInfo.processInfo.systemUptime + (torchChanged ? 0.5 : 0.35)
            publishDesired()
        }
        if warn != autoState.warning {
            autoState.warning = warn
            publishWarning(warn)
        }
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
    /// `completion` (main thread) gets a summary of the locked values.
    func lockAll(completion: ((String) -> Void)? = nil) {
        sessionQueue.async {
            guard let dev = self.device else {
                DispatchQueue.main.async { completion?("") }
                return
            }
            let fmt = dev.activeFormat
            // custom mode: lock the values that were set (the read-back is rounded by the sensor)
            var dur = self.customExposure ? self.desired.shutter : dev.exposureDuration.seconds
            if !(dur > 0) { dur = self.desired.shutter }
            dur = min(max(dur, fmt.minExposureDuration.seconds), fmt.maxExposureDuration.seconds)
            let iso = min(max(self.customExposure ? self.desired.iso : dev.iso, fmt.minISO), fmt.maxISO)
            self.desired.iso = iso
            self.desired.shutter = dur
            self.desired.exposureAuto = false
            self.desired.shutterAuto = false
            let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
            if tt.temperature.isFinite { self.desired.temperature = tt.temperature }
            if tt.tint.isFinite { self.desired.tint = tt.tint }
            self.desired.wbAuto = false
            self.desired.lensPosition = min(max(dev.lensPosition, 0), 1)
            self.desired.focusAuto = false
            self.desired.torchAuto = false
            self.autoLoopActive = false
            self.autoState = AutoState()
            self.publishWarning(nil)
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
            let k = dur * 2 * self.mainsQ
            let flickerFree = k >= 0.98 && abs(k - k.rounded()) < 0.02
            let torchText = dev.hasTorch ? " · " + L("闪光") + " \(Int((self.desired.torch * 100).rounded()))%" : ""
            let tempText = tt.temperature.isFinite ? " · \(Int(tt.temperature.rounded()))K" : ""
            let summary = "ISO \(Int(iso.rounded())) · \(dur.shutterLabel)\(torchText)\(tempText)"
                + (flickerFree ? "" : " · " + L("快门非防频闪"))
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
            let custom = self.customExposure
            let iso = dev.iso
            let dur = dev.exposureDuration.seconds
            let lens = dev.lensPosition
            let tt = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains)
            DispatchQueue.main.async {
                if dur.isFinite && dur > 0 && abs(dur - self.actualShutter) > 1e-7 { self.actualShutter = dur }
                // GasCam's own AUTO publishes its values; read back only when the device runs its own auto
                if s.exposureAuto && !custom {
                    if iso.isFinite { self.iso = iso }
                    if dur.isFinite && dur > 0 { self.shutter = dur }
                }
                if s.focusAuto && lens.isFinite { self.lensPosition = lens }
                if s.wbAuto && tt.temperature.isFinite && tt.tint.isFinite {
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
