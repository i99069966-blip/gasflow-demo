import SwiftUI

extension SignalChannel {
    /// Curve colour of the channel.
    var color: Color {
        switch self {
        case .red: return Color(red: 1, green: 0.35, blue: 0.3)
        case .green: return Color(red: 0.3, green: 0.9, blue: 0.4)
        case .blue: return Color(red: 0.35, green: 0.55, blue: 1)
        case .luma: return Color(white: 0.9)
        case .redChroma: return Color(red: 1, green: 0.6, blue: 0.55)
        case .redBlueRatio: return Color(red: 0.85, green: 0.5, blue: 1)
        }
    }
    /// Same 0–255 scale as R, G and B (can share the RGB curve view). r and R/B are ratios.
    var rgbScale: Bool { self == .red || self == .green || self == .blue || self == .luma }
}

/// Live curve of the analysis regions: raw value of the signal channel or mean ΔS/S %.
/// Blue band = baseline, light blue = where a baseline would be taken from here, red band = gas detected.
/// Pinch with two fingers to zoom the time axis. Drag the ≡ handle to move the panel up or down.
struct ChartPanel: View {
    @EnvironmentObject var pipeline: FramePipeline
    /// Highest place the panel may be moved to (top of the preview, in the "stage" coordinate space).
    var minTop: CGFloat = 0
    /// Top of the panel at its normal place (offset 0), in the "stage" coordinate space.
    @State private var baseTop: CGFloat = 0
    @State private var moveStart: CGFloat?
    @State private var liveOffset: CGFloat?
    /// 0 = everything (whole video / whole live buffer).
    private static let windows: [Double] = [1, 2, 5, 10, 30, 60, 120, 0]
    static let minWindow: Double = 0.5
    @State private var dragging = false
    @State private var dragSpan: ClosedRange<Double>?
    @State private var dragStartTime: Double?
    /// Visible seconds while pinching (committed to the settings when the fingers lift).
    @State private var pinchWindow: Double?
    @State private var pinchBase: Double?
    /// The drag that belongs to a pinch must not move the playhead.
    @State private var suppressDrag = false
    @State private var lastPinch = Date.distantPast

    private var isFile: Bool {
        if case .file = pipeline.source { return true }
        return false
    }

    static func windowLabel(_ w: Double) -> String {
        if w <= 0 { return L("全部") }
        return w == w.rounded() ? "\(Int(w))s" : String(format: "%.1fs", w)
    }

