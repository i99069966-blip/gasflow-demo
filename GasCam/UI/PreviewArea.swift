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
                    Color.black.overlay(Text("Metal 不可用").foregroundStyle(.gray))
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
                    camera.focusAndExpose(at: n)
                    focusMark = p
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { focusMark = nil }
                }

            if opt.grid { GridLines().stroke(Color.white.opacity(0.35), lineWidth: 0.5) }
            if opt.crosshair { Crosshair().stroke(Color.white.opacity(0.8), lineWidth: 1) }

            ROIEditor(roi: $pipeline.roi, size: size, editing: editROI)

            if let h = r.hotspot, r.phase == .detected || r.maxResponse > 0 {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .position(x: h.x * size.width, y: h.y * size.height)
            }

            if opt.showArrow {
                if let s = r.source {
                    SourceMarker(source: s, size: size, ghost: false)
                } else if let s = r.lastSource {
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

            if r.phase == .waiting && pipeline.source == .camera && !editROI {
                VStack(spacing: 4) {
                    Text("① 对准基板，调好曝光 / 白平衡 / 对焦")
                    Text("② 点 ROI 框选基板区域")
                    Text("③ 点 BASELINE 锁定相机并取基线，然后通气")
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

// MARK: - ROI editor

struct ROIEditor: View {
    @Binding var roi: NormRect
    let size: CGSize
    let editing: Bool
    @State private var draft: NormRect?
    @State private var moveStart: NormRect?

    var body: some View {
        let cur = draft ?? roi
        let rect = CGRect(x: cur.x0 * size.width, y: cur.y0 * size.height,
                          width: cur.width * size.width, height: cur.height * size.height)
        ZStack {
            Path(rect)
                .stroke(editing ? Theme.accent : Color.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: editing ? 2 : 1, dash: editing ? [] : [6, 4]))
                .allowsHitTesting(false)
            if editing {
                Rectangle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let start = moveStart ?? cur
                                if moveStart == nil { moveStart = cur }
                                var n = start
                                var dx = v.translation.width / size.width
                                var dy = v.translation.height / size.height
                                dx = min(max(dx, -start.x0), 1 - start.x1)
                                dy = min(max(dy, -start.y0), 1 - start.y1)
                                n.x0 += dx; n.x1 += dx; n.y0 += dy; n.y1 += dy
                                draft = n
                            }
                            .onEnded { _ in commit() }
                    )
                ForEach(0..<4, id: \.self) { corner in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1))
                        .position(cornerPoint(corner, rect))
                        .gesture(
                            DragGesture(coordinateSpace: .named("preview"))
                                .onChanged { v in
                                    var n = draft ?? roi
                                    let x = min(max(v.location.x / size.width, 0), 1)
                                    let y = min(max(v.location.y / size.height, 0), 1)
                                    switch corner {
                                    case 0: n.x0 = min(x, n.x1 - 0.08); n.y0 = min(y, n.y1 - 0.08)
                                    case 1: n.x1 = max(x, n.x0 + 0.08); n.y0 = min(y, n.y1 - 0.08)
                                    case 2: n.x1 = max(x, n.x0 + 0.08); n.y1 = max(y, n.y0 + 0.08)
                                    default: n.x0 = min(x, n.x1 - 0.08); n.y1 = max(y, n.y0 + 0.08)
                                    }
                                    draft = n
                                }
                                .onEnded { _ in commit() }
                        )
                }
                Text("拖动框或四角调整 ROI，再点 ROI 结束")
                    .font(Theme.mono(10))
                    .padding(4)
                    .background(Color.black.opacity(0.6))
                    .position(x: size.width / 2, y: min(size.height - 14, rect.maxY + 14))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named("preview"))
    }

    private func cornerPoint(_ i: Int, _ r: CGRect) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.maxX, y: r.minY)
        case 2: return CGPoint(x: r.maxX, y: r.maxY)
        default: return CGPoint(x: r.minX, y: r.maxY)
        }
    }

    private func commit() {
        if let d = draft { roi = d.clamped() }
        draft = nil
        moveStart = nil
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
            Text(level.faceDown ? String(format: "X %+.1f°  Y %+.1f°", level.tiltX, level.tiltY) : "请将手机镜头朝下放置")
                .font(Theme.mono(10, .semibold))
                .padding(3)
                .background(Color.black.opacity(0.6))
        }
        .allowsHitTesting(false)
    }
}
