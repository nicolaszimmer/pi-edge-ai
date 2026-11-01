import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @AppStorage(SettingsKey.model) private var model = ""
    @AppStorage(SettingsKey.thinking) private var thinking = false
    @AppStorage(SettingsKey.tools) private var toolsOn = false
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingImage: Data?
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showPhotoPicker = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            isStreaming: store.isGeneratingHere && message.id == store.messages.last?.id,
                            afterTool: index > 0 && store.messages[index - 1].role == .tool
                        )
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.messages.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.currentChatID) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .overlay {
            if store.messages.isEmpty { emptyState }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .background(Theme.surface.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistoryView(newChat: startNewChat) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            Task { await loadPhoto() }
        }
        .task { await store.refreshModels() }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            HStack(spacing: 0) {
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 17))
                }
                .buttonStyle(.ds(.ghost, iconOnly: true))
                .accessibilityLabel("Chats")

                Button(action: startNewChat) {
                    Image(systemName: "square.and.pencil").font(.system(size: 17))
                }
                .buttonStyle(.ds(.ghost, iconOnly: true))
                .disabled(store.messages.isEmpty)
                .accessibilityLabel("New chat")

                Spacer(minLength: 0)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 17))
                }
                .buttonStyle(.ds(.ghost, iconOnly: true))
                .accessibilityLabel("Settings")
            }
            // On top and centred on the screen, clear of the buttons either side.
            modelMenu
                .padding(.horizontal, 96)
        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        .background(Theme.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    /// The title. Tapping it picks the model and turns Thinking on or off.
    private var modelMenu: some View {
        Menu {
            Picker(selection: $model) {
                ForEach(store.models) { m in
                    Text(m.id).tag(m.id)
                }
            } label: {
                Text("Model")
            }
            .pickerStyle(.inline)

            Toggle(isOn: $thinking) {
                Text("Thinking")
                Text("Better answers, much slower on a Pi")
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.signal)
                    Text("Pi Chat")
                        .font(Theme.section)
                        .foregroundStyle(Theme.text)
                }
                HStack(spacing: 4) {
                    if store.models.isEmpty {
                        Text(store.connectionError == nil ? "Connecting…" : "Not connected")
                            .font(Theme.sans(12))
                    } else {
                        Text(model.isEmpty ? "Choose a model" : model)
                            .font(Theme.mono(12))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(store.models.isEmpty)
        .accessibilityLabel(Text(modelMenuLabel))
    }

    private var modelMenuLabel: String {
        model.isEmpty ? "Pi Chat" : "Model: \(model). Choose another"
    }

    // MARK: Empty chat

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error = store.connectionError {
                connectionProblem(error)
            } else {
                welcome
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.signal)
                    .accessibilityHidden(true)
                Text("Gemma on your Pi")
                    .font(Theme.pageTitle)
                    .tracking(Theme.pageTitleTracking)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Ask anything, or attach a photo and ask about it.")
                    .font(Theme.lead)
                    .foregroundStyle(Theme.text2)
            }
            VStack(spacing: 8) {
                if toolsActive {
                    starter("Look something up on the web") {
                        draft = "Search the web: "
                        composerFocused = true
                    }
                }
                starter("Describe what is in a photo") {
                    draft = "Describe what is in this photo."
                    showPhotoPicker = true
                }
                starter("Summarise a text I paste in") {
                    draft = "Summarise this text:\n\n"
                    composerFocused = true
                }
                starter("Explain something step by step") {
                    draft = "Explain step by step: "
                    composerFocused = true
                }
            }
        }
    }

    private func starter(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func connectionProblem(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.connectionUnreachable {
                NoticeView(
                    .danger,
                    title: "Pi Chat cannot reach the Pi.",
                    message: "It asked \(store.serverAddress) and got no answer. Check that the Pi is switched on and on the same network as this iPhone."
                )
            } else {
                NoticeView(
                    .danger,
                    title: "Pi Chat cannot talk to the Pi.",
                    message: "Check the address and the API key in Settings. The error below says what went wrong."
                )
            }
            Fold("Error as kept", mono: true) { Text(error) }
            HStack(spacing: 8) {
                Button("Open settings") { showSettings = true }
                    .buttonStyle(.ds(.primary))
                Button("Try again") { Task { await store.refreshModels() } }
                    .buttonStyle(.ds(.secondary))
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isBusyElsewhere {
                busyElsewhere
            }
            if let data = pendingImage, let image = UIImage(data: data) {
                pendingPhoto(image)
            }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 0) {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Image(systemName: "photo")
                            .font(.system(size: 17))
                            .frame(width: 40, height: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text2)
                    .accessibilityLabel("Attach a photo")

                    TextField(
                        text: $draft,
                        prompt: Text(pendingImage == nil ? "Ask anything, or attach a photo" : "Ask about the photo")
                            .foregroundStyle(Theme.text3),
                        axis: .vertical
                    ) {
                        Text("Message")
                    }
                    .font(Theme.lead)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.vertical, 9)
                    .padding(.trailing, 10)
                }
                .padding(.leading, 2)
                .frame(minHeight: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    // The message box is the one field that takes the signal when focused.
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(composerFocused ? Theme.signal : Theme.lineStrong, lineWidth: composerFocused ? 2 : 1)
                }

                if store.isGeneratingHere {
                    Button("Stop") { store.stop() }
                        .buttonStyle(.ds(.secondary))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(.ds(.primary, iconOnly: true))
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            Text(toolsActive
                 ? "Your chat stays on the Pi. Web searches and the pages the model reads go out to the internet."
                 : "Gemma runs on your Pi. Nothing you send leaves your home network.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func pendingPhoto(_ image: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                .accessibilityLabel("Photo to send")
            VStack(alignment: .leading, spacing: 2) {
                Text("Photo attached")
                    .font(Theme.sans(13, .medium))
                    .foregroundStyle(Theme.text)
                Text("Sent at 1024 px at most, so the Pi answers sooner.")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
            Button("Remove") { pendingImage = nil }
                .buttonStyle(.ds(.ghost))
        }
    }

    /// The Pi answers one question at a time: while it answers in another
    /// chat, this one waits, with a way to go there.
    private var busyElsewhere: some View {
        let title = store.chats.first { $0.id == store.generatingChatID }?.title ?? "another chat"
        return HStack(spacing: 8) {
            Text(store.toolStepAwaitingApproval == nil
                 ? "Still answering in “\(title)”. You can ask here once it is done."
                 : "“\(title)” waits for you to allow a tool. You can ask here once it is done.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open it") {
                if let id = store.generatingChatID { store.open(id) }
            }
            .buttonStyle(.ds(.ghost, height: 32))
        }
    }

    /// Tools on in Settings, and the Pi offers some.
    private var toolsActive: Bool { toolsOn && !store.serverTools.isEmpty }

    private var canSend: Bool {
        !store.isGenerating
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil)
    }

    private func startNewChat() {
        store.newChat()
        draft = ""
        pendingImage = nil
    }

    private func send() {
        guard canSend else { return }
        store.send(draft.trimmingCharacters(in: .whitespacesAndNewlines), image: pendingImage)
        draft = ""
        pendingImage = nil
    }

    private func loadPhoto() async {
        guard let item = photoItem else { return }
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        // Smaller images = fewer tokens = faster answers on the Pi.
        pendingImage = image.jpegForUpload(maxDimension: 1024)
    }
}

