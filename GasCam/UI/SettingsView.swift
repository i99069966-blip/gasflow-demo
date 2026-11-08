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
    @ObservedObject private var lang = LanguageSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var showImporter = false
    @State private var loadingVideo = false
    @State private var recordingCount = 0
    @State private var crashLogs: [URL] = []

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                videoSection
                recordingSection
                cameraSection
                assistSection
                detectionSection
                advancedSection
                crashSection
                aboutSection
            }
            .navigationTitle(L("GasCam 设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
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
                            pipeline.toast = L("导入失败") + ": \(error.localizedDescription)"
                        }
                    }
                }
            }
            .onAppear {
                recordingCount = RecordingStore.list().count
                crashLogs = CrashReporter.list()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var languageSection: some View {
        Section {
            Picker(L("语言"), selection: $lang.choice) {
                ForEach(AppLanguage.allCases) { l in Text(l.label).tag(l) }
            }
        } footer: {
            Text(L("默认跟随手机系统语言。"))
        }
    }

    private var videoSection: some View {
        Section {
            NavigationLink {
                RecordingsView(onOpen: { url in
                    pipeline.openVideo(url: url)
                    dismiss()
                })
                .environmentObject(pipeline)
            } label: {
                Label(String(format: L("本 App 的录像（%d）"), recordingCount), systemImage: "film.stack")
            }
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                Label(loadingVideo ? L("正在载入…") : L("从相册导入视频分析"), systemImage: "photo.on.rectangle")
            }
            Button { showImporter = true } label: {
                Label(L("从“文件”导入视频分析"), systemImage: "folder")
            }
            Picker(L("回放速度"), selection: $pipeline.playbackSpeed) {
                Text("0.1×").tag(0.1)
                Text("0.25×").tag(0.25)
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text(L("最快")).tag(0.0)
            }
        } header: {
            Text(L("视频分析"))
        } footer: {
            Text(String(format: L("导入的视频走与实时相机完全相同的检测流程：默认用开头 %.1f 秒作基线；也可以拖动进度条或曲线到任意位置后点 BASELINE，从那里重新取基线。"),
                        pipeline.params.baselineSeconds))
        }
    }

    private var recordingSection: some View {
        Section {
            Picker(selection: Binding(get: { camera.resolution }, set: { camera.setResolution($0) })) {
                ForEach(camera.supportedResolutions) { r in Text(r.label).tag(r) }
            } label: { HelpLabel(L("分辨率"), .resolution) }
            .disabled(pipeline.isRecording)
            Picker(selection: Binding(get: { camera.frameRate }, set: { camera.setFrameRate($0) })) {
                ForEach(camera.supportedFrameRates, id: \.self) { f in Text("\(Int(f)) fps").tag(f) }
            } label: { HelpLabel(L("帧率"), .fps) }
            .disabled(pipeline.isRecording)
            Picker(selection: $pipeline.recordSettings.codec) {
                ForEach(VideoCodec.allCases) { c in Text(c.label).tag(c) }
            } label: { HelpLabel(L("编码"), .codec) }
            .disabled(pipeline.isRecording)
            Picker(selection: $pipeline.recordSettings.bitrateMbps) {
                ForEach(RecordSettings.bitratePresets, id: \.self) { b in Text("\(Int(b)) Mb/s").tag(b) }
            } label: { HelpLabel(L("比特率"), .bitrate) }
            .disabled(pipeline.isRecording)
            Toggle(L("录完存入相册"), isOn: $pipeline.recordSettings.saveToPhotos)
            Toggle(L("同时写 CSV 分析日志"), isOn: $pipeline.recordSettings.writeCSV)
            Toggle(L("录制声音（麦克风）"), isOn: $pipeline.recordSettings.recordAudio)
        } header: {
            Text(L("录制"))
        } footer: {
            Text(L("录像 (.mov)、设置 (.json)、日志 (.csv) 和结果图 (.png) 保存在“文件”App → 我的 iPhone → GasCam。CSV 里每个分析框单独成列。防抖和 HDR 已关闭，以免改变像素值。"))
        }
    }

    private var cameraSection: some View {
        Section {
            Picker(selection: $camera.mainsHz) {
                Text(L("60 Hz（九州・关西）")).tag(60.0)
                Text(L("50 Hz（关东・东北）")).tag(50.0)
            } label: { HelpLabel(L("电网频率（灯光频闪）"), .mains) }
            Picker(selection: $camera.autoISOCap) {
                ForEach([Float(200), 400, 800, 1600, 3200], id: \.self) { v in Text("\(Int(v))").tag(v) }
            } label: { HelpLabel(L("AUTO 最高 ISO"), .autoISOCap) }
            ValueSlider(label: L("AUTO 闪光灯上限"), value: $camera.autoTorchLimit, range: 0.1...1, help: .autoTorchLimit) {
                "\(Int(($0 * 100).rounded()))%"
            }
        } header: {
            Text(L("相机 AUTO / LOCK"))
        } footer: {
            Text(L("AUTO：快门固定为不超过 1/帧率的最长防频闪值；框内最亮的 2% 像素调到约 85%（不过曝）。暗了先加闪光灯，开满还不够再升 ISO（不超过上面的上限）；亮了先降 ISO，再降闪光灯，最后才缩短快门。点画面只用于对焦。按 LOCK 全部固定并显示最终参数。最高 ISO 只限制 AUTO，手动仍可设到手机的最高值。"))
        }
    }

    private var assistSection: some View {
        Section(L("辅助显示")) {
            Toggle(L("直方图"), isOn: $pipeline.display.showHistogram)
            Toggle(L("假色 False Color"), isOn: $pipeline.display.falseColor)
            Toggle(L("斑马纹 Zebra"), isOn: $pipeline.display.zebra)
            ValueSlider(label: L("斑马阈值"), value: $pipeline.display.zebraLevel, range: 0.70...1.0, help: .zebraLevel) { "\(Int(($0 * 100).rounded()))%" }
            Toggle(L("峰值对焦 Peaking"), isOn: $pipeline.display.peaking)
            ValueSlider(label: L("峰值灵敏"), value: $pipeline.display.peakingThreshold, range: 0.05...0.6, help: .peaking) { String(format: "%.2f", $0) }
            Toggle(L("三分线"), isOn: $pipeline.display.grid)
            Toggle(L("中心十字"), isOn: $pipeline.display.crosshair)
            Toggle(L("水平仪（镜头朝下）"), isOn: $pipeline.display.level)
            Toggle(L("显示气源箭头"), isOn: $pipeline.display.showArrow)
            Toggle(L("气体消失后保留上一次的箭头（虚线）"), isOn: $pipeline.display.keepLastResult)
            Toggle(L("显示最大响应点（十字）"), isOn: $pipeline.display.showHotspot)
            Toggle(L("显示变化曲线"), isOn: $pipeline.display.showChart)
            Toggle(L("显示色标条"), isOn: $pipeline.display.showColorBar)
            Toggle(isOn: $pipeline.display.blackBackground) { HelpLabel(L("黑底显示"), .blackBackground) }
            Toggle(L("显示实验步骤"), isOn: $pipeline.display.showSteps)
            Toggle(L("声源显示（麦克风电平表）"), isOn: $pipeline.display.showAudioMeter)
            ValueSlider(label: L("叠加透明"), value: $pipeline.display.overlayOpacity, range: 0.1...1.0, help: .overlayOpacity) { String(format: "%.2f", $0) }
        }
    }

    private var detectionSection: some View {
        Section {
            Picker(selection: $pipeline.params.channel) {
                ForEach(SignalChannel.allCases) { c in Text(L(c.label)).tag(c) }
            } label: { HelpLabel(L("信号通道"), .channel) }
            Picker(selection: $pipeline.params.polarity) {
                ForEach(ResponsePolarity.allCases) { p in Text(L(p.label)).tag(p) }
            } label: { HelpLabel(L("响应方向"), .polarity) }
            ValueSlider(label: L("最小阈值"), value: $pipeline.params.minPercent, range: 0.2...10, help: .threshold) { String(format: "%.1f%%", $0) }
            ValueSlider(label: "k·σ", value: $pipeline.params.kSigma, range: 1...10, help: .kSigma) { String(format: "%.1f", $0) }
            Toggle(isOn: $pipeline.params.autoScale) { HelpLabel(L("自动色标"), .autoScale) }
            if !pipeline.params.autoScale {
                ValueSlider(label: L("色标上限"), value: $pipeline.params.displayMaxPercent, range: 1...40, help: .displayMax) { String(format: "%.0f%%", $0) }
            }
            ValueSlider(label: L("到达色标"), value: $pipeline.params.arrivalSpan, range: 0.1...10, help: .arrivalSpan) { String(format: "%.1fs", $0) }
            ValueSlider(label: L("区域到达"), value: $pipeline.params.regionArrivalFraction, range: 0.01...0.8, help: .regionArrival) {
                String(format: "%.0f%%", $0 * 100)
            }
            Toggle(isOn: $pipeline.params.useReference) { HelpLabel(L("参考框校正"), .useReference) }
                .disabled(pipeline.regions.reference == nil)
            Toggle(isOn: $pipeline.params.lockCameraOnBaseline) { HelpLabel(L("取基线时锁定 AE/AWB/AF"), .lockOnBaseline) }
        } header: {
            Text(L("气体检测"))
        } footer: {
            Text(L("响应 = 100·(S−S₀)/S₀；像素超过 max(最小阈值, k·基线噪声) 即视为有气体。自动色标：实时画面缓慢跟随（有下限，不会忽大忽小），视频整段用同一个色标。区域到达：框内这个比例的像素到达即算该区域到达。参考框校正：用参考框（白纸/灰卡）的亮度变化抵消灯光和曝光的整体变化，需要先在 ROI 里画参考框。"))
        }
    }

    private var advancedSection: some View {
        Section {
            Stepper(value: $pipeline.params.blurRadius, in: 0...8) {
                HelpLabel(String(format: L("空间平滑半径: %d"), pipeline.params.blurRadius), .blur)
            }
            ValueSlider(label: L("基线时长"), value: $pipeline.params.baselineSeconds, range: 0.2...10, help: .baselineSeconds) { String(format: "%.1f s", $0) }
            Stepper(value: $pipeline.params.confirmFrames, in: 1...10) {
                HelpLabel(String(format: L("确认帧数: %d"), pipeline.params.confirmFrames), .confirmFrames)
            }
            ValueSlider(label: L("时间平滑"), value: $pipeline.params.emaAlpha, range: 0.05...1, help: .ema) { String(format: "α %.2f", $0) }
            Picker(selection: $pipeline.params.analysisRate) {
                Text("15 Hz").tag(15.0)
                Text("30 Hz").tag(30.0)
                Text("60 Hz").tag(60.0)
                Text(L("每帧")).tag(1000.0)
            } label: { HelpLabel(L("分析频率"), .analysisRate) }
            ValueSlider(label: L("方向置信"), value: $pipeline.params.directionConfMin, range: 0.05...0.8, help: .directionConf) { String(format: "%.2f", $0) }
            ValueSlider(label: L("最少到达"), value: $pipeline.params.minArrivedFraction, range: 0.001...0.1, help: .minArrived) { String(format: "%.1f%%", $0 * 100) }
            Picker(selection: $pipeline.params.autoRearmSeconds) {
                Text(L("关闭")).tag(0.0)
                Text(L("气体消失 3 s 后")).tag(3.0)
                Text(L("气体消失 5 s 后")).tag(5.0)
                Text(L("气体消失 10 s 后")).tag(10.0)
            } label: { HelpLabel(L("自动重置"), .autoRearm) }
            Toggle(isOn: $pipeline.params.baselineTracking) { HelpLabel(L("基线漂移跟踪（慢速）"), .baselineTracking) }
            Button(L("恢复检测默认值")) { pipeline.params = GasParams() }
            Button(L("清除所有分析框")) { pipeline.regions = AnalysisRegions() }
        } header: {
            Text(L("检测（高级）"))
        } footer: {
            Text(L("箭头：E = 最早被气体到达的 5% 像素的重心，C = 所有已到达像素的重心，方向 C→E 延长到分析框外边缘（红色 ×）即气体进入基板的位置。置信度 = |E−C| / 羽流半径；低于阈值时认为气体从基板正上方扩散（显示同心圆）。多个框时按所有框合起来计算。"))
        }
    }

    private var crashSection: some View {
        Section {
            if crashLogs.isEmpty {
                Text(L("没有崩溃记录")).foregroundStyle(.gray)
            }
            ForEach(crashLogs, id: \.self) { url in
                ShareLink(item: url) {
                    Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                        .font(Theme.mono(12))
                }
            }
            if !crashLogs.isEmpty {
                Button(L("清除崩溃记录"), role: .destructive) {
                    CrashReporter.clear()
                    crashLogs = CrashReporter.list()
                }
            }
        } header: {
            Text(String(format: L("崩溃记录（%d）"), crashLogs.count))
        } footer: {
            Text(L("闪退后再次打开 App，这里会出现记录（iOS 的崩溃报告有时要晚一些才送来）。点一下即可分享（AirDrop / 存到“文件”），发给开发者定位问题。"))
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section(L("本机能力（当前镜头）")) {
            LabeledContent(L("机型代号"), value: CameraController.modelIdentifier)
            ForEach(camera.capabilities, id: \.self) { line in
                Text(line).font(Theme.mono(12))
            }
            Text(L("FPS 菜单里只会列出这台手机硬件支持的组合。码率是否真正达到，以录制结束时提示的“实际码率 / 实际帧率 / 丢帧”为准。"))
                .font(.footnote).foregroundStyle(.gray)
        }
        Section(L("关于")) {
            LabeledContent(L("版本"), value: CrashReporter.appVersion)
            LabeledContent(L("分析网格"), value: L("长边 256 px"))
            Text(L("参考实现：tools/gas_reference.py（与 App 算法逐步一致，可在电脑上复现 App 的结果）。"))
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
            pipeline.toast = L("导入失败") + ": \(error.localizedDescription)"
        }
    }
}

