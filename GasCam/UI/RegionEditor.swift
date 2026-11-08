import SwiftUI

/// Shared between the editing overlay on the preview and the region panel.
final class RegionEditState: ObservableObject {
    enum Target { case region, reference }
    enum Selection: Equatable { case region(Int), reference, grid }
    /// What a drag on empty space draws.
    @Published var target: Target = .region
    /// A finger is drawing / moving on the picture (the toolbar fades out).
    @Published var dragging = false
    @Published var selection: Selection?
}

extension AnalysisRegions {
    static func swiftColor(_ i: Int) -> Color {
        let c = color(i)
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    func rect(_ s: RegionEditState.Selection) -> NormRect? {
        switch s {
        case .region(let k): return mode == .free && k < rects.count ? rects[k] : nil
        case .reference: return reference
        case .grid: return mode == .grid ? gridArea : nil
        }
    }

    mutating func set(_ s: RegionEditState.Selection, _ r: NormRect) {
        switch s {
        case .region(let k): if k < rects.count { rects[k] = r }
        case .reference: reference = r
        case .grid: gridArea = r
        }
    }

    mutating func remove(_ s: RegionEditState.Selection) {
        switch s {
        case .region(let k): if k < rects.count { rects.remove(at: k) }
        case .reference: reference = nil
        case .grid: gridArea = nil
        }
    }
}

/// Order in which the regions were reached: region index → 1-based rank.
func regionArrivalRanks(_ stats: [RegionStat]) -> [Int: Int] {
    let arrived = stats.enumerated().compactMap { k, s in s.arrivalTime.map { (k, $0) } }
        .sorted { $0.1 < $1.1 }
    var out: [Int: Int] = [:]
    for (rank, item) in arrived.enumerated() { out[item.0] = rank + 1 }
    return out
}

/// Regions drawn on the preview; when `editing`, also the touch handling to draw, move and resize.
struct RegionOverlay: View {
    @EnvironmentObject var pipeline: FramePipeline
    @EnvironmentObject var edit: RegionEditState
    let size: CGSize
    let editing: Bool

    private enum Action {
        case draw
        case move(RegionEditState.Selection, NormRect)
        case resize(RegionEditState.Selection, Int, NormRect)
    }
    @State private var action: Action?
    @State private var draft: NormRect?