    var body: some View {
        let file = isFile
        let samples = file ? pipeline.videoCurve : pipeline.chart
        let opt = pipeline.display
        let window = pinchWindow ?? (file ? opt.videoChartWindow : opt.chartWindow)
        let playhead: Double? = file ? (pipeline.scrubTime ?? pipeline.playbackTime) : nil
        let span: ClosedRange<Double>? = file
            ? (dragSpan ?? Self.span(duration: pipeline.playbackDuration, window: window, playhead: playhead ?? 0))
            : nil
        let m = pipeline.marks
        let preview: ClosedRange<Double>? = {
            guard file, let ph = playhead, ph.isFinite,
                  m.baselineEnd == nil || pipeline.scrubTime != nil || pipeline.playbackPaused else { return nil }
            return ph...(ph + pipeline.params.baselineSeconds)
        }()
        let nReg = samples.last?.regions.count ?? 0
        let scrubHandler: ((Double, LiveChart.ScrubPhase) -> Void)? = file ? { t, phase in scrub(t, phase, span) } : nil
        let full: Double = file ? pipeline.playbackDuration
                                : max(0, (samples.last?.t ?? 0) - (samples.first?.t ?? 0))
        let ch = pipeline.params.channel
        let off = clampedOffset(liveOffset ?? CGFloat(opt.chartOffsetY))
        let showRGB = opt.chartShowGB && ch.rgbScale
        // why the Δ curve is empty (shown inside the chart)
        let hint: String? = {
            switch pipeline.result.phase {
            case .waiting: return file ? L("还没有基线：拖到通气前的位置，按 BASELINE") : L("还没有基线：按 BASELINE")
            case .baseline: return L("正在取基线…")
            default: return file && pipeline.scanProgress < 1 ? L("正在扫描曲线…") : nil
            }
        }()
        ZStack {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                moveHandle(current: off)
                Picker("", selection: $pipeline.display.chartMode) {
                    ForEach(ChartMode.allCases) { m in Text(m.label(ch)).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                if opt.chartMode == .raw && nReg <= 1 && ch.rgbScale {
                    Button { pipeline.display.chartShowGB.toggle() } label: {
                        Text("RGB").font(Theme.mono(11, .bold))
                            .foregroundStyle(opt.chartShowGB ? .black : .white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(opt.chartShowGB ? Theme.accent : Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 2)
                if file && pipeline.scanProgress < 1 {
                    Text(String(format: L("扫描曲线 %d%%"), Int(pipeline.scanProgress * 100)))
                        .font(Theme.mono(10, .semibold)).foregroundStyle(.gray)
                } else {
                    readout(samples, mode: opt.chartMode, at: playhead)
                }
                Menu {
                    ForEach(Self.windows, id: \.self) { w in
                        Button(Self.windowLabel(w)) {
                            if file { pipeline.display.videoChartWindow = w } else { pipeline.display.chartWindow = w }
                        }
                    }
                } label: {
                    Text(Self.windowLabel(window)).font(Theme.mono(11, .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            if nReg > 1 { legend(nReg) }
            LiveChart(samples: samples, mode: opt.chartMode, window: window, showGB: showRGB,
                      channel: ch, playhead: playhead, span: span, preview: preview, emptyHint: hint,
                      onScrub: scrubHandler,
                      onZoom: { scale, ended in zoom(scale, ended, file: file, full: full, current: window) })
                .frame(height: 86)
        }
        .padding(8)
        .background(Theme.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
        .offset(y: off)
        }
        .background(GeometryReader { g in
            let top = g.frame(in: .named("stage")).minY
            Color.clear
                .onAppear { baseTop = top }
                .onChange(of: top) { _, v in baseTop = v }
        })
    }

    /// The panel may go up to `minTop` and never below its normal place.
    private func clampedOffset(_ v: CGFloat) -> CGFloat {
        let lowest = baseTop > minTop + 1 ? minTop - baseTop : 0
        return max(lowest, min(0, v.isFinite ? v : 0))
    }

    /// ≡ handle: drag to move the panel, double-tap to put it back.
    private func moveHandle(current: CGFloat) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(liveOffset != nil ? Theme.accent : Color.gray)
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { pipeline.display.chartOffsetY = 0 }
            }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("stage"))
                .onChanged { v in
                    if moveStart == nil { moveStart = current }
                    liveOffset = clampedOffset((moveStart ?? 0) + v.translation.height)
                }
                .onEnded { v in
                    let final = clampedOffset((moveStart ?? current) + v.translation.height)
                    pipeline.display.chartOffsetY = Double(final)
                    liveOffset = nil
                    moveStart = nil
                })
            .accessibilityLabel(L("移动曲线"))
    }

    private func scrub(_ t: Double, _ phase: LiveChart.ScrubPhase, _ span: ClosedRange<Double>?) {
        let tt = min(max(0, t), pipeline.playbackDuration)
        switch phase {
        case .changed:
            if pinchBase != nil && Date().timeIntervalSince(lastPinch) > 0.7 {
                // a pinch that never reported its end: finish it here
                if let w = pinchWindow {
                    if isFile { pipeline.display.videoChartWindow = w } else { pipeline.display.chartWindow = w }
                }
                pinchWindow = nil
                pinchBase = nil
                suppressDrag = false
            }
            if suppressDrag || pinchBase != nil { return }
            if !dragging {
                dragging = true
                dragStartTime = pipeline.playbackTime
                dragSpan = span          // keep the visible range still while dragging
                pipeline.beginScrub()
            }
            pipeline.scrub(to: tt)
        case .ended:
            if dragging && !suppressDrag { pipeline.endScrub(at: tt) }
            suppressDrag = false
            dragging = false
            dragSpan = nil
        }
    }

    /// Two-finger pinch: spread = fewer seconds visible. `full` = everything there is (video length /
    /// live buffer); at or beyond it the window becomes "all".
    private func zoom(_ scale: CGFloat, _ ended: Bool, file: Bool, full: Double, current: Double) {
        lastPinch = Date()
        if pinchBase == nil {
            pinchBase = current > 0 ? current : max(full, Self.minWindow)
            suppressDrag = true
            if dragging {                    // the first finger started a scrub: put the playhead back
                pipeline.endScrub(at: dragStartTime ?? pipeline.playbackTime)
                dragging = false
                dragSpan = nil
            }
        }
        guard let base = pinchBase, base > 0, scale.isFinite, scale > 0 else { return }
        let w = max(Self.minWindow, base / Double(scale))
        let value: Double = (full > 0 && w >= full) ? 0 : (w >= 10 ? w.rounded() : (w * 10).rounded() / 10)
        if ended {
            if file { pipeline.display.videoChartWindow = value } else { pipeline.display.chartWindow = value }
            pinchWindow = nil
            pinchBase = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { suppressDrag = false }
        } else {
            pinchWindow = value
        }
    }

    private func legend(_ n: Int) -> some View {
        let r = pipeline.result.regions
        let ranks = regionArrivalRanks(r)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<n, id: \.self) { k in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1).fill(AnalysisRegions.swiftColor(k)).frame(width: 10, height: 3)
                        Text("\(k + 1)" + (ranks[k].map { RegionOverlay.circled($0) } ?? ""))
                            .foregroundStyle(AnalysisRegions.swiftColor(k))
                    }
                }
            }
            .font(Theme.mono(10, .bold))
        }
    }

    /// Visible time range for a video: the whole file if it fits (or window = all), otherwise a
    /// window around the playhead.
    static func span(duration: Double, window: Double, playhead: Double) -> ClosedRange<Double> {
        let d = duration.isFinite ? max(duration, 0.01) : 0.01
        if window <= 0 || d <= window { return 0...d }
        let ph = playhead.isFinite ? playhead : 0
        let start = min(max(0, ph - window / 2), d - window)
        return start...(start + window)
    }

    @ViewBuilder
    private func readout(_ s: [ChartSample], mode: ChartMode, at playhead: Double?) -> some View {
        let sample: ChartSample? = {
            guard let p = playhead else { return s.last }
            return s.min(by: { abs($0.t - p) < abs($1.t - p) })
        }()
        if let cur = sample {
            VStack(alignment: .trailing, spacing: 0) {
                if mode == .raw {
                    let ch = pipeline.params.channel
                    Text(String(format: "%@ %.2f", ch.shortName, ch.value(r: cur.r, g: cur.g, b: cur.b)))
                        .foregroundStyle(ch.color)
                } else {
                    Text(cur.hasResponse ? String(format: "%+.2f%%", cur.response) : "—").foregroundStyle(Theme.accent)
                }
                if playhead == nil {
                    Text(String(format: L("亮度波动 %.2f%%"), Self.ripple(s))).foregroundStyle(.gray)
                } else {
                    Text(String(format: "t = %.2f s", cur.t)).foregroundStyle(.gray)
                }
            }
            .font(Theme.mono(10, .semibold))
        }
    }

    /// Peak-to-peak variation of the mean brightness over the last second, in % — light flicker shows up here.
    static func ripple(_ s: [ChartSample]) -> Double {
        guard let last = s.last else { return 0 }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude, sum: Float = 0, n: Float = 0
        for p in s.reversed() {
            if last.t - p.t > 1 { break }
            let y = SignalChannel.luma.value(r: p.r, g: p.g, b: p.b)
            lo = min(lo, y); hi = max(hi, y); sum += y; n += 1
        }
        guard n > 1, sum > 0 else { return 0 }
        return Double((hi - lo) / (sum / n) * 100)
    }
}

