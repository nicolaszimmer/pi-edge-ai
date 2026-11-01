import SwiftUI

struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.serverURL) private var serverURL = SettingsKey.defaultServerURL
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.model) private var model = ""
    @AppStorage(SettingsKey.systemPrompt) private var systemPrompt = ""
    @AppStorage(SettingsKey.thinking) private var thinking = false

    @State private var testing = false
    @State private var testResult: TestResult?
    @FocusState private var promptFocused: Bool

    private enum TestResult: Equatable {
        case connected([String])
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    serverPanel
                    modelPanel
                    promptPanel
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 64)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg.ignoresSafeArea())
        .presentationBackground(Theme.bg)
        .onChange(of: serverURL) { testResult = nil }
        .onChange(of: apiKey) { testResult = nil }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Settings")
                .font(Theme.section)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            HStack {
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

    // MARK: Server

    private var serverPanel: some View {
        panel("Server") {
            VStack(spacing: 8) {
                FieldBox("Address") {
                    TextField("", text: $serverURL, prompt: Text(SettingsKey.defaultServerURL).foregroundStyle(Theme.text3))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                FieldBox("API key") {
                    SecureField("", text: $apiKey, prompt: Text("From install.sh").foregroundStyle(Theme.text3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            (Text("Both are printed at the end of ")
                + Text("install.sh").font(Theme.mono(12))
                + Text(" on the Pi. If pi-llm.local does not answer, use the Pi’s IP address."))
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "Testing the connection…" : "Test connection")
                }
            }
            .buttonStyle(.ds(.secondary))
            .disabled(testing)

            if let testResult {
                switch testResult {
                case .connected(let ids):
                    NoticeView(.success, title: "Connected.", message: Self.modelsSentence(ids))
                case .failed(let error):
                    NoticeView(.danger, title: "The test failed.", message: error)
                }
            }
        }
    }

    // MARK: Model

    private var modelPanel: some View {
        panel("Model") {
            if store.models.isEmpty {
                CalloutView("No models yet. Test the connection first.")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.models) { m in
                        OptionCard(
                            title: m.id,
                            note: ModelNote.long(for: m.id),
                            isSelected: m.id == model
                        ) {
                            model = m.id
                        }
                    }
                }
                Text("Switching takes a few seconds while the Pi loads the other model.")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SwitchRow(
                title: "Thinking",
                note: "Thinks before it answers. Better answers, but much slower on a Pi.",
                isOn: $thinking
            )
        }
    }

    // MARK: System prompt

    private var promptPanel: some View {
        panel("System prompt") {
            TextField("", text: $systemPrompt, prompt: Text("For example: Answer briefly.").foregroundStyle(Theme.text3), axis: .vertical)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineLimit(3...8)
                .focused($promptFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(promptFocused ? Theme.accent : Theme.lineStrong, lineWidth: promptFocused ? 2 : 1)
                }
                .accessibilityLabel("System prompt")
            Text("Sent at the start of every chat. Leave it empty for none.")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text3)
        }
    }

    // MARK: Parts

    /// A panel: surface with a hairline border, radius 12, its title in `section`.
    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.section)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    /// "The Pi offers 2 models: gemma-4-e2b and gemma-4-e4b."
    private static func modelsSentence(_ ids: [String]) -> String {
        switch ids.count {
        case 0: return "The Pi answered, but offers no models yet."
        case 1: return "The Pi offers 1 model: \(ids[0])."
        default: return "The Pi offers \(ids.count) models: \(ids.formatted(.list(type: .and)))."
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        await store.refreshModels()
        testing = false
        if let error = store.connectionError {
            testResult = .failed(error)
        } else {
            testResult = .connected(store.models.map(\.id))
        }
    }
}
