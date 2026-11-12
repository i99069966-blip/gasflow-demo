import SwiftUI

/// Short explanation of a setting: what it does, what a larger value does, and what to use.
enum HelpTopic: String, CaseIterable {
    case ev, iso, shutter, wb, focus, torch, fps, resolution, bitrate, codec, mains
    case autoISOCap
    case channel, polarity, threshold, kSigma, confirmFrames, minArrived, blur, ema, analysisRate
    case directionConf, autoRearm, baselineTracking, baselineSeconds, arrivalSpan, regionArrival
    case useReference, autoScale, displayMax, flowLag, flowScale, overlayOpacity, blackBackground
    case lockOnBaseline, zebraLevel, peaking
    case arrivalMode

    var title: String {
        switch self {
        case .ev: return L("EV 曝光补偿")
        case .iso: return "ISO"
        case .shutter: return L("快门")
        case .wb: return L("白平衡")
        case .focus: return L("对焦")
        case .torch: return L("闪光灯")
        case .fps: return L("帧率")
        case .resolution: return L("分辨率")
        case .bitrate: return L("比特率")
        case .codec: return L("编码")
        case .mains: return L("电网频率（灯光频闪）")
        case .autoISOCap: return L("AUTO 最高 ISO")
        case .channel: return L("信号通道")
        case .polarity: return L("响应方向")
        case .threshold: return L("检测阈值")
        case .kSigma: return "k·σ"
        case .confirmFrames: return L("确认帧数")
        case .minArrived: return L("最少到达")
        case .blur: return L("空间平滑半径")
        case .ema: return L("时间平滑")
        case .analysisRate: return L("分析频率")
        case .directionConf: return L("方向置信")
        case .autoRearm: return L("自动重置")
        case .baselineTracking: return L("基线漂移跟踪（慢速）")
        case .baselineSeconds: return L("基线时长")
        case .arrivalSpan: return L("到达色标")
        case .regionArrival: return L("区域到达")
        case .useReference: return L("参考框校正")
        case .autoScale: return L("自动色标")
        case .displayMax: return L("色标上限")
        case .flowLag: return L("帧差间隔")
        case .flowScale: return L("帧差色标")
        case .overlayOpacity: return L("叠加透明")
        case .blackBackground: return L("黑底显示")
        case .lockOnBaseline: return L("取基线时锁定 AE/AWB/AF")
        case .zebraLevel: return L("斑马阈值")
        case .peaking: return L("峰值灵敏")
        case .arrivalMode: return L("到达判定")
        }
    }