    var body: some View {
        let regs = pipeline.regions
        let ranks = regionArrivalRanks(pipeline.result.regions)
        ZStack {
            if editing {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged(changed)
                        .onEnded(ended))
            }
            // grid area outline
            if regs.mode == .grid, let a = shown(.grid, regs.gridArea) {
                Path(cg(a)).stroke(Color.white.opacity(editing ? 0.9 : 0.5), lineWidth: editing ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            // regions
            let list = liveList(regs)
            ForEach(list.indices, id: \.self) { k in
                let r = cg(list[k])
                let color = AnalysisRegions.swiftColor(k)
                let selected = editing && edit.selection == .region(k)
                Path(r).stroke(color, lineWidth: selected ? 2.5 : (editing ? 1.5 : 1.2))
                    .allowsHitTesting(false)
                label(k, rank: ranks[k], color: color)
                    .position(x: r.minX + 13, y: r.minY + 10)
                    .allowsHitTesting(false)
            }
            // reference box
            if let ref = shown(.reference, regs.reference) {
                let r = cg(ref)
                Path(r).stroke(Color.white, style: StrokeStyle(lineWidth: editing && edit.selection == .reference ? 2.5 : 1.2,
                                                              dash: [5, 4]))
                    .allowsHitTesting(false)
                Text("REF")
                    .font(Theme.mono(9, .bold))
                    .padding(.horizontal, 3)
                    .background(Color.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .position(x: r.minX + 15, y: r.minY + 9)
                    .allowsHitTesting(false)
            }
            // new box being drawn
            if case .draw = action, let d = draft {
                Path(cg(d)).stroke(edit.target == .reference ? Color.white : Theme.accent,
                                   style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
            // corner handles of the selection
            if editing, let sel = edit.selection, let r = shown(sel, regs.rect(sel)) {
                ForEach(0..<4, id: \.self) { c in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1))
                        .position(corner(c, cg(r)))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func label(_ k: Int, rank: Int?, color: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(k + 1)")
            if let rank { Text(Self.circled(rank)) }
        }
        .font(Theme.mono(10, .bold))
        .padding(.horizontal, 3)
        .background(Color.black.opacity(0.55))
        .foregroundStyle(color)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    static func circled(_ n: Int) -> String {
        let s = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮", "⑯"]
        return n >= 1 && n <= s.count ? s[n - 1] : "(\(n))"
    }

    // MARK: Geometry

    private func cg(_ r: NormRect) -> CGRect {
        CGRect(x: r.x0 * size.width, y: r.y0 * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private func norm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }

    private func corner(_ i: Int, _ r: CGRect) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.maxX, y: r.minY)
        case 2: return CGPoint(x: r.maxX, y: r.maxY)
        default: return CGPoint(x: r.minX, y: r.maxY)
        }
    }

    /// The rectangle as currently shown (the draft while it is being moved / resized).
    private func shown(_ sel: RegionEditState.Selection, _ r: NormRect?) -> NormRect? {
        switch action {
        case .move(let s, _), .resize(let s, _, _):
            if s == sel, let d = draft { return d }
        default: break
        }
        return r
    }

    /// Regions with the draft applied (grid cells follow the grid area while it is edited).
    private func liveList(_ regs: AnalysisRegions) -> [NormRect] {
        var r = regs
        switch action {
        case .move(let s, _), .resize(let s, _, _):
            if let d = draft { r.set(s, d) }
        default: break
        }
        return r.list
    }

    // MARK: Gesture

    private func decide(at p: CGPoint) -> Action {
        let regs = pipeline.regions
        if let sel = edit.selection, let r = regs.rect(sel) {
            let rr = cg(r)
            for c in 0..<4 {
                let q = corner(c, rr)
                if hypot(q.x - p.x, q.y - p.y) < 26 { return .resize(sel, c, r) }
            }
        }
        if edit.target == .reference { return .draw }
        let n = norm(p)
        if let ref = regs.reference, ref.contains(n) { return .move(.reference, ref) }
        if regs.mode == .grid {
            if let a = regs.gridArea, a.contains(n) { return .move(.grid, a) }
        } else {
            for k in regs.rects.indices.reversed() where regs.rects[k].contains(n) {
                return .move(.region(k), regs.rects[k])
            }
        }
        return .draw
    }

    private func changed(_ v: DragGesture.Value) {
        if !edit.dragging { edit.dragging = true }
        if action == nil {
            let a = decide(at: v.startLocation)
            action = a
            switch a {
            case .move(let s, _), .resize(let s, _, _): edit.selection = s
            case .draw: break
            }
        }
        let p = norm(v.location)
        switch action {
        case .draw:
            draft = NormRect(norm(v.startLocation), p)
        case .move(_, let start):
            var dx = v.translation.width / size.width
            var dy = v.translation.height / size.height
            dx = min(max(dx, -start.x0), 1 - start.x1)
            dy = min(max(dy, -start.y0), 1 - start.y1)
            draft = NormRect(x0: start.x0 + dx, y0: start.y0 + dy, x1: start.x1 + dx, y1: start.y1 + dy)
        case .resize(_, let c, let start):
            var n = start
            let m: CGFloat = 0.03
            switch c {
            case 0: n.x0 = min(p.x, n.x1 - m); n.y0 = min(p.y, n.y1 - m)
            case 1: n.x1 = max(p.x, n.x0 + m); n.y0 = min(p.y, n.y1 - m)
            case 2: n.x1 = max(p.x, n.x0 + m); n.y1 = max(p.y, n.y0 + m)
            default: n.x0 = min(p.x, n.x1 - m); n.y1 = max(p.y, n.y0 + m)
            }
            draft = n
        case nil:
            break
        }
    }

    private func ended(_ v: DragGesture.Value) {
        defer { action = nil; draft = nil; edit.dragging = false }
        let tiny = hypot(v.translation.width, v.translation.height) < 6
        switch action {
        case .draw:
            guard !tiny, let d = draft, d.width >= 0.03, d.height >= 0.03 else {
                if tiny { edit.selection = nil }
                return
            }
            var regs = pipeline.regions
            if edit.target == .reference {
                regs.reference = d
                edit.selection = .reference
                edit.target = .region
            } else if regs.mode == .grid {
                regs.gridArea = d
                edit.selection = .grid
            } else {
                guard regs.rects.count < AnalysisRegions.maxFree else {
                    pipeline.toast = L("最多 6 个框")
                    return
                }
                regs.rects.append(d)
                edit.selection = .region(regs.rects.count - 1)
            }
            pipeline.regions = regs
        case .move(let s, _), .resize(let s, _, _):
            if !tiny, let d = draft {
                var regs = pipeline.regions
                regs.set(s, d)
                pipeline.regions = regs
            }
        case nil:
            break
        }
    }
}

/// Compact toolbar shown at the top of the screen while the regions are being edited.
/// Fades out while a finger is drawing / moving on the picture.
struct RegionPanel: View {
    @EnvironmentObject var pipeline: FramePipeline
    @EnvironmentObject var edit: RegionEditState
    @Binding var editing: Bool

    var body: some View {
        let regs = pipeline.regions
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { pipeline.regions.mode }, set: { m in
                    pipeline.regions.mode = m
                    edit.selection = nil
                })) {
                    Text(L("自由框")).tag(RegionMode.free)
                    Text(L("网格")).tag(RegionMode.grid)
                }
                .pickerStyle(.segmented)
                .frame(width: 112)
                PillButton(text: "REF", selected: edit.target == .reference) {
                    edit.target = edit.target == .reference ? .region : .reference
                }
                PillButton(text: L("校正"), selected: pipeline.params.useReference, disabled: regs.reference == nil) {
                    pipeline.params.useReference.toggle()
                }
                iconButton("trash", disabled: edit.selection == nil) {
                    if let s = edit.selection { pipeline.regions.remove(s) }
                    edit.selection = nil
                }
                iconButton("xmark.square") {
                    var r = pipeline.regions
                    r.rects = []
                    r.gridArea = nil
                    r.reference = nil
                    pipeline.regions = r
                    edit.selection = nil
                }
                Spacer(minLength: 0)
                Button(L("完成")) {
                    edit.selection = nil
                    edit.target = .region
                    editing = false
                }
                .font(Theme.mono(13, .bold))
                .foregroundStyle(Theme.accent)
            }
            if regs.mode == .grid {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        preset("2×2", 2, 2); preset("3×3", 3, 3); preset("4×4", 4, 4)
                        preset(L("横条"), 4, 1); preset(L("竖条"), 1, 4)
                        counter(String(format: L("行 %d"), regs.rows),
                                minus: { setGrid(rows: regs.rows - 1, cols: regs.cols) },
                                plus: { setGrid(rows: regs.rows + 1, cols: regs.cols) })
                        counter(String(format: L("列 %d"), regs.cols),
                                minus: { setGrid(rows: regs.rows, cols: regs.cols - 1) },
                                plus: { setGrid(rows: regs.rows, cols: regs.cols + 1) })
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.bar)
        .opacity(edit.dragging ? 0.08 : 1)
        .allowsHitTesting(!edit.dragging)
        .animation(.easeOut(duration: 0.15), value: edit.dragging)
    }

    private func iconButton(_ name: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(Color.white.opacity(0.12))
                .foregroundStyle(disabled ? Color.gray : Color.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func counter(_ title: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: minus) { Image(systemName: "minus").frame(width: 24, height: 26) }
            Text(title).font(Theme.mono(12, .semibold))
            Button(action: plus) { Image(systemName: "plus").frame(width: 24, height: 26) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.12))
        .clipShape(Capsule())
    }

    private func preset(_ title: String, _ rows: Int, _ cols: Int) -> some View {
        PillButton(text: title, selected: pipeline.regions.rows == rows && pipeline.regions.cols == cols) {
            setGrid(rows: rows, cols: cols)
        }
    }

    private func setGrid(rows: Int, cols: Int) {
        let r0 = min(max(rows, 1), AnalysisRegions.maxGridLines)
        let c0 = min(max(cols, 1), AnalysisRegions.maxGridLines)
        guard r0 * c0 <= AnalysisRegions.maxGridCells else {
            pipeline.toast = L("网格最多 16 格")
            return
        }
        var r = pipeline.regions
        r.rows = r0
        r.cols = c0
        pipeline.regions = r
    }
}

/// Short instructions at the bottom of the picture while editing.
struct RegionHint: View {
    @EnvironmentObject var pipeline: FramePipeline
    @EnvironmentObject var edit: RegionEditState

