import SwiftUI

/// Blackmagic-style RGB histogram with the measurement zones marked. Tap for an explanation.
struct HistogramView: View {
    let histogram: Histogram
    @State private var showHelp = false

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            // good exposure zone 60–90 % (same as the false colour green and the AUTO target)
            ctx.fill(Path(CGRect(x: size.width * 0.60, y: 0, width: size.width * 0.30, height: size.height)),
                     with: .color(Color.green.opacity(0.16)))
            // grid at 25 / 50 / 75 %
            for f: CGFloat in [0.25, 0.5, 0.75] {
                var p = Path()
                p.move(to: CGPoint(x: size.width * f, y: 0))
                p.addLine(to: CGPoint(x: size.width * f, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            }
            func area(_ bins: [Float]) -> Path {
                var p = Path()
                let n = bins.count
                guard n > 1 else { return p }
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(n - 1)
                    let y = size.height * (1 - CGFloat(min(1, max(0, v.isFinite ? v : 0))))
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.blendMode = .plusLighter
            ctx.fill(area(histogram.r), with: .color(.red.opacity(0.55)))
            ctx.fill(area(histogram.g), with: .color(.green.opacity(0.55)))
            ctx.fill(area(histogram.b), with: .color(.blue.opacity(0.7)))
            ctx.blendMode = .normal
            let label = Font.system(size: 7, weight: .semibold, design: .monospaced)
            ctx.draw(Text(L("暗")).font(label).foregroundColor(.gray), at: CGPoint(x: 3, y: size.height - 5), anchor: .leading)
            ctx.draw(Text(L("亮")).font(label).foregroundColor(.gray), at: CGPoint(x: size.width - 5, y: size.height - 5), anchor: .trailing)
            if histogram.clipped > 0.001 {
                ctx.fill(Path(CGRect(x: size.width - 3, y: 0, width: 3, height: size.height)), with: .color(.red))
                ctx.draw(Text(L("过曝")).font(label).foregroundColor(.red), at: CGPoint(x: size.width - 5, y: 5), anchor: .trailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { showHelp = true }
        .alert(L("直方图"), isPresented: $showHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L("横轴是亮度（左暗右亮），纵轴是这个亮度的像素有多少，R、G、B 分开画。\n\n绿色区域（60–90%）= 合适的亮度，基板的峰最好落在这里。\n\n右边出现红条 = 有像素过曝，这些地方测不出颜色变化。\n\n峰挤在最左边 = 太暗，噪声大。"))
        }
    }
}