struct LiveChart: View {
    enum ScrubPhase { case changed, ended }

    let samples: [ChartSample]
    let mode: ChartMode
    /// Visible seconds (0 = everything).
    let window: Double
    let showGB: Bool
    var channel: SignalChannel = .red
    /// Video mode: vertical line at the current position, fixed visible range.
    var playhead: Double? = nil
    var span: ClosedRange<Double>? = nil
    /// Light-blue band: where a baseline taken from the playhead would come from.
    var preview: ClosedRange<Double>? = nil
    /// Shown in the middle when the Δ curve has nothing to draw (no baseline yet …).
    var emptyHint: String? = nil
    /// Video mode: dragging on the chart moves the playhead.
    var onScrub: ((Double, ScrubPhase) -> Void)? = nil
    /// Two-finger pinch: (magnification, ended).
    var onZoom: ((CGFloat, Bool) -> Void)? = nil

    private static let leftPad: CGFloat = 34

    private func range() -> (Double, Double)? {
        if let span { return (span.lowerBound, span.upperBound) }
        guard let last = samples.last else { return nil }
        let tEnd = last.t
        let tStart = window <= 0 ? (samples.first?.t ?? tEnd) : tEnd - window
        return (tStart, max(tEnd, tStart + 0.01))
    }

    var body: some View {
        GeometryReader { geo in
            let rng = range()
            Canvas { ctx, size in draw(ctx, size, rng) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard let onScrub, let r = rng else { return }
                        onScrub(time(at: v.location.x, width: geo.size.width, r.0, r.1), .changed)
                    }
                    .onEnded { v in
                        guard let onScrub, let r = rng else { return }
                        onScrub(time(at: v.location.x, width: geo.size.width, r.0, r.1), .ended)
                    },
                    including: onScrub == nil ? .subviews : .all)
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in onZoom?(v.magnification, false) }
                    .onEnded { v in onZoom?(v.magnification, true) })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func time(at x: CGFloat, width: CGFloat, _ a: Double, _ b: Double) -> Double {
        let plotW = max(1, width - Self.leftPad)
        let f = Double(min(max(0, (x - Self.leftPad) / plotW), 1))
        return a + f * (b - a)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ rng: (Double, Double)?) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
        guard let rr = rng, !samples.isEmpty else {
            ctx.draw(Text(L("等待画面…")).font(Theme.mono(10)).foregroundColor(.gray),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let (tStart, tEnd) = rr
        let shownWindow = max(0.01, tEnd - tStart)
        var vis = samples.filter { $0.t >= tStart && $0.t <= tEnd }
        // thin very long curves to ~2 points per pixel
        let maxPts = Int(size.width * 2)
        if vis.count > maxPts && maxPts > 0 {
            let step = Double(vis.count) / Double(maxPts)
            vis = (0..<maxPts).map { vis[min(vis.count - 1, Int(Double($0) * step))] }
        }
        let leftPad = Self.leftPad
        let plotW = max(1, size.width - leftPad)
        func x(_ t: Double) -> CGFloat { leftPad + CGFloat((t - tStart) / shownWindow) * plotW }
        let nReg = vis.last?.regions.count ?? 0
        let multi = nReg > 1

        func rawValue(_ c: RGBMean) -> Float { channel.value(r: c.r, g: c.g, b: c.b) }

        // value range
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for p in vis {
            if mode == .raw {
                if multi {
                    for c in p.regions { let v = rawValue(c); lo = min(lo, v); hi = max(hi, v) }
                } else if showGB {
                    lo = min(lo, p.r, p.g, p.b); hi = max(hi, p.r, p.g, p.b)
                } else {
                    let v = channel.value(r: p.r, g: p.g, b: p.b)
                    lo = min(lo, v); hi = max(hi, v)
                }
            } else if p.hasResponse {
                if multi {
                    for v in p.regionResponse { lo = min(lo, v); hi = max(hi, v) }
                } else {
                    lo = min(lo, p.response); hi = max(hi, p.response)
                }
            }
        }
        let showRef = mode == .response && vis.contains { $0.refResponse != nil }
        if showRef {
            for p in vis where p.hasResponse {
                if let v = p.refResponse { lo = min(lo, v); hi = max(hi, v) }
            }
        }
        if lo > hi { lo = 0; hi = 1 }
        if mode == .response { lo = min(lo, -0.5); hi = max(hi, 2) }
        let minSpan: Float = mode == .raw ? 2 : 1
        if hi - lo < minSpan {
            let c = (hi + lo) / 2
            lo = c - minSpan / 2; hi = c + minSpan / 2
        }
        let pad = (hi - lo) * 0.08
        lo -= pad; hi += pad
        func y(_ v: Float) -> CGFloat { size.height * (1 - CGFloat((v - lo) / (hi - lo))) }

        // phase bands: baseline (blue), detected (red)
        var i = 0
        while i < vis.count {
            let ph = vis[i].phase
            var j = i
            while j + 1 < vis.count && vis[j + 1].phase == ph { j += 1 }
            if ph == 1 || ph == 3 {
                let x0 = x(vis[i].t), x1 = max(x(vis[j].t), x0 + 1)
                let color: Color = ph == 1 ? .blue.opacity(0.30) : .red.opacity(0.22)
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(color))
            }
            i = j + 1
        }
        // baseline preview (light blue, follows the playhead)
        if let pv = preview {
            let x0 = max(leftPad, x(pv.lowerBound)), x1 = min(size.width, max(x(pv.upperBound), x0 + 1))
            if x1 > x0 {
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                         with: .color(Color(red: 0.55, green: 0.8, blue: 1).opacity(0.22)))
            }
        }

        // grid + labels
        for k in 0...2 {
            let v = lo + (hi - lo) * Float(k) / 2
            let yy = y(v)
            var g = Path()
            g.move(to: CGPoint(x: leftPad, y: yy)); g.addLine(to: CGPoint(x: size.width, y: yy))
            ctx.stroke(g, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            let label = mode == .raw ? String(format: "%.1f", v) : String(format: "%.1f%%", v)
            ctx.draw(Text(label).font(Theme.mono(8)).foregroundColor(.gray),
                     at: CGPoint(x: leftPad - 3, y: min(max(yy, 6), size.height - 6)), anchor: .trailing)
        }
        if mode == .response {
            var z = Path()
            z.move(to: CGPoint(x: leftPad, y: y(0))); z.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(z, with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        }
        let tf = shownWindow < 5 ? "%.2fs" : "%.1fs"
        ctx.draw(Text(String(format: tf, max(0, tStart))).font(Theme.mono(8)).foregroundColor(.gray),
                 at: CGPoint(x: leftPad + 2, y: size.height - 5), anchor: .leading)
        ctx.draw(Text(String(format: tf, tEnd)).font(Theme.mono(8)).foregroundColor(.gray),
                 at: CGPoint(x: size.width - 2, y: size.height - 5), anchor: .trailing)

        // curves
        func curve(_ value: (ChartSample) -> Float?) -> Path {
            var p = Path()
            var started = false
            for s in vis {
                guard let v = value(s) else { started = false; continue }
                let pt = CGPoint(x: x(s.t), y: y(v))
                if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
            }
            return p
        }
        if multi {
            for k in 0..<nReg {
                let color = AnalysisRegions.swiftColor(k)
                if mode == .raw {
                    ctx.stroke(curve({ k < $0.regions.count ? rawValue($0.regions[k]) : nil }), with: .color(color), lineWidth: 1.4)
                } else {
                    // fainter before / during the baseline (video), full after it
                    ctx.stroke(curve({ $0.hasResponse && k < $0.regionResponse.count ? $0.regionResponse[k] : nil }),
                               with: .color(color.opacity(0.4)), lineWidth: 1)
                    ctx.stroke(curve({ $0.hasResponse && $0.phase >= 2 && k < $0.regionResponse.count ? $0.regionResponse[k] : nil }),
                               with: .color(color), lineWidth: 1.4)
                }
            }
        } else if mode == .raw {
            if showGB {
                // R, G, B together; the channel in use is drawn thicker
                ctx.stroke(curve({ $0.b }), with: .color(SignalChannel.blue.color), lineWidth: channel == .blue ? 1.8 : 1)
                ctx.stroke(curve({ $0.g }), with: .color(SignalChannel.green.color), lineWidth: channel == .green ? 1.8 : 1)
                ctx.stroke(curve({ $0.r }), with: .color(SignalChannel.red.color), lineWidth: channel == .red ? 1.8 : 1)
                if channel == .luma {
                    ctx.stroke(curve({ SignalChannel.luma.value(r: $0.r, g: $0.g, b: $0.b) }),
                               with: .color(SignalChannel.luma.color), lineWidth: 1.8)
                }
            } else {
                ctx.stroke(curve({ channel.value(r: $0.r, g: $0.g, b: $0.b) }), with: .color(channel.color), lineWidth: 1.6)
            }
        } else {
            // fainter before / during the baseline (video), full after it
            ctx.stroke(curve({ $0.hasResponse ? $0.response : nil }), with: .color(Theme.accent.opacity(0.4)), lineWidth: 1.2)
            ctx.stroke(curve({ $0.hasResponse && $0.phase >= 2 ? $0.response : nil }), with: .color(Theme.accent), lineWidth: 1.6)
        }
        if mode == .response, let hint = emptyHint, !vis.contains(where: { $0.hasResponse }) {
            ctx.draw(Text(hint).font(Theme.mono(10, .semibold)).foregroundColor(Theme.accent),
                     at: CGPoint(x: leftPad + plotW / 2, y: size.height / 2))
        }
        // reference box (white dashed): what the light / exposure alone did
        if showRef {
            ctx.stroke(curve({ $0.hasResponse ? $0.refResponse : nil }), with: .color(.white.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            ctx.draw(Text("REF").font(Theme.mono(8, .bold)).foregroundColor(.white),
                     at: CGPoint(x: size.width - 2, y: 6), anchor: .trailing)
        }
        // playhead (video mode)
        if let ph = playhead, ph >= tStart, ph <= tEnd {
            var pl = Path()
            let px = x(ph)
            pl.move(to: CGPoint(x: px, y: 0))
            pl.addLine(to: CGPoint(x: px, y: size.height))
            ctx.stroke(pl, with: .color(.white), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: -4, width: 8, height: 8)), with: .color(.white))
        }
    }
}