    /// (what it does, what a larger value / turning it on does, recommendation)
    var lines: (String, String, String) {
        switch self {
        case .ev: return (L("改变 AUTO 的目标亮度（默认：最亮的 2% 像素约 85%）。"),
                          L("+ 更亮，− 更暗；+1 = 光量 ×2。"),
                          L("一般用 0。AUTO 调出来偏暗或偏亮时用 ±0.3。按 LOCK 后不起作用。"))
        case .iso: return (L("把信号放大，让画面变亮。"),
                           L("越高越亮，但噪声也一起放大。"),
                           L("越低越好，交给 AUTO（最高 800）。"))
        case .shutter: return (L("每一帧收集光的时间。"),
                               L("越长越亮、噪声越小；最长 = 1/帧率。"),
                               L("用绿色（防频闪）的值：30 fps 用 1/30 或 1/60，60 fps 用 1/60，120 fps 用 1/120。"))
        case .wb: return (L("告诉相机什么是白色，决定 R/G/B 的比例。"),
                          L("色温越高画面越偏暖（黄），越低越偏冷（蓝）。"),
                          L("实验时一定要固定（按 LOCK 或“灰卡/场景”）。同一组实验用同一个值。"))
        case .focus: return (L("让基板清楚。"),
                             L("0 = 最近，1 = 最远。"),
                             L("点基板自动对焦，按 LOCK 固定。看不清时手动对焦并打开 PEAK。"))
        case .torch: return (L("照亮基板的光源。用电池供电，本身不闪。"),
                             L("越亮噪声越小，但手机会发热。"),
                             L("手动设一个够亮的值，整个实验保持不变（AUTO 不会动它）。长时间实验手机发热时，系统可能自动调暗闪光灯，基线会漂移。"))
        case .fps: return (L("每秒拍多少帧。"),
                           L("越高时间越精细，但每帧的光更少、文件更大。"),
                           L("一般 30–60 fps；气体来得很快时 120 fps。"))
        case .resolution: return (L("录像的像素数。"),
                                  L("分析网格固定为 144×256，分辨率主要影响录像。"),
                                  L("1080p 或 720p。4K 负担重，容易丢帧。"))
        case .bitrate: return (L("录像每秒用多少数据。"),
                               L("越高，压缩损失越小，文件越大。"),
                               L("1080p30 或 720p60 用 50 Mb/s 就够。再高只是文件更大，还更容易丢帧。"))
        case .codec: return (L("录像的压缩方式。"),
                             L("H.264 兼容性好；HEVC 同样画质文件更小。"),
                             L("都可以；在电脑上分析时 H.264 更省事。"))
        case .mains: return (L("房间灯每秒亮暗（2 × 电网频率）次。"),
                             L("决定哪些快门不会闪（绿色的值）。"),
                             L("九州、关西 60 Hz；关东、东北 50 Hz。"))
        case .autoISOCap: return (L("AUTO 最多把 ISO 升到这里。手动不受限制。"),
                                  L("高：暗处也能调亮，但噪声大；低：噪声小，但更容易“光线不足”。"),
                                  L("800；闪光灯够亮时可以设 400。"))
        case .channel: return (L("用哪个颜色的变化来检测气体。"),
                               L("—"),
                               L("选变化最大、噪声最小的通道。视频分析后 App 会推荐。你的基板是 R；灯光不稳又没有参考框时用 R/B（色比，不受亮度变化影响）。"))
        case .polarity: return (L("气体让信号变小还是变大。"),
                                L("—"),
                                L("你的基板 R 下降 → 选“下降”。不确定时选“双向”。"))
        case .threshold: return (L("像素的变化超过这个比例才算有气体。"),
                                 L("高：不容易误报，但弱的气体检测不到。"),
                                 L("设成预期最大响应的约 1/3。噪声偏大时 App 会建议调高。默认 2%。"))
        case .kSigma: return (L("变化还要超过这个像素噪声的 k 倍。"),
                              L("高：误报更少。"),
                              L("4；噪声大时 5–6。"))
        case .confirmFrames: return (L("连续几帧超过阈值才算到达。"),
                                     L("高：误报更少，但到达时间稍晚。"),
                                     L("2–3。"))
        case .minArrived: return (L("至少多少比例的像素到达，才算检测到气体、才画箭头。"),
                                  L("高：零散的噪声小点不会误报。"),
                                  L("1%；没通气也误报时 2–3%；气体范围很小时 0.3%。"))
        case .blur: return (L("每个像素和周围的像素平均。"),
                            L("大：噪点少，但图更模糊。"),
                            L("2；热图上有零散小斑点时 3；气体范围很小时 1。"))
        case .ema: return (L("和前几帧平均（α = 1 不平滑）。"),
                           L("α 越小越平滑，但反应和到达时间更慢。"),
                           L("0.5；噪声大时 0.3。"))
        case .analysisRate: return (L("每秒计算多少次。"),
                                    L("高：到达时间更精细，但手机更热。"),
                                    L("30 Hz；气体来得很快时 60 Hz。"))
        case .directionConf: return (L("方向不够明确时不画箭头，改为显示同心圆（“正上方”）。"),
                                     L("高：箭头更少、更可靠。"),
                                     L("0.25；箭头来回乱跳时 0.35。"))
        case .autoRearm: return (L("气体消失多久后清空到达图，等下一次通气。"),
                                 L("—"),
                                 L("多次通气用 5 s；只通一次、想保留结果选“关闭”。"))
        case .baselineTracking: return (L("没有气体的地方，基线慢慢跟着光线变化走。"),
                                        L("打开：抵消很慢的漂移，但来得很慢的气体可能被当成漂移。"),
                                        L("平时关着；没画参考框的长时间实验可以打开。"))
        case .baselineSeconds: return (L("通气前取多少秒的画面，作为“没有气体”的参考。"),
                                       L("长：噪声估计更准。"),
                                       L("1–3 s，必须在通气之前取完。"))
        case .arrivalSpan: return (L("ARRIVAL 图里，红 = 最早到达，蓝 = 晚这么多秒。"),
                                   L("—"),
                                   L("设成气体铺满基板大约需要的时间。"))
        case .regionArrival: return (L("框内多少比例的像素到达，才算这个区域到达。"),
                                     L("高：区域的到达时间更晚。"),
                                     L("10%。"))
        case .useReference: return (L("用参考框（白纸/灰卡）的亮度变化，抵消灯光和曝光的整体变化。"),
                                    L("—"),
                                    L("光线可能变化或实验时间长时打开。需要先在 ROI 里画参考框。"))
        case .autoScale: return (L("热图的颜色范围跟着数据走。"),
                                 L("关掉：用“色标上限”固定。"),
                                 L("一般打开；要比较不同实验时关掉，并用同一个上限。"))
        case .displayMax: return (L("热图满红对应的变化量。"),
                                  L("—"),
                                  L("接近最大响应（你的基板约 6–8%）。"))
        case .flowLag: return (L("FLOW 用“现在”和多少秒之前比较。"),
                               L("大：信号强，但前沿模糊；小：前沿清楚，但噪声大。"),
                               L("0.1–0.5 s，默认 0.2 s。"))
        case .flowScale: return (L("FLOW 满红 / 满蓝对应的变化量。"),
                                 L("—"),
                                 L("FLOW 颜色太淡就调小，大片满红就调大。"))
        case .overlayOpacity: return (L("热图盖在画面上的不透明度。"),
                                      L("高：颜色更实，下面的画面更看不清。"),
                                      L("0.75。"))
        case .blackBackground: return (L("HEAT / FLOW / ARRIVAL 时背景变黑，只显示气体响应。"),
                                       L("—"),
                                       L("演示和截图时打开；调相机、画框时关掉。"))
        case .lockOnBaseline: return (L("按 BASELINE 时，如果相机还没锁定，就自动锁定。"),
                                      L("—"),
                                      L("保持打开。"))
        case .zebraLevel: return (L("亮度超过这个值的地方显示斜纹。"),
                                  L("—"),
                                  L("95%：基板和参考框上不要有斜纹。"))
        case .peaking: return (L("边缘多清楚才描红。"),
                               L("低：描红的地方更多。"),
                               L("0.2 左右。"))
        case .arrivalMode: return (L("怎样决定每个像素的“到达时刻”。"),
                                   L("—"),
                                   L("固定阈值：响应超过检测阈值的时刻；响应弱的地方会显得晚。自适应：超过“自己最大响应的一半”的时刻（不高于检测阈值），弱的地方不再显得晚，到达图更完整，但要等气体基本到齐才稳定。可以随时切换比较。"))
        }
    }

