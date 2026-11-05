import SwiftUI

/// Live curve of the ROI: raw mean R (optionally G/B) or mean ΔR/R %.
/// Blue band = baseline being taken, red band = gas detected.
struct ChartPanel: View {
    @EnvironmentObject var pipeline: FramePipeline
    private static let windows: [Double] = [10, 30, 60, 120]

    private var isFile: Bool {
        if case .file = pipeline.source { return true }
        return false
    }

    var body: some View {
        let file = isFile
        let samples = file ? pipeline.videoCurve : pipeline.chart
        let opt = pipeline.display
        let playhead: Double? = file ? (pipeline.scrubTime ?? pipeline.playbackTime) : nil
        let span: ClosedRange<Double>? = file ? Self.span(duration: pipeline.playbackDuration,
                                                          window: opt.chartWindow, playhead: playhead ?? 0) : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $pipeline.display.chartMode) {
                    ForEach(ChartMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                if opt.chartMode == .raw {
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
                    Text("扫描曲线 \(Int(pipeline.scanProgress * 100))%")
                        .font(Theme.mono(10, .semibold)).foregroundStyle(.gray)
                } else {
                    readout(samples, mode: opt.chartMode, at: playhead)
                }
                Menu {
                    ForEach(Self.windows, id: \.self) { w in
                        Button("\(Int(w)) s") { pipeline.display.chartWindow = w }
                    }
                } label: {
                    Text("\(Int(opt.chartWindow))s").font(Theme.mono(11, .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            LiveChart(samples: samples, mode: opt.chartMode, window: opt.chartWindow, showGB: opt.chartShowGB,
                      playhead: playhead, span: span)
                .frame(height: 86)
        }
        .padding(8)
        .background(Theme.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }

    /// Visible time range for a video: the whole file if it fits, otherwise a window around the playhead.
    static func span(duration: Double, window: Double, playhead: Double) -> ClosedRange<Double> {
        let d = max(duration, 0.01)
        if d <= window { return 0...d }
        let start = min(max(0, playhead - window / 2), d - window)
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
                    Text(String(format: "亮度波动 %.2f%%", Self.ripple(s))).foregroundStyle(.gray)
                } else {
                    Text(String(format: "t = %.2f s", cur.t)).foregroundStyle(.gray)
                }
            }
            .font(Theme.mono(10, .semibold))
        }
    }

    /// Peak-to-peak variation of the ROI mean R over the last second, in % — light flicker shows up here.
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
    let samples: [ChartSample]
    let mode: ChartMode
    let window: Double
    let showGB: Bool
    /// Video mode: vertical line at the current position, fixed visible range.
    var playhead: Double? = nil
    var span: ClosedRange<Double>? = nil

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
            guard let last = samples.last else {
                ctx.draw(Text("等待画面…").font(Theme.mono(10)).foregroundColor(.gray),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let tEnd = span?.upperBound ?? last.t
            let tStart = span?.lowerBound ?? (tEnd - window)
            let shownWindow = max(0.01, tEnd - tStart)
            let vis = samples.filter { $0.t >= tStart && $0.t <= tEnd }
            let leftPad: CGFloat = 34
            let plotW = max(1, size.width - leftPad)
            func x(_ t: Double) -> CGFloat { leftPad + CGFloat((t - tStart) / shownWindow) * plotW }

            // value range
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for p in vis {
                if mode == .raw {
                    lo = min(lo, p.r); hi = max(hi, p.r)
                    if showGB { lo = min(lo, p.g, p.b); hi = max(hi, p.g, p.b) }
                } else if p.phase >= 2 {
                    lo = min(lo, p.response); hi = max(hi, p.response)
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
                    let color: Color = ph == 1 ? .blue.opacity(0.22) : .red.opacity(0.22)
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(color))
                }
                i = j + 1
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
            if mode == .raw {
                if showGB {
                    ctx.stroke(curve({ $0.g }), with: .color(Color(red: 0.3, green: 0.9, blue: 0.4)), lineWidth: 1)
                    ctx.stroke(curve({ $0.b }), with: .color(Color(red: 0.35, green: 0.55, blue: 1)), lineWidth: 1)
                }
                ctx.stroke(curve({ $0.r }), with: .color(Color(red: 1, green: 0.35, blue: 0.3)), lineWidth: 1.6)
            } else {
                ctx.stroke(curve({ $0.phase >= 2 ? $0.response : nil }), with: .color(Theme.accent), lineWidth: 1.6)
            }
            // playhead (video mode)
            if let ph = playhead, ph >= tStart, ph <= tEnd {
                var pl = Path()
                let px = x(ph)
                pl.move(to: CGPoint(x: px, y: 0))
                pl.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(pl, with: .color(.white), lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Quick detection settings opened from the gear on the gas status bar.
struct GasQuickPanel: View {
    @EnvironmentObject var pipeline: FramePipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ValueSlider(label: "基线时长", value: $pipeline.params.baselineSeconds, range: 0.1...10) {
                String(format: "%.2f s", $0)
            }
            BaselineFramesRow()
            ValueSlider(label: "检测阈值", value: $pipeline.params.minPercent, range: 0.2...10) {
                String(format: "%.1f%%", $0)
            }
            ValueSlider(label: "色标上限", value: $pipeline.params.displayMaxPercent, range: 1...40) {
                String(format: "%.0f%%", $0)
            }
            ValueSlider(label: "帧差间隔", value: $pipeline.params.flowLagSeconds, range: 0.05...1.5) {
                String(format: "%.2f s", $0)
            }
            ValueSlider(label: "帧差色标", value: $pipeline.params.flowScalePercent, range: 0.5...10) {
                String(format: "%.1f%%", $0)
            }
            Text("FLOW = 现在与“帧差间隔”之前相比：红 = R 正在下降（气体进来），蓝 = R 在恢复（气体离开）。")
                .font(Theme.mono(10)).foregroundStyle(.gray)
            Text(pipeline.source == .camera
                 ? "点 BASELINE 后，从此刻起取上面设定时长的画面平均作为基线。"
                 : "视频：拖进度条到要作基线的位置，点 BASELINE，会从这里往后播放并取基线。")
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
            Text("基线帧数").font(Theme.mono(11)).foregroundStyle(.gray).frame(width: 52, alignment: .leading)
            Button { pipeline.setBaselineFrames(frames - 1) } label: { Image(systemName: "minus.circle") }
            TextField("帧", text: $text)
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
            Text(String(format: "帧 · 分析 %.0f 帧/秒", pipeline.effectiveAnalysisRate))
                .font(Theme.mono(10)).foregroundStyle(.gray)
            Spacer(minLength: 0)
            if focused {
                Button("确定") { commit() }.font(Theme.mono(12, .bold))
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
