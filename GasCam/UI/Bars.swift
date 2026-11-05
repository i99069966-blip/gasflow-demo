import SwiftUI

/// Gas detection status + BASELINE / RESET + overlay mode.
struct GasStatusBar: View {
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var showGasPanel: Bool

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
                Button { withAnimation(.easeOut(duration: 0.15)) { showGasPanel.toggle() } } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 30)
                        .background(showGasPanel ? Theme.accent : Color.white.opacity(0.15))
                        .foregroundStyle(showGasPanel ? Color.black : Color.white)
                        .clipShape(Capsule())
                }
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
                .frame(maxWidth: 270)
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
            case .baseline(let p):
                return (r.baselineTarget > 0 ? "基线 \(r.baselineFrames)/\(r.baselineTarget)帧" : "基线 \(Int(p * 100))%", .blue)
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
            if pipeline.display.showAudioMeter && camera.audioActive {
                AudioMeterView(level: camera.audioLevel, peak: camera.audioPeak)
                    .frame(width: 22, height: 52)
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
        guard let l = camera.lenses.first(where: { $0.id == camera.currentLensID }) else { return "LENS" }
        if l.label == "FRONT" || camera.zoomFactor <= 1.001 { return l.label }
        return String(format: "%.1fx", camera.effectiveZoom)
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

/// Video-file mode: live scrubbing, frame stepping, play/pause, speed.
struct PlaybackBar: View {
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var showSettings: Bool
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    static let speeds: [(String, Double)] = [("0.1×", 0.1), ("0.25×", 0.25), ("0.5×", 0.5), ("1×", 1), ("2×", 2), ("MAX", 0)]
    private var speeds: [(String, Double)] { Self.speeds }

    var body: some View {
        let dur = max(pipeline.playbackDuration, 0.01)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(String(format: "%.2f", scrubbing ? scrubValue : pipeline.playbackTime))
                    .font(Theme.mono(11)).frame(width: 46, alignment: .leading)
                Slider(value: Binding(get: { scrubbing ? scrubValue : min(pipeline.playbackTime, dur) },
                                      set: { v in
                                          if !scrubbing {
                                              scrubbing = true
                                              pipeline.beginScrub()
                                          }
                                          scrubValue = v
                                          pipeline.scrub(to: v)       // picture follows the finger
                                      }),
                       in: 0...dur,
                       onEditingChanged: { editing in
                           if editing {
                               if !scrubbing {
                                   scrubbing = true
                                   scrubValue = pipeline.playbackTime
                                   pipeline.beginScrub()
                               }
                           } else {
                               pipeline.endScrub(at: scrubValue)
                               scrubbing = false
                           }
                       })
                    .tint(Theme.accent)
                Text(String(format: "%.2f s", dur))
                    .font(Theme.mono(11)).foregroundStyle(.gray).frame(width: 54, alignment: .trailing)
            }
            HStack(spacing: 14) {
                Button { pipeline.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }
                Button {
                    if pipeline.playbackFinished { pipeline.restartVideo() } else { pipeline.playbackPaused.toggle() }
                } label: {
                    Image(systemName: pipeline.playbackFinished ? "arrow.counterclockwise"
                          : (pipeline.playbackPaused ? "play.fill" : "pause.fill"))
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 40, height: 34)
                }
                Button { pipeline.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }
                Menu {
                    ForEach(speeds.indices, id: \.self) { i in
                        Button(speeds[i].0) { pipeline.playbackSpeed = speeds[i].1 }
                    }
                } label: {
                    Text(speeds.first(where: { $0.1 == pipeline.playbackSpeed })?.0 ?? "1×")
                        .font(Theme.mono(13, .bold))
                        .frame(width: 52, height: 30)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Spacer(minLength: 0)
                Button { pipeline.saveResultImage() } label: { Image(systemName: "camera.viewfinder") }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                Button { pipeline.closeVideo() } label: { Image(systemName: "xmark.circle.fill") }
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

/// Blackmagic-style microphone level meter (声源): −60…0 dBFS with peak hold.
struct AudioMeterView: View {
    let level: Float
    let peak: Float

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            func frac(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }
            let barW = size.width - 8
            let h = size.height - 4
            let lv = frac(level) * h
            // green / yellow / red segments
            let segments: [(Float, Float, Color)] = [(-60, -12, .green), (-12, -3, .yellow), (-3, 0, .red)]
            for (lo, hi, c) in segments {
                let y0 = frac(lo) * h, y1 = min(frac(hi) * h, lv)
                if y1 > y0 {
                    ctx.fill(Path(CGRect(x: 4, y: size.height - 2 - y1, width: barW, height: y1 - y0)), with: .color(c))
                }
            }
            let py = size.height - 2 - frac(peak) * h
            ctx.fill(Path(CGRect(x: 2, y: py - 1, width: size.width - 4, height: 2)), with: .color(.white))
            for db: Float in [-12, -24, -36, -48] {
                let y = size.height - 2 - frac(db) * h
                ctx.fill(Path(CGRect(x: 0, y: y, width: 3, height: 0.5)), with: .color(.white.opacity(0.5)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        .overlay(alignment: .top) {
            Text("dB").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(.gray).offset(y: -9)
        }
    }
}

/// Vertical assist toggles on the right edge of the preview.
struct AssistColumn: View {
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var editROI: Bool
    /// Collapsed automatically while a bottom panel is open so the two never overlap.
    var forceCollapsed = false
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: (expanded && !forceCollapsed) ? "chevron.up" : "slider.vertical.3")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 40, height: 26)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            if expanded && !forceCollapsed {
                toggles
            }
        }
    }

    private var toggles: some View {
        VStack(spacing: 6) {
            AssistToggle(text: "FC", isOn: pipeline.display.falseColor) { pipeline.display.falseColor.toggle() }
            AssistToggle(text: "ZEB", isOn: pipeline.display.zebra) { pipeline.display.zebra.toggle() }
            AssistToggle(text: "PEAK", isOn: pipeline.display.peaking) { pipeline.display.peaking.toggle() }
            AssistToggle(text: "GRID", isOn: pipeline.display.grid) { pipeline.display.grid.toggle() }
            AssistToggle(text: "+", isOn: pipeline.display.crosshair) { pipeline.display.crosshair.toggle() }
            AssistToggle(text: "LVL", isOn: pipeline.display.level) { pipeline.display.level.toggle() }
            AssistToggle(text: "ROI", isOn: editROI) { editROI.toggle() }
            AssistToggle(text: "➚", isOn: pipeline.display.showArrow) { pipeline.display.showArrow.toggle() }
            AssistToggle(text: "CRV", isOn: pipeline.display.showChart) { pipeline.display.showChart.toggle() }
        }
    }
}
