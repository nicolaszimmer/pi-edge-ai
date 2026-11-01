import SwiftUI

/// Every saved chat, the most recent first, grouped by when it was last used.
/// Tap one to open it; swipe it or hold it to rename or delete it.
struct HistoryView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Starts a new chat in the chat view (it also clears the message box).
    let newChat: () -> Void

    @State private var search = ""
    @State private var renaming: ChatSummary?
    @State private var newTitle = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.chats.isEmpty {
                CalloutView("No saved chats yet. Every chat is kept here once you ask something in it.")
                    .padding(16)
                Spacer()
            } else {
                searchField
                list
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .presentationBackground(Theme.bg)
        .alert("Rename the chat", isPresented: isRenaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let chat = renaming { store.rename(chat.id, to: newTitle) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Chats")
                .font(Theme.section)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button("New chat") {
                    newChat()
                    dismiss()
                }
                .buttonStyle(.ds(.ghost))
                .disabled(store.messages.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.ds(.ghost))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Theme.text3)
                .accessibilityHidden(true)
            TextField("", text: $search, prompt: Text("Search chats").foregroundStyle(Theme.text3))
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityLabel("Search chats")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text3)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? Theme.accent : Theme.lineStrong, lineWidth: searchFocused ? 2 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: List

    private var list: some View {
        List {
            if sections.isEmpty {
                Text("No chat has “\(search)” in its title or last answer.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.text2)
                    .listRowBackground(Theme.surface)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.chats) { chat in
                        row(chat)
                            .listRowBackground(chat.id == store.currentChatID ? Theme.signalSoft : Theme.surface)
                            .listRowSeparatorTint(Theme.line)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.delete(chat.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    startRenaming(chat)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Theme.text3)
                            }
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { startRenaming(chat) }
                                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(chat.id) }
                            }
                    }
                } header: {
                    Text(section.title)
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(Theme.text3)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func row(_ chat: ChatSummary) -> some View {
        Button {
            store.open(chat.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chat.title)
                        .font(Theme.sans(15, .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(chat.updated.listStamp)
                        .font(Theme.sans(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                }
                if chat.id == store.generatingChatID {
                    Text("Answering…")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.text3)
                } else if !chat.preview.isEmpty {
                    Text(chat.preview)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chat.id == store.currentChatID ? .isSelected : [])
    }

    // MARK: Grouping

    private struct DaySection: Identifiable {
        let title: String
        var chats: [ChatSummary]
        var id: String { title }
    }

    private var filtered: [ChatSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.chats }
        return store.chats.filter {
            $0.title.localizedStandardContains(query) || $0.preview.localizedStandardContains(query)
        }
    }

    /// Today, Yesterday, Previous 7 days, Previous 30 days, then by month.
    private var sections: [DaySection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var sections: [DaySection] = []
        for chat in filtered {
            let title: String
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: chat.updated), to: today).day ?? 0
            switch days {
            case ..<1: title = "Today"
            case 1: title = "Yesterday"
            case 2..<7: title = "Previous 7 days"
            case 7..<30: title = "Previous 30 days"
            default: title = chat.updated.formatted(.dateTime.month(.wide).year())
            }
            if sections.last?.title == title {
                sections[sections.count - 1].chats.append(chat)
            } else {
                sections.append(DaySection(title: title, chats: [chat]))
            }
        }
        return sections
    }

    // MARK: Renaming

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    private func startRenaming(_ chat: ChatSummary) {
        newTitle = chat.title
        renaming = chat
    }
}

extension Date {
    /// 16:52 today, Mon this week, 31 Oct this year, 31 Oct 2025 before.
    var listStamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: Date())).day,
           days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated).year())
    }
}
