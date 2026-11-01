import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable

/// A movie picked from Photos, copied into the app's temp folder.
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: received.file, to: dst)
            return MovieFile(url: dst)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var pipeline: FramePipeline
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var showImporter = false
    @State private var loadingVideo = false
    @State private var recordings: [URL] = []

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                recordingSection
                assistSection
                detectionSection
                advancedSection
                aboutSection
            }
            .navigationTitle("GasCam 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie]) { result in
                handleImport(result)
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                loadingVideo = true
                Task {
                    do {
                        if let movie = try await item.loadTransferable(type: MovieFile.self) {
                            await MainActor.run {
                                loadingVideo = false
                                pipeline.openVideo(url: movie.url)
                                dismiss()
                            }
                        } else {
                            await MainActor.run { loadingVideo = false }
                        }
                    } catch {
                        await MainActor.run {
                            loadingVideo = false
                            pipeline.toast = "导入失败: \(error.localizedDescription)"
                        }
                    }
                }
            }
            .onAppear { recordings = Self.listRecordings() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var videoSection: some View {
        Section {
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                Label(loadingVideo ? "正在载入…" : "从相册导入视频分析", systemImage: "photo.on.rectangle")
            }
            Button { showImporter = true } label: {
                Label("从“文件”导入视频分析", systemImage: "folder")
            }
            if !recordings.isEmpty {
                DisclosureGroup("本 App 的录像（\(recordings.count)）") {
                    ForEach(recordings, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            pipeline.openVideo(url: url)
                            dismiss()
                        }
                        .font(Theme.mono(12))
                    }
                }
            }
            Picker("回放速度", selection: $pipeline.playbackSpeed) {
                Text("0.1×").tag(0.1)
                Text("0.25×").tag(0.25)
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("最快").tag(0.0)
            }
        } header: {
            Text("视频分析（离线 / 模拟器测试）")
        } footer: {
            Text("导入的视频走与实时相机完全相同的检测流程：前 \(pipeline.params.baselineFrames) 帧作基线。在 iOS 模拟器中没有相机，可把视频拖进模拟器的“照片”后从这里导入。")
        }
    }

    private var recordingSection: some View {
        Section {
            Picker("分辨率", selection: Binding(get: { camera.resolution }, set: { camera.setResolution($0) })) {
                ForEach(camera.supportedResolutions) { r in Text(r.label).tag(r) }
            }
            .disabled(pipeline.isRecording)
            Picker("帧率", selection: Binding(get: { camera.frameRate }, set: { camera.setFrameRate($0) })) {
                ForEach(camera.supportedFrameRates, id: \.self) { f in Text("\(Int(f)) fps").tag(f) }
            }
            .disabled(pipeline.isRecording)
            Picker("编码", selection: $pipeline.recordSettings.codec) {
                ForEach(VideoCodec.allCases) { c in Text(c.label).tag(c) }
            }
            .disabled(pipeline.isRecording)
            Picker("比特率", selection: $pipeline.recordSettings.bitrateMbps) {
                ForEach(RecordSettings.bitratePresets, id: \.self) { b in Text("\(Int(b)) Mb/s").tag(b) }
            }
            .disabled(pipeline.isRecording)
            Toggle("录完存入相册", isOn: $pipeline.recordSettings.saveToPhotos)
            Toggle("同时写 CSV 分析日志", isOn: $pipeline.recordSettings.writeCSV)
        } header: {
            Text("录制")
        } footer: {
            Text("录像 (.mov)、设置 (.json)、日志 (.csv) 和结果图 (.png) 保存在“文件”App → 我的 iPhone → GasCam。防抖和 HDR 已关闭，以免改变像素值。")
        }
    }

    private var assistSection: some View {
        Section("辅助显示") {
            Toggle("直方图", isOn: $pipeline.display.showHistogram)
            Toggle("假色 False Color", isOn: $pipeline.display.falseColor)
            Toggle("斑马纹 Zebra", isOn: $pipeline.display.zebra)
            ValueSlider(label: "斑马阈值", value: $pipeline.display.zebraLevel, range: 0.70...1.0) { "\(Int(($0 * 100).rounded()))%" }
            Toggle("峰值对焦 Peaking", isOn: $pipeline.display.peaking)
            ValueSlider(label: "峰值灵敏", value: $pipeline.display.peakingThreshold, range: 0.05...0.6) { String(format: "%.2f", $0) }
            Toggle("三分线", isOn: $pipeline.display.grid)
            Toggle("中心十字", isOn: $pipeline.display.crosshair)
            Toggle("水平仪（镜头朝下）", isOn: $pipeline.display.level)
            Toggle("显示气源箭头", isOn: $pipeline.display.showArrow)
            ValueSlider(label: "叠加透明", value: $pipeline.display.overlayOpacity, range: 0.1...1.0) { String(format: "%.2f", $0) }
        }
    }

    private var detectionSection: some View {
        Section {
            Picker("信号通道", selection: $pipeline.params.channel) {
                ForEach(SignalChannel.allCases) { c in Text(c.label).tag(c) }
            }
            Picker("响应方向", selection: $pipeline.params.polarity) {
                ForEach(ResponsePolarity.allCases) { p in Text(p.label).tag(p) }
            }
            ValueSlider(label: "最小阈值", value: $pipeline.params.minPercent, range: 0.2...10) { String(format: "%.1f%%", $0) }
            ValueSlider(label: "k·σ", value: $pipeline.params.kSigma, range: 1...10) { String(format: "%.1f", $0) }
            ValueSlider(label: "色标上限", value: $pipeline.params.displayMaxPercent, range: 1...40) { String(format: "%.0f%%", $0) }
            ValueSlider(label: "到达色标", value: $pipeline.params.arrivalSpan, range: 0.1...10) { String(format: "%.1fs", $0) }
            Toggle("取基线时锁定 AE/AWB/AF", isOn: $pipeline.params.lockCameraOnBaseline)
        } header: {
            Text("气体检测")
        } footer: {
            Text("响应 = 100·(S−S₀)/S₀；像素超过 max(最小阈值, k·基线噪声) 即视为有气体。用你的乙醇视频验证的默认值：R 通道、下降、2%、k=4。")
        }
    }

    private var advancedSection: some View {
        Section {
            Stepper("空间平滑半径: \(pipeline.params.blurRadius)", value: $pipeline.params.blurRadius, in: 0...8)
            Stepper("基线帧数: \(pipeline.params.baselineFrames)", value: $pipeline.params.baselineFrames, in: 5...300, step: 5)
            Stepper("确认帧数: \(pipeline.params.confirmFrames)", value: $pipeline.params.confirmFrames, in: 1...10)
            ValueSlider(label: "时间平滑", value: $pipeline.params.emaAlpha, range: 0.05...1) { String(format: "α %.2f", $0) }
            Picker("分析频率", selection: $pipeline.params.analysisRate) {
                Text("15 Hz").tag(15.0)
                Text("30 Hz").tag(30.0)
                Text("60 Hz").tag(60.0)
                Text("每帧").tag(1000.0)
            }
            ValueSlider(label: "方向置信", value: $pipeline.params.directionConfMin, range: 0.05...0.8) { String(format: "%.2f", $0) }
            ValueSlider(label: "最少到达", value: $pipeline.params.minArrivedFraction, range: 0.001...0.1) { String(format: "%.1f%%", $0 * 100) }
            Picker("自动重置", selection: $pipeline.params.autoRearmSeconds) {
                Text("关闭").tag(0.0)
                Text("气体消失 3 s 后").tag(3.0)
                Text("气体消失 5 s 后").tag(5.0)
                Text("气体消失 10 s 后").tag(10.0)
            }
            Toggle("基线漂移跟踪（慢速）", isOn: $pipeline.params.baselineTracking)
            Button("恢复检测默认值") { pipeline.params = GasParams() }
            Button("ROI 恢复默认") { pipeline.roi = .defaultROI }
        } header: {
            Text("检测（高级）")
        } footer: {
            Text("箭头：E = 最早被气体到达的 5% 像素的重心，C = 所有已到达像素的重心，方向 C→E 延长到 ROI 边缘（红色 ×）即气体进入基板的位置。置信度 = |E−C| / 羽流半径；低于阈值时认为气体从基板正上方扩散（显示同心圆）。")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: "1.0")
            LabeledContent("分析网格", value: "长边 256 px")
            Text("参考实现：tools/gas_reference.py（与 App 算法逐步一致，可在电脑上复现 App 的结果）。")
                .font(.footnote).foregroundStyle(.gray)
        }
    }

    // MARK: Helpers

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: url, to: dst)
            pipeline.openVideo(url: dst)
            dismiss()
        } catch {
            pipeline.toast = "导入失败: \(error.localizedDescription)"
        }
    }

    static func listRecordings() -> [URL] {
        let dir = FramePipeline.documentsURL
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }
}
