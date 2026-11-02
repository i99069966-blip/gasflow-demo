import SwiftUI

/// Live curve of the ROI: raw mean R (optionally G/B) or mean ΔR/R %.
/// Blue band = baseline being taken, red band = gas detected.
struct ChartPanel: View {
    @EnvironmentObject var pipeline: FramePipeline
    private static let windows: [Double] = [10, 30, 60, 120]

    var body: some View {
        let samples = pipeline.chart
        let opt = pipeline.display
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
                readout(samples, mode: opt.chartMode)
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
            LiveChart(samples: samples, mode: opt.chartMode, window: opt.chartWindow, showGB: opt.chartShowGB)
                .frame(height: 86)
        }
        .padding(8)
        .background(Theme.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func readout(_ s: [ChartSample], mode: ChartMode) -> some View {
        if let last = s.last {
            VStack(alignment: .trailing, spacing: 0) {
                if mode == .raw {
                    Text(String(format: "R %.2f", last.r)).foregroundStyle(Color(red: 1, green: 0.35, blue: 0.3))
                } else {
                    Text(String(format: "%+.2f%%", last.response)).foregroundStyle(Theme.accent)
                }
                Text(String(format: "亮度波动 %.2f%%", Self.ripple(s))).foregroundStyle(.gray)
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

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
            guard let last = samples.last else {
                ctx.draw(Text("等待画面…").font(Theme.mono(10)).foregroundColor(.gray),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let tEnd = last.t
            let tStart = tEnd - window
            let firstIdx = samples.firstIndex(where: { $0.t >= tStart }) ?? 0
            let vis = Array(samples[firstIdx...])
            let leftPad: CGFloat = 34
            let plotW = max(1, size.width - leftPad)
            func x(_ t: Double) -> CGFloat { leftPad + CGFloat((t - tStart) / window) * plotW }

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
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Quick detection settings opened from the gear on the gas status bar.
struct GasQuickPanel: View {
    @EnvironmentObject var pipeline: FramePipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ValueSlider(label: "基线时长", value: $pipeline.params.baselineSeconds, range: 0.2...10) {
                String(format: "%.1f s", $0)
            }
            ValueSlider(label: "检测阈值", value: $pipeline.params.minPercent, range: 0.2...10) {
                String(format: "%.1f%%", $0)
            }
            ValueSlider(label: "色标上限", value: $pipeline.params.displayMaxPercent, range: 1...40) {
                String(format: "%.0f%%", $0)
            }
            Text(pipeline.source == .camera
                 ? "点 BASELINE 后，从此刻起取上面设定时长的画面平均作为基线。"
                 : "视频：先拖进度条到要作基线的位置（暂停也可以），再点 BASELINE。")
                .font(Theme.mono(10)).foregroundStyle(.gray)
        }
        .padding(10)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
    }
}
