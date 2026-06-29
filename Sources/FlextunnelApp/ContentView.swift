import SwiftUI

struct ContentView: View {
    @StateObject private var proxy = ProxyController()

    @AppStorage("lastServerNodeID") private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    @State private var socksPortText = "18080"

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server node id", text: $serverNodeID)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Auth token", text: $authToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Relay URLs (comma-separated, optional)", text: $relayURLs)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("SOCKS bind port", text: $socksPortText)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .onChange(of: socksPortText) { _, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue {
                                socksPortText = filtered
                            }
                        }
                    if let portValidationMessage {
                        Text(portValidationMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section("Status") {
                    LabeledContent("State", value: proxy.status)
                    if let socksPort = proxy.socksPort {
                        LabeledContent("SOCKS", value: "127.0.0.1:\(socksPort)")
                    }
                    if proxy.socksPort != nil {
                        LabeledContent("Health") {
                            Label(proxy.healthy ? "alive" : "down",
                                  systemImage: proxy.healthy
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(proxy.healthy ? .green : .red)
                        }
                    }
                    if let err = proxy.lastError {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    Button("Start proxy") {
                        proxy.start(currentSettings())
                    }
                    .disabled(!canStartProxy)

                    Button("Stop", role: .destructive) {
                        proxy.stop()
                    }
                    .disabled(proxy.socksPort == nil)
                }

                if let socksPort = proxy.socksPort, proxy.healthy {
                    Section("Browse (through SOCKS5)") {
                        NavigationLink("Open browser") {
                            BrowserView(model: BrowserModel(socksPort: socksPort), proxy: proxy)
                                .navigationTitle("Browser")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                } else {
                    Section("Browse (through SOCKS5)") {
                        Label("Start a healthy proxy to browse", systemImage: "lock.shield")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("flextunnel")
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var trimmedServerNodeID: String {
        serverNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAuthToken: String {
        authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedSocksPort: UInt16? {
        let trimmed = socksPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65535).contains(value) else {
            return nil
        }
        return UInt16(value)
    }

    private var portValidationMessage: String? {
        let trimmed = socksPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a SOCKS port."
        }
        guard let value = Int(trimmed), (1...65535).contains(value) else {
            return "Use a port from 1 to 65535."
        }
        return nil
    }

    private var canStartProxy: Bool {
        !trimmedServerNodeID.isEmpty && !trimmedAuthToken.isEmpty && parsedSocksPort != nil
    }

    private func currentSettings() -> ProxyController.Settings {
        ProxyController.Settings(
            serverNodeID: trimmedServerNodeID,
            authToken: trimmedAuthToken,
            socksPort: parsedSocksPort ?? 18080,
            relayURLs: splitCSV(relayURLs)
        )
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    ContentView()
}
