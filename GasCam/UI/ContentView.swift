import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var pipeline: FramePipeline
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeControl: CameraControlKind?
    @State private var showSettings = false
    @State private var editROI = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(active: $activeControl)
                ZStack(alignment: .bottom) {
                    PreviewArea(editROI: $editROI)
                    VStack(spacing: 6) {
                        if pipeline.source == .camera, let c = activeControl {
                            ControlPanel(kind: c)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        GasStatusBar()
                        if pipeline.source == .camera {
                            CameraBottomBar(active: $activeControl, showSettings: $showSettings)
                        } else {
                            PlaybackBar(showSettings: $showSettings)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .overlay(alignment: .topTrailing) {
                    AssistColumn(editROI: $editROI)
                        .padding(.top, 8)
                        .padding(.trailing, 6)
                }
            }
            if let msg = pipeline.toast ?? camera.statusMessage {
                Text(msg)
                    .font(Theme.mono(12, .semibold))
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 70)
                    .padding(.horizontal, 20)
                    .onTapGesture { dismissToast() }
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        dismissToast()
                    }
            }
            if pipeline.source == .camera && (camera.authorization == .denied || camera.authorization == .restricted) {
                permissionView
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(camera)
                .environmentObject(pipeline)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on during experiments
            pipeline.startCamera()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if pipeline.isRecording { pipeline.stopRecording() }
                camera.stop()
            case .active:
                if pipeline.source == .camera { camera.start() }
            default:
                break
            }
        }
    }

    private func dismissToast() {
        pipeline.toast = nil
        camera.statusMessage = nil
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("需要相机权限").font(.headline)
            Text("请在 设置 → GasCam 中允许访问相机。\n也可以在设置页导入视频进行离线分析。")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.gray)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            Button("导入视频分析") { showSettings = true }
        }
        .padding(24)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.top, 200)
    }
}
