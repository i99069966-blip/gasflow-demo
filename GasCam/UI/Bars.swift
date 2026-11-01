import SwiftUI

/// Gas detection status + BASELINE / RESET + overlay mode.
struct GasStatusBar: View {
    @EnvironmentObject var pipeline: FramePipeline

    var body: some View {
        let r = pipeline.result
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                phasePill(r)
                if let s = r.source ?? r.lastSource {
                    HStack(spacing: 4) {
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.degrees(90 - s.angleDeg))
                            .foregroundStyle(r.source == nil ? Color.gray : Color.white)
                        Text(s.mode == .direction ? String(format: "%.0f°", s.angleDeg) : "正上方")
                        Text(String(format: "c%.2f", s.confidence)).foregroundStyle(.gray)
                    }
                    .font(Theme.mono(13, .semibold))
                }
                Spacer(minLength: 4)
                Button { pipeline.startBaseline() } label: {
                    Text("BASELINE").font(Theme.mono(12, .bold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.accent).foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                Button { pipeline.resetArrivals() } label: {
                    Text("RESET").font(Theme.mono(12, .bold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.white.opacity(0.15)).foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $pipeline.display.overlay) {
                    ForEach(OverlayMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "Δ %.2f%%  max %.1f%%", r.meanResponse, r.maxResponse))
                    Text(String(format: "active %.1f%%  σ %.2f%%", r.activeFraction * 100, r.noiseMedianPercent))
                        .foregroundStyle(.gray)
                }
                .font(Theme.mono(10))
            }
        }
        .padding(8)
        .background(Theme.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }

    private func phasePill(_ r: GasFrameResult) -> some View {
        let (text, color): (String, Color) = {
            switch r.phase {
            case .waiting: return ("待机", .gray)
            case .baseline(let p): return ("基线 \(Int(p * 100))%", .blue)
            case .monitoring: return ("监测中", .green)
            case .detected: return ("检测到气体", .red)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(Theme.mono(12, .bold))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.18))
        .clipShape(Capsule())
    }
}

/// Camera mode: histogram, lens, torch, record, snapshot, settings.
struct CameraBottomBar: View {
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var active: CameraControlKind?
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            if pipeline.display.showHistogram {
                HistogramView(histogram: pipeline.histogram)
                    .frame(width: 104, height: 52)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                smallButton(lensLabel, selected: active == .lens) { toggle(.lens) }
                smallButton(camera.torchLevel > 0 ? "☀︎\(Int(camera.torchLevel * 100))" : "☀︎OFF",
                            selected: active == .torch) { toggle(.torch) }
            }
            Button { pipeline.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 3).frame(width: 62, height: 62)
                    if pipeline.isRecording {
                        RoundedRectangle(cornerRadius: 5).fill(Color.red).frame(width: 26, height: 26)
                    } else {
                        Circle().fill(Color.red).frame(width: 50, height: 50)
                    }
                }
            }
            .buttonStyle(.plain)
            VStack(spacing: 6) {
                iconButton("camera.viewfinder") { pipeline.saveResultImage() }
                iconButton("gearshape") { showSettings = true }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }

    private var lensLabel: String {
        camera.lenses.first(where: { $0.id == camera.currentLensID })?.label ?? "LENS"
    }

    private func toggle(_ k: CameraControlKind) {
        withAnimation(.easeOut(duration: 0.15)) { active = (active == k) ? nil : k }
    }

    private func smallButton(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Theme.mono(12, .bold))
                .frame(width: 64, height: 26)
                .foregroundStyle(selected ? .black : .white)
                .background(selected ? Theme.accent : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 26)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Video-file mode: transport controls.
struct PlaybackBar: View {
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var showSettings: Bool
    static let speeds: [(String, Double)] = [("0.1×", 0.1), ("0.25×", 0.25), ("0.5×", 0.5), ("1×", 1), ("2×", 2), ("MAX", 0)]
    private var speeds: [(String, Double)] { Self.speeds }

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: min(pipeline.playbackTime, max(pipeline.playbackDuration, 0.001)),
                         total: max(pipeline.playbackDuration, 0.001))
                .tint(Theme.accent)
            HStack(spacing: 10) {
                if pipeline.display.showHistogram {
                    HistogramView(histogram: pipeline.histogram).frame(width: 90, height: 44)
                }
                Button {
                    if pipeline.playbackFinished { pipeline.restartVideo() } else { pipeline.playbackPaused.toggle() }
                } label: {
                    Image(systemName: pipeline.playbackFinished ? "arrow.counterclockwise"
                          : (pipeline.playbackPaused ? "play.fill" : "pause.fill"))
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 48, height: 40)
                }
                Menu {
                    ForEach(speeds.indices, id: \.self) { i in
                        Button(speeds[i].0) { pipeline.playbackSpeed = speeds[i].1 }
                    }
                } label: {
                    Text(speeds.first(where: { $0.1 == pipeline.playbackSpeed })?.0 ?? "1×")
                        .font(Theme.mono(13, .bold))
                        .frame(width: 56, height: 32)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                Button { pipeline.saveResultImage() } label: { Image(systemName: "camera.viewfinder") }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                Button { pipeline.closeVideo() } label: {
                    Label("相机", systemImage: "xmark.circle.fill").font(Theme.mono(12, .bold))
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
        }
        .padding(10)
        .background(Theme.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }
}

/// Vertical assist toggles on the right edge of the preview.
struct AssistColumn: View {
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var editROI: Bool

    var body: some View {
        VStack(spacing: 6) {
            AssistToggle(text: "FC", isOn: pipeline.display.falseColor) { pipeline.display.falseColor.toggle() }
            AssistToggle(text: "ZEB", isOn: pipeline.display.zebra) { pipeline.display.zebra.toggle() }
            AssistToggle(text: "PEAK", isOn: pipeline.display.peaking) { pipeline.display.peaking.toggle() }
            AssistToggle(text: "GRID", isOn: pipeline.display.grid) { pipeline.display.grid.toggle() }
            AssistToggle(text: "+", isOn: pipeline.display.crosshair) { pipeline.display.crosshair.toggle() }
            AssistToggle(text: "LVL", isOn: pipeline.display.level) { pipeline.display.level.toggle() }
            AssistToggle(text: "ROI", isOn: editROI) { editROI.toggle() }
            AssistToggle(text: "➚", isOn: pipeline.display.showArrow) { pipeline.display.showArrow.toggle() }
        }
    }
}