/// Quick detection settings opened from the gear on the gas status bar.
struct GasQuickPanel: View {
    @EnvironmentObject var pipeline: FramePipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ValueSlider(label: L("基线时长"), value: $pipeline.params.baselineSeconds, range: 0.1...10, help: .baselineSeconds) {
                String(format: "%.2f s", $0)
            }
            BaselineFramesRow()
            ChannelRow()
            HStack(spacing: 6) {
                Text(L("到达判定")).font(Theme.mono(11)).foregroundStyle(.gray)
                Picker("", selection: $pipeline.params.arrivalMode) {
                    ForEach(ArrivalMode.allCases) { m in Text(L(m.label)).tag(m) }
                }
                .pickerStyle(.segmented)
                InfoButton(.arrivalMode)
            }
            ValueSlider(label: L("检测阈值"), value: $pipeline.params.minPercent, range: 0.2...10, help: .threshold) {
                String(format: "%.1f%%", $0)
            }
            Toggle(isOn: $pipeline.params.autoScale) {
                HStack(spacing: 0) {
                    Text(L("自动色标")).font(Theme.mono(11)).foregroundStyle(.gray)
                    InfoButton(.autoScale)
                }
            }
            .tint(Theme.accent)
            if !pipeline.params.autoScale {
                ValueSlider(label: L("色标上限"), value: $pipeline.params.displayMaxPercent, range: 1...40, help: .displayMax) {
                    String(format: "%.0f%%", $0)
                }
            }
            ValueSlider(label: L("帧差间隔"), value: $pipeline.params.flowLagSeconds, range: 0.05...1.5, help: .flowLag) {
                String(format: "%.2f s", $0)
            }
            ValueSlider(label: L("帧差色标"), value: $pipeline.params.flowScalePercent, range: 0.5...10, help: .flowScale) {
                String(format: "%.1f%%", $0)
            }
            Text(L("FLOW = 现在与“帧差间隔”之前相比：红 = 信号正在下降（气体进来），蓝 = 信号在恢复（气体离开）。"))
                .font(Theme.mono(10)).foregroundStyle(.gray)
            Text(pipeline.source == .camera
                 ? L("点 BASELINE 后，从此刻起取上面设定时长的画面平均作为基线。")
                 : L("视频：拖进度条或曲线到要作基线的位置（浅蓝色 = 将取基线的区间），点 BASELINE，会从这里往后播放并取基线。"))
                .font(Theme.mono(10)).foregroundStyle(.gray)
        }
        .padding(10)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }
}

