import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.1)   // Blackmagic-ish orange
    static let bar = Color.black.opacity(0.78)
    static let panel = Color(white: 0.08).opacity(0.92)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Two-line status chip (label / value) used in the top bar.
struct StatusChip: View {
    let title: String
    let value: String
    var auto = false
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(selected ? Theme.accent : Color.gray)
                HStack(spacing: 2) {
                    if auto {
                        Text("A").font(Theme.mono(9, .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 2)
                            .background(Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    Text(value)
                        .font(Theme.mono(14, .semibold))
                        .foregroundStyle(selected ? Theme.accent : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(selected ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Small selectable pill used inside control panels.
struct PillButton: View {
    let text: String
    var selected = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.mono(13, .semibold))
                .foregroundStyle(selected ? .black : (disabled ? .gray : .white))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Theme.accent : Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Square toggle on the right edge of the preview (FC / ZEB / PEAK …).
struct AssistToggle: View {
    let text: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.mono(10, .bold))
                .foregroundStyle(isOn ? .black : .white)
                .frame(width: 40, height: 30)
                .background(isOn ? Theme.accent : Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// Labelled slider row with a value read-out.
struct ValueSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let label: String
    @Binding var value: V
    let range: ClosedRange<V>
    let format: (V) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.mono(11)).foregroundStyle(.gray).frame(width: 52, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(Theme.accent)
            Text(format(value)).font(Theme.mono(12, .semibold)).frame(width: 64, alignment: .trailing)
        }
    }
}
