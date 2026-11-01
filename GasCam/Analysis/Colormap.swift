import Foundation

enum Colormap {
    /// Google "Turbo" colormap, 256 entries × RGB (polynomial approximation).
    static let turbo: [UInt8] = {
        var out = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let x = Double(i) / 255
            let r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
            let g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
            let b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
            out[i * 3] = UInt8(max(0, min(1, r)) * 255)
            out[i * 3 + 1] = UInt8(max(0, min(1, g)) * 255)
            out[i * 3 + 2] = UInt8(max(0, min(1, b)) * 255)
        }
        return out
    }()
}
