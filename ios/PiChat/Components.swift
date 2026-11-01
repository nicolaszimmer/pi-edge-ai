import SwiftUI

// Shared controls drawn to Rapid Review's components: Button, Notice, Callout,
// Disclosure, OptionCard and Switch, plus the assistant's waiting dots.

// MARK: - Button

/// Buttons are ink: one primary for the main action of a view, secondary for
/// everything else, ghost for low actions. 44 pt high, where a finger is likely.
struct DSButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, danger }

    var variant: Variant = .secondary
    var height: CGFloat = 44
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, variant: variant, height: height, iconOnly: iconOnly)
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static func ds(_ variant: DSButtonStyle.Variant, height: CGFloat = 44, iconOnly: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: variant, height: height, iconOnly: iconOnly)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: DSButtonStyle.Variant
    let height: CGFloat
    let iconOnly: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Theme.sans(14, (variant == .primary || variant == .danger) ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 0 : 14)
            .frame(minWidth: height, minHeight: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if variant == .secondary {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.lineStrong)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }

    private var foreground: Color {
        switch variant {
        case .primary: Theme.onAccent
        case .secondary: Theme.text
        case .ghost: Theme.text2
        case .danger: Theme.onCrit
        }
    }

    private var fill: Color {
        switch variant {
        case .primary: Theme.accent
        case .secondary: Theme.surface
        case .ghost: configuration.isPressed ? Theme.surface2 : Color.clear
        case .danger: Theme.crit
        }
    }
}

// MARK: - Notice

/// The result of something a person just did, or a warning beside its subject:
/// a bold first sentence says what happened, the rest what it means.
struct NoticeView: View {
    enum Tone { case success, warning, danger, info }

    let tone: Tone
    let title: String?
    let message: String

    init(_ tone: Tone, title: String? = nil, message: String) {
        self.tone = tone
        self.title = title
        self.message = message
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol = symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
            }
            words
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var words: Text {
        guard let title = title else { return Text(message) }
        return Text(title).font(Theme.sans(14, .semibold)) + Text(" " + message)
    }

    private var symbol: String? {
        switch tone {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "exclamationmark.circle"
        case .info: nil
        }
    }

    private var iconColor: Color {
        switch tone {
        case .success: Theme.fixed
        case .warning: Theme.major
        case .danger: Theme.crit
        case .info: Theme.text3
        }
    }

    private var fill: Color {
        switch tone {
        case .success: Theme.fixedSoft
        case .warning: Theme.majorSoft
        case .danger: Theme.critSoft
        case .info: Theme.surface2
        }
    }
}

// MARK: - Callout

/// A quiet note inside its subject: one or two sentences, no icon, no title.
struct CalloutView: View {
    enum Tone { case plain, warning, danger }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .plain) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(Theme.sans(13))
            .foregroundStyle(tone == .plain ? Theme.text2 : Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var fill: Color {
        switch tone {
        case .plain: Theme.surface2
        case .warning: Theme.majorSoft
        case .danger: Theme.critSoft
        }
    }
}

// MARK: - Disclosure

/// Something folded away under a line that names it (Thinking, Error as kept).
struct Fold<Content: View>: View {
    let summary: String
    let mono: Bool
    let content: Content
    @State private var isOpen = false

    init(_ summary: String, mono: Bool = false, @ViewBuilder content: () -> Content) {
        self.summary = summary
        self.mono = mono
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isOpen.toggle()
            } label: {
                Text(summary)
                    .font(Theme.sans(12, .medium))
                    .underline(true, color: Theme.lineStrong)
                    .foregroundStyle(Theme.text3)
                    .frame(minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Open" : "Folded")

            if isOpen {
                if mono {
                    content
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.code, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                } else {
                    content
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Fields

/// A text field in a 44 pt box with its label inside, the way TextField draws it.
struct FieldBox<Field: View>: View {
    let label: String
    let field: Field
    @FocusState private var focused: Bool

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 64, alignment: .leading)
                .accessibilityHidden(true)
            field
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .focused($focused)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Theme.accent : Theme.lineStrong, lineWidth: focused ? 2 : 1)
        }
    }
}

// MARK: - Option card

/// A choice drawn as a card. Selected: a signal border on signal-soft, the radio
/// a 5 pt signal ring around an on-signal dot.
struct OptionCard: View {
    let title: String
    let note: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.mono(14, .medium))
                        .foregroundStyle(Theme.text)
                    if let note {
                        Text(note)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                RadioMark(isOn: isSelected)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.signalSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Theme.signal : Theme.lineStrong, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Theme.onSignal : Theme.surface)
            .overlay {
                Circle().strokeBorder(isOn ? Theme.signal : Theme.lineStrong, lineWidth: isOn ? 5 : 1.5)
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

// MARK: - Switch

/// A bordered settings row with a switch. The track is ink when on.
struct SwitchRow: View {
    let title: String
    let note: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.text)
                Text(note)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

// MARK: - Waiting

/// The assistant's waiting step: three dots that rise in turn (still under
/// Reduce Motion) and one line that says what is happening.
struct WaitingRow: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .frame(width: 6, height: 6)
                            .offset(y: reduceMotion ? (i == 1 ? -3 : 0) : Self.lift(t, i))
                    }
                }
                .frame(height: 16)
            }
            .accessibilityHidden(true)

            Text(text)
                .font(Theme.body)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.text3)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static func lift(_ t: TimeInterval, _ i: Int) -> CGFloat {
        let p = t * 1.4 - Double(i) * 0.18
        let f = p - p.rounded(.down)
        return f < 0.4 ? CGFloat(-3 * sin(f / 0.4 * .pi)) : 0
    }
}

// MARK: - Words

enum ModelNote {
    /// One line for the model menu.
    static func short(for id: String) -> String? {
        if id.contains("e2b") { return "Fast" }
        if id.contains("e4b") { return "Smarter, at about half the speed" }
        return nil
    }

    /// A sentence for the option cards in Settings.
    static func long(for id: String) -> String? {
        if id.contains("e2b") { return "Fast. The one to use most of the time." }
        if id.contains("e4b") { return "Smarter, at about half the speed." }
        return nil
    }
}

extension Date {
    /// The phone's own time: 16:52 today, 31 Oct, 16:52 before.
    var chatStamp: String {
        if Calendar.current.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        return formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