    var body: some View {
        let regs = pipeline.regions
        let text: String = {
            if edit.target == .reference { return L("在白纸或灰卡上拖动画参考框") }
            if regs.mode == .grid {
                return regs.gridArea == nil ? L("先在画面上拖出总区域，再选择划分方式")
                                            : L("拖总区域移动，拖四角改大小；空白处拖动重新画")
            }
            return String(format: L("在空白处拖动画新框（%d/6），拖框内移动，拖四角改大小"), regs.rects.count)
        }()
        Text(text)
            .font(Theme.mono(11, .semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.black.opacity(0.65))
            .foregroundStyle(edit.target == .reference ? Theme.accent : .white)
            .clipShape(Capsule())
            .opacity(edit.dragging ? 0 : 1)
            .allowsHitTesting(false)
    }
}

/// Colour scale of the current overlay ("red = x %").
struct ColorBarView: View {
    let mode: OverlayMode
    let scale: Float
    let flowScale: Float
    let arrivalSpan: Float

    private static let turbo: Gradient = {
        let lut = Colormap.turbo
        let stops = stride(from: 0, through: 255, by: 32).map { i -> Color in
            Color(red: Double(lut[i * 3]) / 255, green: Double(lut[i * 3 + 1]) / 255, blue: Double(lut[i * 3 + 2]) / 255)
        } + [Color(red: Double(lut[765]) / 255, green: Double(lut[766]) / 255, blue: Double(lut[767]) / 255)]
        return Gradient(colors: stops)
    }()

    var body: some View {
        let (grad, lo, hi): (Gradient, String, String) = {
            switch mode {
            case .heat:
                return (Self.turbo, "0", String(format: "%.1f%%", scale))
            case .flow:
                return (Gradient(colors: [.blue, Color(white: 0.1), .red]),
                        String(format: "−%.1f%%", flowScale), String(format: "+%.1f%%", flowScale))
            case .arrival:
                return (Gradient(colors: Array(Self.turbo.stops.map { $0.color }.reversed())),
                        "0 s", String(format: "+%.1f s", arrivalSpan))
            case .live:
                return (Self.turbo, "", "")
            }
        }()
        HStack(spacing: 4) {
            Text(lo)
            LinearGradient(gradient: grad, startPoint: .leading, endPoint: .trailing)
                .frame(width: 70, height: 7)
                .clipShape(Capsule())
            Text(hi)
        }
        .font(Theme.mono(9, .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}
