import SwiftUI

/// A tool the model used, between the question and the answer: one quiet line
/// that says what it did, with what it found folded away under it. While the
/// step waits, the question whether it may, with the person's three answers.
struct ToolStepRow: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    /// The step the chat on screen is at right now.
    let isActive: Bool

    var body: some View {
        Group {
            if isActive && message.toolState == .waitingForApproval {
                approval
            } else if isActive && message.toolState == .running {
                WaitingRow(message.toolLabel.running)
            } else {
                summary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(message.toolSummary)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if (message.toolState == .done || message.toolState == .failed) && !message.text.isEmpty {
                Fold(message.toolState == .failed ? "What went wrong" : "What it found", mono: true) {
                    Text(message.text)
                }
                .padding(.leading, 22)
            }
        }
    }

    private var icon: String {
        switch message.toolState {
        case .done: (message.toolName ?? "").hasSuffix("fetch") ? "doc.text" : "magnifyingglass"
        case .failed: "exclamationmark.triangle"
        default: "minus.circle"
        }
    }

    private var approval: some View {
        let label = message.toolLabel
        return VStack(alignment: .leading, spacing: 10) {
            Text("The model wants to \(label.ask).")
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            // In full: the model picks the address (or input), and a long
            // one can carry more than its start shows.
            if let detail = label.detail {
                Text(detail)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("It goes out to the internet through your Pi. Your chat stays on the Pi.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var buttons: some View {
        Button("Allow") { store.answerToolRequest(.allow) }
            .buttonStyle(.ds(.primary))
        Button("Always allow this tool") { store.answerToolRequest(.alwaysAllow) }
            .buttonStyle(.ds(.secondary))
        Button("Don’t allow") { store.answerToolRequest(.deny) }
            .buttonStyle(.ds(.ghost))
    }
}
