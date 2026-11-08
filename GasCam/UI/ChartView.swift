import SwiftUI

/// Live curve of the analysis regions: raw mean (R or the signal channel) or mean ΔS/S %.
/// Blue band = baseline, light blue = where a baseline would be taken from here, red band = gas detected.
struct ChartPanel: View {
    @EnvironmentObject var pipeline: FramePipeline
    /// 0 = everything (whole video / whole live buffer).
    private static let windows: [Double] = [10, 30, 60, 120, 0]
    @State private var dragging = false
    @State private var dragSpan: ClosedRange<Double>?

    private var isFile: Bool {
        if case .file = pipeline.source { return true }
        return false
    }

    static func windowLabel(_ w: Double) -> String { w <= 0 ? L("全部") : "\(Int(w))s" }

    var body: some View {
        let file = isFile
        let samples = file ? pipeline.videoCurve : pipeline.chart
        let opt = pipeline.display
        let window = file ? opt.videoChartWindow : opt.chartWindow
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $pipeline.display.chartMode) {
                    ForEach(ChartMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                if opt.chartMode == .raw && nReg <= 1 {
                    Button { pipeline.display.chartShowGB.toggle() } label: {
                        Text("G B").font(Theme.mono(11, .bold))
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
            LiveChart(samples: samples, mode: opt.chartMode, window: window, showGB: opt.chartShowGB,
                      channel: pipeline.params.channel, playhead: playhead, span: span, preview: preview,
                      onScrub: scrubHandler)
                .frame(height: 86)
        }
        .padding(8)
        .background(Theme.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }

    private func scrub(_ t: Double, _ phase: LiveChart.ScrubPhase, _ span: ClosedRange<Double>?) {
        let tt = min(max(0, t), pipeline.playbackDuration)
        switch phase {
        case .changed:
            if !dragging {
                dragging = true
                dragSpan = span          // keep the visible range still while dragging
                pipeline.beginScrub()
            }
            pipeline.scrub(to: tt)
        case .ended:
            if dragging { pipeline.endScrub(at: tt) }
            dragging = false
            dragSpan = nil
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
                    Text(String(format: "R %.2f", cur.r)).foregroundStyle(Color(red: 1, green: 0.35, blue: 0.3))
                } else {
                    Text(String(format: "%+.2f%%", cur.response)).foregroundStyle(Theme.accent)
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

    /// Peak-to-peak variation of the mean R over the last second, in % — light flicker shows up here.
    static func ripple(_ s: [ChartSample]) -> Double {
        guard let last = s.last else { return 0 }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude, sum: Float = 0, n: Float = 0
        for p in s.reversed() {
            if last.t - p.t > 1 { break }
            lo = min(lo, p.r); hi = max(hi, p.r); sum += p.r; n += 1
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
    /// Video mode: dragging on the chart moves the playhead.
    var onScrub: ((Double, ScrubPhase) -> Void)? = nil

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
                } else {
                    lo = min(lo, p.r); hi = max(hi, p.r)
                    if showGB { lo = min(lo, p.g, p.b); hi = max(hi, p.g, p.b) }
                }
            } else if p.phase >= 2 {
                if multi {
                    for v in p.regionResponse { lo = min(lo, v); hi = max(hi, v) }
                } else {
                    lo = min(lo, p.response); hi = max(hi, p.response)
                }
            }
        }
        let showRef = mode == .response && vis.contains { $0.refResponse != nil }
        if showRef {
            for p in vis where p.phase >= 2 {
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
        ctx.draw(Text(String(format: "%.1fs", max(0, tStart))).font(Theme.mono(8)).foregroundColor(.gray),
                 at: CGPoint(x: leftPad + 2, y: size.height - 5), anchor: .leading)
        ctx.draw(Text(String(format: "%.1fs", tEnd)).font(Theme.mono(8)).foregroundColor(.gray),
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
                let path: Path = mode == .raw
                    ? curve({ k < $0.regions.count ? rawValue($0.regions[k]) : nil })
                    : curve({ $0.phase >= 2 && k < $0.regionResponse.count ? $0.regionResponse[k] : nil })
                ctx.stroke(path, with: .color(AnalysisRegions.swiftColor(k)), lineWidth: 1.4)
            }
        } else if mode == .raw {
            if showGB {
                ctx.stroke(curve({ $0.g }), with: .color(Color(red: 0.3, green: 0.9, blue: 0.4)), lineWidth: 1)
                ctx.stroke(curve({ $0.b }), with: .color(Color(red: 0.35, green: 0.55, blue: 1)), lineWidth: 1)
            }
            ctx.stroke(curve({ $0.r }), with: .color(Color(red: 1, green: 0.35, blue: 0.3)), lineWidth: 1.6)
        } else {
            ctx.stroke(curve({ $0.phase >= 2 ? $0.response : nil }), with: .color(Theme.accent), lineWidth: 1.6)
        }
        // reference box (white dashed): what the light / exposure alone did
        if showRef {
            ctx.stroke(curve({ $0.phase >= 2 ? $0.refResponse : nil }), with: .color(.white.opacity(0.85)),
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
            if case .file = pipeline.source, !pipeline.channelReport.isEmpty {
                HStack(spacing: 0) {
                    Text(L("通道信噪比") + "：" + pipeline.channelReport.map { "\($0.shortName) \(Int($0.snr.rounded()))" }
                        .joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(.gray)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    InfoButton(.channel)
                }
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
