import SwiftUI

struct ContentView: View {
    @StateObject private var proxy = ProxyController()

    @AppStorage("lastServerNodeID") private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    @State private var socksPortText = "18080"
    @State private var browserModel: BrowserModel?

    var body: some View {
        NavigationStack {
            Form {
                Section("Setup") {
                    TextField("Server node id", text: $serverNodeID)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Auth token", text: $authToken)
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

                Section {
                    Button("Start proxy") {
                        proxy.start(currentSettings())
                    }
                    .disabled(!canStartProxy)

                    if let err = proxy.lastError {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("flextunnel")
            .scrollDismissesKeyboard(.interactively)
            .fullScreenCover(isPresented: browserIsPresented) {
                if let browserModel {
                    BrowserView(model: browserModel, proxy: proxy)
                        .interactiveDismissDisabled(proxy.socksPort != nil)
                }
            }
            .onChange(of: proxy.healthy) { syncBrowserPresentation() }
            .onChange(of: proxy.socksPort) { syncBrowserPresentation() }
            .onAppear { syncBrowserPresentation() }
        }
    }

    private var browserIsPresented: Binding<Bool> {
        Binding {
            browserModel != nil
        } set: { isPresented in
            if !isPresented, proxy.socksPort == nil {
                browserModel = nil
            }
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

    private func syncBrowserPresentation() {
        guard let socksPort = proxy.socksPort, proxy.healthy else {
            browserModel?.stopAll()
            browserModel = nil
            return
        }

        if browserModel?.socksPort != socksPort {
            browserModel = BrowserModel(socksPort: socksPort)
        }
    }
}

#Preview {
    ContentView()
}
