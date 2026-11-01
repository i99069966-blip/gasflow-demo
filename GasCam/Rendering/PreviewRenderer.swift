import Foundation
import CoreImage
import Metal
import MetalKit
import CoreVideo
import CoreGraphics

/// Display-only options (none of these affect analysis or recording).
struct DisplayOptions: Equatable, Codable {
    var overlay: OverlayMode = .heat
    var overlayOpacity: Float = 0.75
    var falseColor = false
    var zebra = false
    var zebraLevel: Float = 0.95
    var peaking = false
    var peakingThreshold: Float = 0.20
    var grid = false
    var crosshair = false
    var level = false
    var showHistogram = true
    var showArrow = true
}

/// Core Image → Metal preview. Camera frames and the analysis overlay arrive from the frame
/// queue; `draw(in:)` runs on the main thread at the display rate.
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    let ciContext: CIContext
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private let lock = NSLock()
    private var frame: CIImage?
    private var overlay: CIImage?
    private var frameID = 0
    private var drawnFrameID = -1

    /// Main thread only.
    var options = DisplayOptions() {
        didSet { if options != oldValue { optionsVersion += 1 } }
    }
    private var optionsVersion = 0
    private var drawnOptionsVersion = -1

    private let falseColorCube: Data = PreviewRenderer.makeCube(dimension: 32, map: PreviewRenderer.falseColor)
    private var zebraCube: Data?
    private var zebraCubeLevel: Float = -1
    private var peakingCube: Data?
    private var peakingCubeLevel: Float = -1

    init?(metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let dev = metalDevice, let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        super.init()
    }

    // MARK: Inputs (any thread)

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        let img = CIImage(cvPixelBuffer: pixelBuffer)
        lock.lock()
        frame = img
        frameID += 1
        lock.unlock()
    }

    func setOverlay(_ image: CIImage?) {
        lock.lock()
        overlay = image
        lock.unlock()
    }

    func clear() {
        lock.lock()
        frame = nil
        overlay = nil
        frameID += 1
        lock.unlock()
    }

    /// Latest composited frame (for "save result image").
    func currentComposite() -> CIImage? {
        lock.lock()
        let f = frame, o = overlay
        lock.unlock()
        guard let f else { return nil }
        return compose(frame: f, overlay: o, includeAssists: false)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawnFrameID = -1
    }

    func draw(in view: MTKView) {
        lock.lock()
        let f = frame, o = overlay, id = frameID
        lock.unlock()
        guard id != drawnFrameID || optionsVersion != drawnOptionsVersion else { return }
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        drawnFrameID = id
        drawnOptionsVersion = optionsVersion

        let size = view.drawableSize
        let target = CGRect(origin: .zero, size: size)
        var out = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: target)
        if let f {
            let img = compose(frame: f, overlay: o, includeAssists: true)
            // aspect-fit into the drawable (SwiftUI sizes the view to the frame aspect)
            let e = img.extent
            let s = min(size.width / e.width, size.height / e.height)
            let w = e.width * s, h = e.height * s
            let t = CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
            out = img.transformed(by: t).composited(over: out)
        }
        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                       pixelFormat: view.colorPixelFormat, commandBuffer: cb,
                                       mtlTextureProvider: { drawable.texture })
        dest.colorSpace = sRGB
        _ = try? ciContext.startTask(toRender: out, to: dest)
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Composition

    private func compose(frame f: CIImage, overlay o: CIImage?, includeAssists: Bool) -> CIImage {
        let extent = f.extent
        var img = f
        let opt = options

        if includeAssists && opt.falseColor {
            img = applyCube(img, falseColorCube, dimension: 32)
        }
        if includeAssists && opt.zebra {
            if zebraCubeLevel != opt.zebraLevel || zebraCube == nil {
                let lvl = opt.zebraLevel
                zebraCube = Self.makeCube(dimension: 32) { y in y >= lvl ? (1, 1, 1) : (0, 0, 0) }
                zebraCubeLevel = lvl
            }
            if let cube = zebraCube {
                let mask = applyCube(f, cube, dimension: 32)
                let stripes = Self.stripes(extent: extent)
                img = blend(foreground: stripes, background: img, mask: mask)
            }
        }
        if includeAssists && opt.peaking {
            if peakingCubeLevel != opt.peakingThreshold || peakingCube == nil {
                let lvl = opt.peakingThreshold
                peakingCube = Self.makeCube(dimension: 16) { y in y >= lvl ? (1, 1, 1) : (0, 0, 0) }
                peakingCubeLevel = lvl
            }
            if let cube = peakingCube, let edges = CIFilter(name: "CIEdges") {
                edges.setValue(f, forKey: kCIInputImageKey)
                edges.setValue(4.0, forKey: kCIInputIntensityKey)
                if let e = edges.outputImage?.cropped(to: extent) {
                    let mask = applyCube(e, cube, dimension: 16)
                    let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1)).cropped(to: extent)
                    img = blend(foreground: red, background: img, mask: mask)
                }
            }
        }
        if let o, opt.overlay != .live {
            let oe = o.extent
            let sx = extent.width / max(oe.width, 1), sy = extent.height / max(oe.height, 1)
            let scaled = o.samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
                .cropped(to: extent)
            img = scaled.composited(over: img)
        }
        return img.cropped(to: extent)
    }

    private func applyCube(_ image: CIImage, _ cube: Data, dimension: Int) -> CIImage {
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(dimension, forKey: "inputCubeDimension")
        f.setValue(cube, forKey: "inputCubeData")
        f.setValue(sRGB, forKey: "inputColorSpace")
        return f.outputImage?.cropped(to: image.extent) ?? image
    }

    private func blend(foreground: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIBlendWithMask") else { return background }
        f.setValue(foreground, forKey: kCIInputImageKey)
        f.setValue(background, forKey: kCIInputBackgroundImageKey)
        f.setValue(mask, forKey: kCIInputMaskImageKey)
        return f.outputImage?.cropped(to: background.extent) ?? background
    }

    private static func stripes(extent: CGRect) -> CIImage {
        guard let f = CIFilter(name: "CIStripesGenerator") else {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        }
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        f.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor0")
        f.setValue(CIColor(red: 0, green: 0, blue: 0), forKey: "inputColor1")
        f.setValue(max(4, extent.width / 120), forKey: "inputWidth")
        f.setValue(1.0, forKey: "inputSharpness")
        let img = f.outputImage ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        return img.transformed(by: CGAffineTransform(rotationAngle: .pi / 4)).cropped(to: extent)
    }

    // MARK: Cubes

    /// Builds a colour cube that maps Rec.709 luma (of sRGB-encoded values) through `map`.
    static func makeCube(dimension n: Int, map: (Float) -> (Float, Float, Float)) -> Data {
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        let d = Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let y = 0.2126 * Float(r) / d + 0.7152 * Float(g) / d + 0.0722 * Float(b) / d
                    let c = map(y)
                    data[i] = c.0
                    data[i + 1] = c.1
                    data[i + 2] = c.2
                    data[i + 3] = 1
                    i += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// ARRI-style false colour (IRE bands) with grey elsewhere.
    static func falseColor(_ y: Float) -> (Float, Float, Float) {
        switch y {
        case ..<0.025: return (0.55, 0.0, 0.75)       // purple: crushed blacks
        case ..<0.04: return (0.1, 0.35, 1.0)         // blue: near black
        case 0.38..<0.42: return (0.1, 0.85, 0.2)     // green: 18 % grey
        case 0.52..<0.56: return (1.0, 0.45, 0.7)     // pink: one stop over grey / skin
        case 0.97..<0.99: return (1.0, 0.95, 0.0)     // yellow: near clipping
        case 0.99...: return (1.0, 0.0, 0.0)          // red: clipped
        default:
            let g = 0.15 + 0.6 * y
            return (g, g, g)
        }
    }
}
