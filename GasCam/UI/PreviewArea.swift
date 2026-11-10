import SwiftUI
import CoreMotion

/// Camera / video preview sized to the frame aspect, with vector overlays on top.
struct PreviewArea: View {
    @EnvironmentObject var pipeline: FramePipeline
    @Binding var editROI: Bool

    var body: some View {
        GeometryReader { geo in
            let size = Self.fit(aspect: pipeline.frameAspect, in: geo.size)
            ZStack {
                if let r = pipeline.renderer {
                    MetalPreviewView(renderer: r)
                } else {
                    Color.black.overlay(Text(L("Metal 不可用")).foregroundStyle(.gray))
                }
                PreviewOverlay(size: size, editROI: $editROI)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .position(x: geo.size.width / 2, y: size.height / 2)   // top aligned
        }
    }

    static func fit(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        if box.width / box.height > aspect {
            return CGSize(width: box.height * aspect, height: box.height)
        } else {
            return CGSize(width: box.width, height: box.width / aspect)
        }
    }
}

struct PreviewOverlay: View {
    @EnvironmentObject var pipeline: FramePipeline
    @EnvironmentObject var camera: CameraController
    let size: CGSize
    @Binding var editROI: Bool
    @StateObject private var level = MotionLevel()
    @State private var focusMark: CGPoint?

    var body: some View {
        let opt = pipeline.display
        let r = pipeline.result
        ZStack {
            // tap to focus/expose (camera, not while editing the ROI)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    guard !editROI, pipeline.source == .camera else { return }
                    let n = CGPoint(x: p.x / size.width, y: p.y / size.height)
                    camera.focus(at: n)
                    focusMark = p
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { focusMark = nil }
                }

            if opt.grid { GridLines().stroke(Color.white.opacity(0.35), lineWidth: 0.5) }
            if opt.crosshair { Crosshair().stroke(Color.white.opacity(0.8), lineWidth: 1) }

            RegionOverlay(size: size, editing: editROI)

            if opt.showHotspot, let h = r.hotspot, r.phase == .detected {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .position(x: h.x * size.width, y: h.y * size.height)
            }

            if opt.showArrow {
                if let s = r.source, r.gasPresent {
                    SourceMarker(source: s, size: size, ghost: false)
                } else if opt.keepLastResult, let s = r.source ?? r.lastSource {
                    SourceMarker(source: s, size: size, ghost: true)
                }
            }

            if opt.level { LevelIndicator(level: level).position(x: size.width / 2, y: size.height * 0.5) }

            if let f = focusMark {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.accent, lineWidth: 1.5)
                    .frame(width: 70, height: 70)
                    .position(f)
            }

            VStack(alignment: .leading, spacing: 4) {
                if opt.showSteps && pipeline.source == .camera && !editROI {
                    StepGuide()
                }
                if opt.falseColor && !(opt.blackBackground && opt.overlay != .live) {
                    FalseColorLegend()
                }
                if opt.zebra {
                    AssistHint(text: String(format: L("ZEB：斜纹 = 亮度超过 %d%%，快过曝"), Int((opt.zebraLevel * 100).rounded())))
                }
                if opt.peaking {
                    AssistHint(text: L("PEAK：红边 = 对焦清楚的地方"))
                }
                if opt.showColorBar && opt.overlay != .live && pipeline.result.phase != .waiting {
                    ColorBarView(mode: opt.overlay, scale: r.displayScale,
                                 flowScale: pipeline.params.flowScalePercent, arrivalSpan: pipeline.params.arrivalSpan,
                                 channel: pipeline.params.channel, adaptive: pipeline.params.arrivalMode == .adaptive)
                }
                if pipeline.regions.isEmpty && !editROI {
                    Text(L("请先画框（点 ROI）· 现在按整个画面分析"))
                        .font(Theme.mono(10, .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .foregroundStyle(Theme.accent)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 6)
            .padding(.top, 6)
            .padding(.trailing, 52)
            .allowsHitTesting(false)

            if r.phase == .waiting && pipeline.source == .camera && !editROI && !opt.showSteps {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("① 按 AUTO，点画面对焦，画面合适后按 LOCK"))
                    Text(L("② 点 ROI 画分析框（可多个，也可画参考框）"))
                    Text(L("③ 点 BASELINE 取基线，然后通气"))
                }
                .font(Theme.mono(11))
                .padding(8)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .position(x: size.width / 2, y: size.height * 0.72)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { if opt.level { level.start() } }
        .onChange(of: opt.level) { _, on in
            if on { level.start() } else { level.stop() }
        }
    }
}

// MARK: - Source arrow / markers

struct SourceMarker: View {
    let source: GasSource
    let size: CGSize
    let ghost: Bool

