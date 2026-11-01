import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @AppStorage(SettingsKey.model) private var model = ""
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingImage: Data?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.messages) { message in
                            MessageRow(
                                message: message,
                                isStreaming: store.isGenerating && message.id == store.messages.last?.id
                            )
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.messages.last?.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: store.messages.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .overlay {
                if store.messages.isEmpty { emptyState }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle(model.isEmpty ? "Pi Chat" : model)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.models.count > 1 {
                        Menu {
                            Picker("Model", selection: $model) {
                                ForEach(store.models) { Text($0.id).tag($0.id) }
                            }
                        } label: { Image(systemName: "cpu") }
                            .accessibilityLabel("Choose model")
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .task { await store.refreshModels() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Gemma on your Pi", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            if let error = store.connectionError {
                Text(error)
            } else {
                Text("Ask anything, or attach a photo. Everything stays on your home network.")
            }
        } actions: {
            if store.connectionError != nil {
                Button("Open Settings") { showSettings = true }
                Button("Retry") { Task { await store.refreshModels() } }
            }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = pendingImage, let image = UIImage(data: data) {
                HStack(alignment: .top) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Button { pendingImage = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove photo")
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo").font(.title3).padding(.bottom, 6)
                }
                .accessibilityLabel("Attach photo")

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))

                if store.isGenerating {
                    Button { store.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: photoItem) {
            Task { await loadPhoto() }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
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

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    @State private var showReasoning = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if let data = message.imageJPEG, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                if !message.reasoning.isEmpty {
                    DisclosureGroup("Thinking", isExpanded: $showReasoning) {
                        Text(message.reasoning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.footnote)
                }
                if !message.text.isEmpty {
                    Text(Self.markdown(message.text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(isUser ? Color.white : Color.primary)
                        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16))
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = message.text
                            }
                        }
                } else if isStreaming {
                    ProgressView().padding(8)
                }
                if let stats = message.stats {
                    Text(stats).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var bubbleColor: Color {
        if message.isError { return Color.red.opacity(0.15) }
        return isUser ? Color.accentColor : Color(.secondarySystemBackground)
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