/// Recordings made by the app: first-frame thumbnail + name; tap to analyse, rename, delete.
struct RecordingsView: View {
    @EnvironmentObject var pipeline: FramePipeline
    let onOpen: (URL) -> Void
    @State private var items: [RecordingStore.Item] = []
    @State private var renaming: RecordingStore.Item?
    @State private var newName = ""
    @State private var busy = false
    @State private var message: String?
    @State private var selecting = false
    @State private var selection = Set<URL>()
    @State private var pendingDelete: [RecordingStore.Item] = []
    @State private var showDeleteDialog = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        List {
            if items.isEmpty {
                Text(L("还没有录像")).foregroundStyle(.gray)
            }
            ForEach(items) { item in
                row(item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            askDelete([item])
                        } label: {
                            Label(L("删除"), systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle(L("本 App 的录像"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button(selecting ? L("取消") : L("选择")) {
                        selecting.toggle()
                        selection = []
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if selecting {
                    Button(role: .destructive) {
                        askDelete(items.filter { selection.contains($0.url) })
                    } label: {
                        Text(String(format: L("删除（%d）"), selection.count)).foregroundStyle(selection.isEmpty ? Color.gray : Color.red)
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .overlay {
            if busy { ProgressView().padding(20).background(Color.black.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 10)) }
        }
        .onAppear { items = RecordingStore.list() }
        .alert(L("改名"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("新名字"), text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L("取消"), role: .cancel) { renaming = nil }
            Button(L("改名")) { if let it = renaming { rename(it) } }
        } message: {
            Text(L(".mov / .json / .csv 一起改名；相册里的副本会另存新名字，再删除旧的（iOS 会请你确认）。"))
        }
        .confirmationDialog(String(format: L("删除 %d 段录像？"), pendingDelete.count),
                            isPresented: $showDeleteDialog, titleVisibility: .visible) {
            Button(L("只删 App 里的"), role: .destructive) { delete(includePhotos: false) }
            Button(L("同时删相册里的那份"), role: .destructive) { delete(includePhotos: true) }
            Button(L("取消"), role: .cancel) { pendingDelete = [] }
        } message: {
            Text(L(".mov / .json / .csv 会一起删除，无法恢复。删除相册里的那份时 iOS 会再确认一次。"))
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        }
    }

    private func row(_ item: RecordingStore.Item) -> some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selection.contains(item.url) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selection.contains(item.url) ? Theme.accent : Color.gray)
            }
            RecordingThumb(url: item.url)
                .frame(width: 54, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(Theme.mono(13, .semibold)).lineLimit(2)
                Text(Self.dateFormatter.string(from: item.date)).font(Theme.mono(11)).foregroundStyle(.gray)
            }
            Spacer(minLength: 4)
            if !selecting {
                Button {
                    newName = item.name
                    renaming = item
                } label: {
                    Image(systemName: "pencil").font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
            } else {
                onOpen(item.url)
            }
        }
    }

    private func askDelete(_ list: [RecordingStore.Item]) {
        guard !list.isEmpty else { return }
        pendingDelete = list
        showDeleteDialog = true
    }

    private func delete(includePhotos: Bool) {
        let list = pendingDelete
        pendingDelete = []
        // a video that is being analysed is closed first
        if case .file(let name) = pipeline.source, list.contains(where: { $0.url.lastPathComponent == name }) {
            pipeline.closeVideo()
        }
        busy = includePhotos
        RecordingStore.delete(list, includePhotos: includePhotos) { msg in
            busy = false
            items = RecordingStore.list()
            selection = []
            selecting = false
            message = msg
        }
    }

    private func rename(_ item: RecordingStore.Item) {
        renaming = nil
        do {
            let url = try RecordingStore.renameFiles(item, to: newName)
            items = RecordingStore.list()
            guard url != item.url else { return }
            busy = true
            RecordingStore.renamePhotosCopy(oldFileName: item.url.lastPathComponent, newURL: url) { msg in
                busy = false
                message = msg
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct RecordingThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.gray)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { image = await RecordingStore.thumbnail(url) }
    }
}