// MARK: - A turn

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    /// Comes right after a tool step: the model is reading what the tool found.
    var afterTool = false

    var body: some View {
        switch message.role {
        case .user:
            userTurn
        case .tool:
            ToolStepRow(message: message, isActive: isStreaming)
        case .assistant:
            if !message.isToolRequestOnly {
                assistantTurn
            }
        }
    }

    /// The person's message: right-aligned on accent-soft, a 4 pt corner at the tail.
    private var userTurn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let data = message.imageJPEG, let image = UIImage(data: data) {
                let size = Self.fitted(image.size, maxWidth: 200, maxHeight: 220)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                    .accessibilityLabel("Photo")
            }
            if !message.text.isEmpty {
                Text(Self.markdown(message.text))
                    .font(Theme.lead)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Theme.accentSoft,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 14,
                            bottomLeadingRadius: 14,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 14
                        )
                    )
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.text
                        }
                    }
            }
        }
        .padding(.leading, 48)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The answer, drawn from its Markdown and maths, with what it took and when under it.
    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.reasoning.isEmpty {
                Fold("Thinking") { Text(message.reasoning) }
            }
            if message.isError {
                CalloutView(message.text, tone: .danger)
            } else if !message.text.isEmpty {
                MarkdownView(text: message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isStreaming {
                WaitingRow(message.reasoning.isEmpty
                    ? (afterTool
                        ? "Reading what it found. This can take a while on a Pi."
                        : "Reading your message. The first words can take a while on a Pi.")
                    : "Thinking. The answer follows once it is done.")
            }
            if !isStreaming && !message.isError && !message.text.isEmpty {
                HStack(spacing: 2) {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 15))
                    }
                    .buttonStyle(.ds(.ghost, iconOnly: true))
                    .accessibilityLabel("Copy the answer")

                    Text(metaLine)
                        .font(Theme.sans(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                }
                .padding(.leading, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 214 tokens · 6.1 tokens a second · 16:52
    private var metaLine: String {
        [message.stats, message.date?.chatStamp].compactMap { $0 }.joined(separator: " · ")
    }

    private static func fitted(_ size: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxWidth) }
        let scale = min(maxWidth / size.width, maxHeight / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

extension UIImage {
    /// Downscales so the longest side is at most `maxDimension`, as JPEG.
    func jpegForUpload(maxDimension: CGFloat, quality: CGFloat = 0.8) -> Data? {
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
