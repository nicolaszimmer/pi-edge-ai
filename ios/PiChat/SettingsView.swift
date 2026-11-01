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
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(SettingsKey.defaultServerURL, text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Both are printed at the end of install.sh on the Pi. If pi-llm.local doesn't resolve, use the Pi's IP address.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if store.models.isEmpty {
                        Text("No models loaded yet: test the connection first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(store.models) { Text($0.id).tag($0.id) }
                        }
                    }
                    Toggle("Thinking", isOn: $thinking)
                } header: {
                    Text("Model")
                } footer: {
                    Text("E2B is fast; E4B is smarter but about half the speed. Switching takes a few seconds while the Pi loads the other model. Thinking makes answers better but much slower on a Pi.")
                }

                Section("System prompt") {
                    TextField("Optional, e.g. \"Answer briefly.\"", text: $systemPrompt, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        await store.refreshModels()
        testing = false
        if let error = store.connectionError {
            testResult = "❌ \(error)"
        } else {
            testResult = "✅ Connected: \(store.models.map(\.id).joined(separator: ", "))"
        }
    }
}
