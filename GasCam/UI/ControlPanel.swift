import SwiftUI

/// Editor for the camera control selected in the top bar.
struct ControlPanel: View {
    let kind: CameraControlKind
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var pipeline: FramePipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .fps: fpsPanel
            case .shutter: shutterPanel
            case .iso: isoPanel
            case .wb: wbPanel
            case .focus: focusPanel
            case .lens: lensPanel
            case .torch: torchPanel
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }

    // MARK: FPS + resolution

    private var fpsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("分辨率" + (pipeline.isRecording ? "（录制中不可改）" : ""))
            chipsRow(camera.supportedResolutions.map { $0.label },
                     selected: camera.resolution.label, disabled: pipeline.isRecording) { label in
                if let r = VideoResolution.allCases.first(where: { $0.label == label }) { camera.setResolution(r) }
            }
            caption("帧率 (fps)")
            chipsRow(camera.supportedFrameRates.map { "\(Int($0))" },
                     selected: "\(Int(camera.frameRate))", disabled: pipeline.isRecording) { s in
                if let f = Double(s) { camera.setFrameRate(f) }
            }
        }
    }

    // MARK: Shutter

    private var shutterChoices: [Double] {
        CameraPresets.shutterDenominators
            .map { 1 / $0 }
            .filter { camera.shutterRange.contains($0) }
    }

    private var shutterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PillButton(text: "AUTO", selected: camera.exposureAuto) { camera.setExposureAuto(!camera.exposureAuto) }
                Text(String(format: "%@  ·  %.0f°", camera.shutter.shutterLabel, camera.shutterAngle))
                    .font(Theme.mono(13, .semibold))
                Spacer()
                Text("50/60Hz 灯光防闪: 1/50·1/100 或 1/60·1/120").font(Theme.mono(9)).foregroundStyle(.gray)
            }
            chipsRow(shutterChoices.map { $0.shutterLabel }, selected: camera.exposureAuto ? "" : camera.shutter.shutterLabel) { label in
                if let v = shutterChoices.first(where: { $0.shutterLabel == label }) { camera.setShutter(v) }
            }
            if camera.exposureAuto {
                ValueSlider(label: "EV", value: Binding(get: { camera.exposureBias }, set: { camera.setExposureBias($0) }),
                            range: camera.biasRange) { String(format: "%+.1f", $0) }
            }
        }
    }

    // MARK: ISO

    private var isoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PillButton(text: "AUTO", selected: camera.exposureAuto) { camera.setExposureAuto(!camera.exposureAuto) }
                Text("ISO \(Int(camera.iso.rounded()))").font(Theme.mono(13, .semibold))
                Spacer()
            }
            chipsRow(CameraPresets.isoValues.filter { camera.isoRange.contains($0) }.map { "\(Int($0))" },
                     selected: camera.exposureAuto ? "" : "\(Int(camera.iso.rounded()))") { s in
                if let v = Float(s) { camera.setISO(v) }
            }
            ValueSlider(label: "ISO", value: Binding(get: { camera.iso }, set: { camera.setISO($0) }),
                        range: camera.isoRange) { "\(Int($0.rounded()))" }
        }
    }

    // MARK: White balance

    private var wbPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PillButton(text: "AUTO", selected: camera.wbAuto) { camera.setWhiteBalanceAuto(!camera.wbAuto) }
                PillButton(text: "锁定当前") { camera.setWhiteBalanceAuto(false) }
                PillButton(text: "灰卡/场景") { camera.whiteBalanceFromScene() }
                Spacer()
            }
            chipsRow(CameraPresets.wbPresets.map { $0.0 }, selected: "") { name in
                if let p = CameraPresets.wbPresets.first(where: { $0.0 == name }) {
                    camera.setWhiteBalance(temperature: p.1, tint: camera.tint)
                }
            }
            ValueSlider(label: "色温", value: Binding(get: { camera.temperature },
                                                    set: { camera.setWhiteBalance(temperature: $0, tint: camera.tint) }),
                        range: 2000...10000) { "\(Int($0.rounded()))K" }
            ValueSlider(label: "色调", value: Binding(get: { camera.tint },
                                                    set: { camera.setWhiteBalance(temperature: camera.temperature, tint: $0) }),
                        range: -150...150) { String(format: "%+.0f", $0) }
        }
    }

    // MARK: Focus

    private var focusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PillButton(text: "AF", selected: camera.focusAuto) { camera.setFocusAuto(!camera.focusAuto) }
                Text(camera.focusAuto ? "连续自动对焦 · 点击画面选择对焦点" : "手动对焦 (0 = 最近, 1 = 最远)")
                    .font(Theme.mono(11)).foregroundStyle(.gray)
                Spacer()
            }
            if camera.canManualFocus {
                ValueSlider(label: "焦点", value: Binding(get: { camera.lensPosition }, set: { camera.setLensPosition($0) }),
                            range: 0...1) { String(format: "%.3f", $0) }
            }
            Text("提示：打开右侧 PEAK（峰值对焦）辅助手动对焦。").font(Theme.mono(10)).foregroundStyle(.gray)
        }
    }

    // MARK: Lens

    private var lensPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("镜头")
            chipsRow(camera.lenses.map { $0.label },
                     selected: camera.lenses.first(where: { $0.id == camera.currentLensID })?.label ?? "",
                     disabled: pipeline.isRecording) { label in
                if let l = camera.lenses.first(where: { $0.label == label }) { camera.selectLens(l.id) }
            }
            Text("切换镜头后会自动重新取基线。").font(Theme.mono(10)).foregroundStyle(.gray)
        }
    }

    // MARK: Torch

    private var torchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if camera.hasTorch {
                HStack(spacing: 6) {
                    PillButton(text: "OFF", selected: camera.torchLevel <= 0.001) { camera.setTorch(0) }
                    ForEach(CameraPresets.torchPresets, id: \.self) { lvl in
                        PillButton(text: "\(Int(lvl * 100))%", selected: abs(camera.torchLevel - lvl) < 0.01) { camera.setTorch(lvl) }
                    }
                }
                ValueSlider(label: "亮度", value: Binding(get: { camera.torchLevel }, set: { camera.setTorch($0) }),
                            range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                Text("闪光灯常亮作为光源；长时间高亮度可能因过热被系统降低。").font(Theme.mono(10)).foregroundStyle(.gray)
            } else {
                Text("当前镜头没有闪光灯").font(Theme.mono(12)).foregroundStyle(.gray)
            }
        }
    }

    // MARK: Helpers

    private func caption(_ s: String) -> some View {
        Text(s).font(Theme.mono(10, .semibold)).foregroundStyle(.gray)
    }

    private func chipsRow(_ items: [String], selected: String, disabled: Bool = false,
                          action: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    PillButton(text: item, selected: item == selected, disabled: disabled) { action(item) }
                }
            }
        }
    }
}
