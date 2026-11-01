import SwiftUI
import MetalKit

struct MetalPreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false          // Core Image writes into the drawable texture
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.preferredFramesPerSecond = 60
        v.autoResizeDrawable = true
        v.contentMode = .scaleAspectFit
        v.backgroundColor = .black
        v.clearColor = MTLClearColorMake(0, 0, 0, 1)
        v.delegate = renderer
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