    var message: String {
        let (a, b, c) = lines
        var parts = [L("作用") + "：" + a]
        if b != "—" { parts.append(L("调大会怎样") + "：" + b) }
        parts.append(L("建议") + "：" + c)
        return parts.joined(separator: "\n\n")
    }
}

/// Small ⓘ button that explains a setting.
struct InfoButton: View {
    let topic: HelpTopic
    @State private var shown = false

    init(_ topic: HelpTopic) { self.topic = topic }

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.gray)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(topic.title)
        .alert(topic.title, isPresented: $shown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(topic.message)
        }
    }
}

/// Label + ⓘ for Form rows.
struct HelpLabel: View {
    let text: String
    let topic: HelpTopic
    init(_ text: String, _ topic: HelpTopic) { self.text = text; self.topic = topic }
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            InfoButton(topic)
        }
    }
}

// MARK: - Assist legends

/// Legend of the false-colour bands (matches PreviewRenderer.falseColor).
struct FalseColorLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            item(Color(red: 0.55, green: 0, blue: 0.75), L("过暗") + " <10%")
            item(Color(white: 0.55), L("中间"))
            item(Color(red: 0.15, green: 0.8, blue: 0.3), L("合适") + " 60–90%")
            item(Color(red: 1, green: 0.9, blue: 0), L("快过曝"))
            item(.red, L("过曝") + " ≥97%")
        }
        .font(Theme.mono(9, .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 9, height: 9)
            Text(t)
        }
    }
}

/// One-line hint shown while zebra / peaking are on.
struct AssistHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.mono(9, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.6))
            .clipShape(Capsule())
    }
}

/// Experiment steps (camera mode): ① box ② AUTO ③ LOCK ④ BASELINE ⑤ gas.
struct StepGuide: View {
    @EnvironmentObject var pipeline: FramePipeline
    @EnvironmentObject var camera: CameraController

    var body: some View {
        let r = pipeline.result
        let baselineDone: Bool = {
            switch r.phase {
            case .monitoring, .detected: return true
            default: return false
            }
        }()
        let inBaseline: Bool = { if case .baseline = r.phase { return true } else { return false } }()
        let locked = camera.isFullyLocked
        let steps: [(String, Bool)] = [
            (L("画框"), !pipeline.regions.isEmpty),
            ("AUTO", camera.exposureAuto || locked),
            ("LOCK", locked),
            ("BASELINE", baselineDone),
            (L("通气"), r.phase == .detected),
        ]
        let current = steps.firstIndex { !$0.1 }
        HStack(spacing: 3) {
            ForEach(steps.indices, id: \.self) { i in
                let (name, done) = steps[i]
                let isCurrent = i == current
                HStack(spacing: 2) {
                    Text(done ? "✓" : "\(i + 1)")
                    Text(name)
                }
                .font(Theme.mono(9, isCurrent ? .bold : .semibold))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(isCurrent ? Theme.accent : (done ? Color.green.opacity(0.35) : Color.black.opacity(0.55)))
                .foregroundStyle(isCurrent ? Color.black : .white)
                .clipShape(Capsule())
                .overlay {
                    if isCurrent && i == 3 && inBaseline {
                        Capsule().stroke(Color.white, lineWidth: 1)
                    }
                }
            }
        }
    }
}
