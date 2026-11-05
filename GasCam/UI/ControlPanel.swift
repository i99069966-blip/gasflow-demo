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
            caption(L("分辨率") + (pipeline.isRecording ? L("（录制中不可改）") : ""))
            chipsRow(camera.supportedResolutions.map { $0.label },
                     selected: camera.resolution.label, disabled: pipeline.isRecording) { label in
                if let r = VideoResolution.allCases.first(where: { $0.label == label }) { camera.setResolution(r) }
            }
            caption(L("帧率 (fps)"))
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
                PillButton(text: "AUTO", selected: camera.shutterAuto) {
                    if camera.shutterAuto { camera.setShutter(camera.shutter) } else { camera.setExposureAuto(true) }
                }
                Text(String(format: "%@  ·  %.0f°", camera.shutter.shutterLabel, camera.shutterAngle))
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(camera.isFlickerFree(camera.shutter) ? Color.green : Color.white)
                Spacer()
            }
            HStack(spacing: 6) {
                Text(L("电网")).font(Theme.mono(10, .semibold)).foregroundStyle(.gray)
                PillButton(text: "60Hz", selected: camera.mainsHz == 60) { camera.mainsHz = 60 }
                PillButton(text: "50Hz", selected: camera.mainsHz == 50) { camera.mainsHz = 50 }
                PillButton(text: L("防频闪")) { applyFlickerFree(camera.mainsHz) }
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(shutterChoices, id: \.self) { v in
                        let free = camera.isFlickerFree(v)
                        let sel = !camera.shutterAuto && abs(camera.shutter - v) / v < 0.01
                        Button { camera.setShutter(v) } label: {
                            Text(v.shutterLabel)
                                .font(Theme.mono(13, .semibold))
                                .foregroundStyle(sel ? .black : (free ? Color.green : .white))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(sel ? (free ? Color.green : Theme.accent) : Color.white.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(camera.shutterAuto
                 ? L("快门自动：按 LOCK 时会改到最近的防频闪值（绿色），并用 ISO 保持亮度。")
                 : L("绿色 = 不会被灯光频闪影响的快门。快门最长 = 1/帧率。"))
                .font(Theme.mono(10)).foregroundStyle(.gray)
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
            Text(L("自动：按分析框的亮度调节（目标约 70%）。"))
                .font(Theme.mono(10)).foregroundStyle(.gray)
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
                PillButton(text: L("锁定当前")) { camera.setWhiteBalanceAuto(false) }
                PillButton(text: L("灰卡/场景")) { camera.whiteBalanceFromScene() }
                Spacer()
            }
            chipsRow(CameraPresets.wbPresets.map { L($0.0) }, selected: "") { name in
                if let p = CameraPresets.wbPresets.first(where: { L($0.0) == name }) {
                    camera.setWhiteBalance(temperature: p.1, tint: camera.tint)
                }
            }
            ValueSlider(label: L("色温"), value: Binding(get: { camera.temperature },
                                                    set: { camera.setWhiteBalance(temperature: $0, tint: camera.tint) }),
                        range: 2000...10000) { "\(Int($0.rounded()))K" }
            ValueSlider(label: L("色调"), value: Binding(get: { camera.tint },
                                                    set: { camera.setWhiteBalance(temperature: camera.temperature, tint: $0) }),
                        range: -150...150) { String(format: "%+.0f", $0) }
        }
    }

    // MARK: Focus

    private var focusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PillButton(text: "AF", selected: camera.focusAuto) { camera.setFocusAuto(!camera.focusAuto) }
                Text(camera.focusAuto ? L("连续自动对焦 · 点击画面选择对焦点") : L("手动对焦 (0 = 最近, 1 = 最远)"))
                    .font(Theme.mono(11)).foregroundStyle(.gray)
                Spacer()
            }
            if camera.canManualFocus {
                ValueSlider(label: L("焦点"), value: Binding(get: { camera.lensPosition }, set: { camera.setLensPosition($0) }),
                            range: 0...1) { String(format: "%.3f", $0) }
            }
            Text(L("提示：打开右侧 PEAK（峰值对焦）辅助手动对焦。")).font(Theme.mono(10)).foregroundStyle(.gray)
        }
    }

    // MARK: Lens

    private func applyFlickerFree(_ hz: Double) {
        if let s = camera.flickerFreeShutter(mainsHz: hz) {
            camera.setShutter(s)
        } else {
            camera.statusMessage = String(format: L("%d fps 时快门无法避开 %dHz 灯光频闪，请把帧率降到 %d fps 以下，或改用直流/LED 恒流光源。"),
                                          Int(camera.frameRate), Int(hz), Int(2 * hz))
        }
    }

    private var zoomPresets: [CGFloat] {
        [1, 1.5, 2, 3, 4, 5].filter { $0 <= camera.maxZoom + 0.001 }
    }

    private var lensPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption(L("镜头（本机的物理镜头）"))
            chipsRow(camera.lenses.map { lensName($0) },
                     selected: camera.lenses.first(where: { $0.id == camera.currentLensID }).map { lensName($0) } ?? "",
                     disabled: pipeline.isRecording) { label in
                if let l = camera.lenses.first(where: { lensName($0) == label }) { camera.selectLens(l.id) }
            }
            HStack {
                caption(L("变焦（数码）"))
                Spacer()
                Text(String(format: L("等效 %.2fx"), camera.effectiveZoom)).font(Theme.mono(12, .semibold))
            }
            chipsRow(zoomPresets.map { String(format: "×%.1f", $0) },
                     selected: String(format: "×%.1f", camera.zoomFactor), disabled: pipeline.isRecording) { s in
                if let v = Double(s.dropFirst()) { camera.setZoom(CGFloat(v)) }
            }
            if camera.maxZoom > 1 {
                ValueSlider(label: L("变焦"),
                            value: Binding(get: { Double(camera.zoomFactor) }, set: { camera.setZoom(CGFloat($0)) }),
                            range: 1...Double(camera.maxZoom)) { String(format: "×%.2f", $0) }
                    .disabled(pipeline.isRecording)
            }
            Text(L("数码变焦是裁切放大，画质会下降；0.5x 镜头放大 ×2 ≈ 1x 视角。切换镜头或变焦后会自动重新取基线。前置镜头的画面是镜像的。"))
                .font(Theme.mono(10)).foregroundStyle(.gray)
        }
    }

    // MARK: Torch

    private var torchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if camera.hasTorch {
                HStack(spacing: 6) {
                    PillButton(text: "AUTO", selected: camera.torchAuto) { camera.setTorchAuto(!camera.torchAuto) }
                    Text(camera.torchAuto ? L("自动：按分析框亮度调节（最高 70%），BASELINE / LOCK 时固定") : L("手动"))
                        .font(Theme.mono(10)).foregroundStyle(.gray)
                    Spacer()
                }
                HStack(spacing: 6) {
                    PillButton(text: "OFF", selected: !camera.torchAuto && camera.torchLevel <= 0.001) { camera.setTorch(0) }
                    ForEach(CameraPresets.torchPresets, id: \.self) { lvl in
                        PillButton(text: "\(Int(lvl * 100))%", selected: abs(camera.torchLevel - lvl) < 0.01) { camera.setTorch(lvl) }
                    }
                }
                ValueSlider(label: L("亮度"), value: Binding(get: { camera.torchLevel }, set: { camera.setTorch($0) }),
                            range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                Text(L("闪光灯常亮作为光源；长时间高亮度可能因过热被系统降低。")).font(Theme.mono(10)).foregroundStyle(.gray)
            } else {
                Text(L("当前镜头没有闪光灯")).font(Theme.mono(12)).foregroundStyle(.gray)
            }
        }
    }

    // MARK: Helpers

    private func lensName(_ l: LensOption) -> String { l.label == "FRONT" ? L("前置") : l.label }

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
