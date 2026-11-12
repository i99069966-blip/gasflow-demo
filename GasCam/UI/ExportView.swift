import SwiftUI

/// Video analysis → export: choose the files, run the export (progress / cancel), then share them.
struct ExportSheet: View {
    @EnvironmentObject var pipeline: FramePipeline
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()

    var body: some View {
        NavigationStack {
            Form {
                if let p = pipeline.exportProgress {
                    progressSection(p)
                } else if let o = pipeline.exportOutcome {
                    outcomeSection(o)
                } else {
                    optionSections
                }
            }
            .navigationTitle(L("导出分析结果"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }.disabled(pipeline.exportProgress != nil)
                }
            }
        }
        .interactiveDismissDisabled(pipeline.exportProgress != nil)
        .onAppear {
            if pipeline.exportProgress == nil { pipeline.exportOutcome = nil }
            options.regions = Set(0..<pipeline.regions.regionCount)
        }
    }

    // MARK: Options

    @ViewBuilder private var optionSections: some View {
        let b0 = pipeline.exportBaselineStart
        Section {
            if let b0 {
                Text(String(format: L("从头到尾把整段视频重新分析一遍（用现在的设置，基线从 %.2f s 开始），生成下面勾选的文件。手机会忙一会儿，视频越长越久。"), b0))
                    .font(.footnote)
            } else {
                Label(L("请先取基线：拖到通气前的位置，按 BASELINE"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        Section {
            Toggle(isOn: $options.video) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("分析视频（.mov）"))
                    Text(String(format: L("画面 + %@ 叠加层 + 区域 + 箭头；最大 1080p，H.264"), pipeline.display.overlay.label))
                        .font(.caption).foregroundStyle(.gray)
                }
            }
            Toggle(isOn: $options.csv) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("区域数据（CSV）"))
                    Text(L("每帧一行：时间、R/G/B、当前通道、ΔS/S %、到达比例；选中的区域放在同一个文件里"))
                        .font(.caption).foregroundStyle(.gray)
                }
            }
            if options.csv { regionPicker }
            Toggle(isOn: $options.arrivalMap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("到达时间图（CSV + PNG）"))
                    Text(L("每个格子的到达时间（144×256），可以直接用来画论文图"))
                        .font(.caption).foregroundStyle(.gray)
                }
            }
            Toggle(L("结果图（PNG）"), isOn: $options.resultImage)
        } header: {
            Text(L("导出内容"))
        }
        Section {
            Button {
                pipeline.startExport(options)
            } label: {
                Label(L("开始导出"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .disabled(b0 == nil || options.isEmpty || (options.csv && options.regions.isEmpty))
        } footer: {
            Text(CloudSync.isConfigured && CloudSync.afterExport
                 ? String(format: L("完成后保存在“文件”App → 我的 iPhone → GasCam → Exports，并自动复制到同步文件夹“%@”。"), CloudSync.folderName ?? "")
                 : L("完成后保存在“文件”App → 我的 iPhone → GasCam → Exports，也可以直接分享（AirDrop、存到网盘等）。"))
        }
    }

    private var regionPicker: some View {
        let n = pipeline.regions.regionCount
        let whole = pipeline.regions.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("CSV 里放哪些区域")).font(.caption).foregroundStyle(.gray)
            if whole {
                Text(L("没有画框：整个画面作为一个区域")).font(.caption)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(0..<n, id: \.self) { k in
                        let on = options.regions.contains(k)
                        Button {
                            if on { options.regions.remove(k) } else { options.regions.insert(k) }
                        } label: {
                            Text("\(k + 1)")
                                .font(Theme.mono(13, .bold))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .foregroundStyle(on ? Color.black : AnalysisRegions.swiftColor(k))
                                .background(on ? AnalysisRegions.swiftColor(k) : Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AnalysisRegions.swiftColor(k), lineWidth: 1.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button(L("全选")) { options.regions = Set(0..<n) }
                    Spacer()
                    Button(L("全不选")) { options.regions = [] }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Running / done

    private func progressSection(_ p: Double) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("正在导出…")).font(.headline)
                ProgressView(value: p)
                Text("\(Int((p * 100).rounded()))%").font(Theme.mono(12)).foregroundStyle(.gray)
                Text(L("请不要切换到别的 App，屏幕会保持常亮。")).font(.caption).foregroundStyle(.gray)
            }
            Button(L("取消导出"), role: .destructive) { pipeline.cancelExport() }
        }
    }

    @ViewBuilder private func outcomeSection(_ o: ExportOutcome) -> some View {
        if let e = o.error {
            Section {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(L("返回")) { pipeline.exportOutcome = nil }
            }
        } else {
            Section {
                ForEach(o.files, id: \.self) { f in
                    Label(f.lastPathComponent, systemImage: Self.icon(f)).font(Theme.mono(12))
                }
            } header: {
                Text(String(format: L("已导出 %d 个文件"), o.files.count))
            } footer: {
                Text(String(format: L("保存在“文件”App → 我的 iPhone → GasCam → Exports → %@"), o.folder?.lastPathComponent ?? ""))
            }
            Section {
                ShareLink(items: o.files) {
                    Label(L("分享 / 存到其他地方…"), systemImage: "square.and.arrow.up")
                }
                if let c = o.cloud {
                    Label(c, systemImage: "icloud.and.arrow.up").font(.footnote)
                } else if CloudSync.isConfigured {
                    Button {
                        if let folder = o.folder {
                            pipeline.exportOutcome?.cloud = L("正在复制到同步文件夹…")
                            CloudSync.copy([folder]) { msg in pipeline.exportOutcome?.cloud = msg }
                        }
                    } label: {
                        Label(String(format: L("复制到同步文件夹“%@”"), CloudSync.folderName ?? ""), systemImage: "icloud.and.arrow.up")
                    }
                }
                Button(L("再导出一次")) { pipeline.exportOutcome = nil }
            }
        }
    }

    private static func icon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4": return "film"
        case "csv": return "tablecells"
        case "png": return "photo"
        default: return "doc"
        }
    }
}