/// Signal channel buttons. After a video has been scanned each one shows its signal-to-noise.
struct ChannelRow: View {
    @EnvironmentObject var pipeline: FramePipeline

    var body: some View {
        let scores = Dictionary(pipeline.channelReport.map { ($0.channel, $0.snr) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(L("通道")).font(Theme.mono(11)).foregroundStyle(.gray)
                ForEach(SignalChannel.allCases) { c in
                    let on = pipeline.params.channel == c
                    Button { pipeline.params.channel = c } label: {
                        VStack(spacing: 0) {
                            Text(c.shortName).font(Theme.mono(12, .bold))
                            if let s = scores[c] {
                                Text("\(s.safeInt)").font(Theme.mono(8))
                                    .foregroundStyle(on ? Color.black.opacity(0.7) : Color.gray)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(on ? Color.black : Color.white)
                        .background(on ? Theme.accent : Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                InfoButton(.channel)
            }
            if !scores.isEmpty {
                Text(L("小数字 = 这段视频里该通道的信噪比（越大越好）"))
                    .font(Theme.mono(9)).foregroundStyle(.gray)
            }
        }
    }
}

/// Baseline length in frames, linked to the seconds slider through the effective analysis rate.
struct BaselineFramesRow: View {
    @EnvironmentObject var pipeline: FramePipeline
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let frames = pipeline.baselineFrameCount
        HStack(spacing: 8) {
            Text(L("基线帧数")).font(Theme.mono(11)).foregroundStyle(.gray).frame(width: 52, alignment: .leading)
            Button { pipeline.setBaselineFrames(frames - 1) } label: { Image(systemName: "minus.circle") }
            TextField(L("帧"), text: $text)
                .keyboardType(.numberPad)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(Theme.mono(13, .semibold))
                .frame(width: 60)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .onSubmit { commit() }
            Button { pipeline.setBaselineFrames(frames + 1) } label: { Image(systemName: "plus.circle") }
            Text(String(format: L("帧 · 分析 %.0f 帧/秒"), pipeline.effectiveAnalysisRate))
                .font(Theme.mono(10)).foregroundStyle(.gray)
            Spacer(minLength: 0)
            if focused {
                Button(L("确定")) { commit() }.font(Theme.mono(12, .bold))
            }
        }
        .foregroundStyle(.white)
        .onAppear { text = "\(frames)" }
        .onChange(of: frames) { _, f in if !focused { text = "\(f)" } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        if let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 {
            pipeline.setBaselineFrames(n)
        }
        text = "\(pipeline.baselineFrameCount)"
        focused = false
    }
}