    var body: some View {
        let c = CGPoint(x: source.centroid.x * size.width, y: source.centroid.y * size.height)
        let e = CGPoint(x: source.earliest.x * size.width, y: source.earliest.y * size.height)
        let s = CGPoint(x: source.sourcePoint.x * size.width, y: source.sourcePoint.y * size.height)
        ZStack {
            if source.mode == .direction {
                ArrowShape(from: c, to: s, head: 16)
                    .stroke(Color.black.opacity(0.8), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                ArrowShape(from: c, to: s, head: 16)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round,
                                                            dash: ghost ? [6, 6] : []))
            } else {
                // radial spreading: source is above / at the entry point
                ForEach(1..<4) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.9 - Double(i) * 0.2), lineWidth: 2)
                        .frame(width: CGFloat(i) * 22, height: CGFloat(i) * 22)
                        .position(e)
                }
            }
            Circle()
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: 14, height: 14)
                .position(e)
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.red)
                .shadow(color: .black, radius: 1)
                .position(s)
        }
        .opacity(ghost ? 0.45 : 1)
        .allowsHitTesting(false)
    }
}

struct ArrowShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var head: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        let ang = atan2(to.y - from.y, to.x - from.x)
        p.move(to: to)
        p.addLine(to: CGPoint(x: to.x - head * cos(ang - 0.45), y: to.y - head * sin(ang - 0.45)))
        p.move(to: to)
        p.addLine(to: CGPoint(x: to.x - head * cos(ang + 0.45), y: to.y - head * sin(ang + 0.45)))
        return p
    }
}

// MARK: - Assists

struct GridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.width * CGFloat(i) / 3
            let y = rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: rect.height))
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return p
    }
}

struct Crosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: CGPoint(x: c.x - 18, y: c.y)); p.addLine(to: CGPoint(x: c.x + 18, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y - 18)); p.addLine(to: CGPoint(x: c.x, y: c.y + 18))
        return p
    }
}

/// Tilt of the phone relative to horizontal (camera looking straight down = 0°, 0°).
final class MotionLevel: ObservableObject {
    @Published var tiltX: Double = 0
    @Published var tiltY: Double = 0
    @Published var faceDown = false
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            self.tiltX = asin(max(-1, min(1, g.x))) * 180 / .pi
            self.tiltY = asin(max(-1, min(1, g.y))) * 180 / .pi
            self.faceDown = abs(g.z) > 0.7
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

struct LevelIndicator: View {
    @ObservedObject var level: MotionLevel

    var body: some View {
        let ok = abs(level.tiltX) < 0.5 && abs(level.tiltY) < 0.5
        let r: CGFloat = 40
        let dx = CGFloat(max(-10, min(10, level.tiltX))) / 10 * r
        let dy = CGFloat(max(-10, min(10, -level.tiltY))) / 10 * r
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.6), lineWidth: 1).frame(width: r * 2, height: r * 2)
                Circle().stroke(Color.white.opacity(0.4), lineWidth: 1).frame(width: 10, height: 10)
                Circle().fill(ok ? Color.green : Theme.accent).frame(width: 12, height: 12).offset(x: dx, y: dy)
            }
            Text(level.faceDown ? String(format: "X %+.1f°  Y %+.1f°", level.tiltX, level.tiltY) : L("请将手机镜头朝下放置"))
                .font(Theme.mono(10, .semibold))
                .padding(3)
                .background(Color.black.opacity(0.6))
        }
        .allowsHitTesting(false)
    }
}
