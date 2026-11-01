import Foundation
import Accelerate
import CoreVideo

/// Shrinks a full-resolution BGRA camera frame to the analysis grid with vImage (SIMD, ~1 ms).
final class FrameDownsampler {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private var dest: vImage_Buffer

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        let data = UnsafeMutableRawPointer.allocate(byteCount: width * 4 * height, alignment: 64)
        dest = vImage_Buffer(data: data,
                             height: vImagePixelCount(height),
                             width: vImagePixelCount(width),
                             rowBytes: width * 4)
    }

    deinit { dest.data.deallocate() }

    var pixels: UnsafePointer<UInt8> {
        UnsafePointer(dest.data.assumingMemoryBound(to: UInt8.self))
    }

    /// `pixelBuffer` must be kCVPixelFormatType_32BGRA.
    @discardableResult
    func downsample(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        var src = vImage_Buffer(data: base,
                                height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
                                rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        let err = vImageScale_ARGB8888(&src, &dest, nil, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError
    }

    /// Analysis grid for a frame: long side 256, short side scaled (144 for 16:9).
    static func gridSize(forFrameWidth w: Int, height h: Int) -> (Int, Int) {
        let long = 256
        if h >= w {
            let sw = max(64, Int((Double(long) * Double(w) / Double(max(h, 1))).rounded()))
            return (sw, long)
        } else {
            let sh = max(64, Int((Double(long) * Double(h) / Double(max(w, 1))).rounded()))
            return (long, sh)
        }
    }
}

/// RGB + luma histogram of the analysis-size frame (64 bins, normalised to the tallest bin).
struct Histogram: Equatable {
    static let bins = 64
    var r = [Float](repeating: 0, count: bins)
    var g = [Float](repeating: 0, count: bins)
    var b = [Float](repeating: 0, count: bins)
    var y = [Float](repeating: 0, count: bins)
    /// Fraction of pixels at 255 in any channel.
    var clipped: Float = 0

    static func compute(bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Histogram {
        var hr = [Int](repeating: 0, count: bins)
        var hg = [Int](repeating: 0, count: bins)
        var hb = [Int](repeating: 0, count: bins)
        var hy = [Int](repeating: 0, count: bins)
        var clip = 0
        let shift = 2 // 256 / 64
        for yy in 0..<height {
            let row = bgra + yy * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                let B = Int(p[0]), G = Int(p[1]), R = Int(p[2])
                hr[R >> shift] += 1
                hg[G >> shift] += 1
                hb[B >> shift] += 1
                let Y = (54 * R + 183 * G + 19 * B) >> 8
                hy[min(255, Y) >> shift] += 1
                if R >= 255 || G >= 255 || B >= 255 { clip += 1 }
            }
        }
        let m = Float(max(1, max(hr.max() ?? 1, hg.max() ?? 1, hb.max() ?? 1, hy.max() ?? 1)))
        var h = Histogram()
        // square-root scale keeps small populations visible
        h.r = hr.map { ($0 > 0 ? Float($0).squareRoot() / m.squareRoot() : 0) }
        h.g = hg.map { ($0 > 0 ? Float($0).squareRoot() / m.squareRoot() : 0) }
        h.b = hb.map { ($0 > 0 ? Float($0).squareRoot() / m.squareRoot() : 0) }
        h.y = hy.map { ($0 > 0 ? Float($0).squareRoot() / m.squareRoot() : 0) }
        h.clipped = Float(clip) / Float(max(1, width * height))
        return h
    }
}
