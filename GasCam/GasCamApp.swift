import SwiftUI

@main
struct GasCamApp: App {
    @StateObject private var camera: CameraController
    @StateObject private var pipeline: FramePipeline

    init() {
        let cam = CameraController()
        _camera = StateObject(wrappedValue: cam)
        _pipeline = StateObject(wrappedValue: FramePipeline(camera: cam))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .environmentObject(pipeline)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
