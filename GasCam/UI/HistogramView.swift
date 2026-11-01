import SwiftUI

/// Blackmagic-style RGB + luma histogram.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
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
                    let y = size.height * (1 - CGFloat(min(1, max(0, v))))
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
            ctx.stroke(area(histogram.y), with: .color(.white.opacity(0.85)), lineWidth: 1)
            if histogram.clipped > 0.001 {
                ctx.fill(Path(CGRect(x: size.width - 3, y: 0, width: 3, height: size.height)), with: .color(.red))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
    }
}
