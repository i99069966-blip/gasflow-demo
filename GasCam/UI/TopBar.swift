import SwiftUI

struct TopBar: View {
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var active: CameraControlKind?

    var body: some View {
        VStack(spacing: 3) {
            if case .file(let name) = pipeline.source {
                fileHeader(name)
            } else {
                HStack(spacing: 2) {
                    chip("FPS", fpsText, kind: .fps, auto: false)
                    chip("SHUTTER", camera.shutter.shutterLabel, kind: .shutter, auto: camera.shutterAuto)
                    chip("ISO", "\(camera.iso.safeInt)", kind: .iso, auto: camera.exposureAuto)
                    chip("WB", "\(camera.temperature.safeInt)K", kind: .wb, auto: camera.wbAuto)
                    chip("FOCUS", String(format: "%.2f", camera.lensPosition), kind: .focus, auto: camera.focusAuto)
                }
                infoRow
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .background(Color.black)
    }

    private var fpsText: String {
        let f = camera.frameRate
        return f == f.rounded() ? "\(Int(f))" : String(format: "%.2f", f)
    }

    private func chip(_ title: String, _ value: String, kind: CameraControlKind, auto: Bool) -> some View {
        StatusChip(title: title, value: value, auto: auto, selected: active == kind) {
            withAnimation(.easeOut(duration: 0.15)) { active = (active == kind) ? nil : kind }
        }
    }

    private var infoRow: some View {
        HStack(spacing: 8) {
            if let w = camera.autoWarning, !camera.isFullyLocked {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if camera.isFullyLocked, let s = camera.lockSummary, !s.isEmpty {
                Label(s, systemImage: "lock.fill")
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(camera.resolution.label) · \(pipeline.recordSettings.codec.label) · \(Int(pipeline.recordSettings.bitrateMbps))Mb/s")
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button { pipeline.lockAllCamera() } label: {
                Label("LOCK", systemImage: "lock.fill")
                    .font(Theme.mono(10, .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .foregroundStyle(camera.isFullyLocked ? Color.black : Color.white)
                    .background(camera.isFullyLocked ? Theme.accent : Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button { pipeline.autoAllCamera() } label: {
                Text("A AUTO")
                    .font(Theme.mono(10, .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if pipeline.isRecording, let start = pipeline.recordingStart {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(start))
                    Label(String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60), systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            Text(String(format: "%.0f fps", pipeline.measuredFPS))
        }
        .font(Theme.mono(10))
        .foregroundStyle(.gray)
        .labelStyle(.titleAndIcon)
    }

    private func fileHeader(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(String(format: "%.2f / %.2f s", pipeline.playbackTime, pipeline.playbackDuration))
            Text(String(format: "%.0f fps", pipeline.measuredFPS)).foregroundStyle(.gray)
        }
        .font(Theme.mono(12, .semibold))
        .foregroundStyle(.white)
        .padding(.vertical, 8)
    }
}
