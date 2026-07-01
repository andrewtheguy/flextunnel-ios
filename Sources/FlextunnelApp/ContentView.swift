import SwiftUI

struct ContentView: View {
    @StateObject private var proxy = ProxyController()

    @AppStorage("lastServerNodeID") private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    @State private var socksPortText = "18080"
    @State private var browserModel: BrowserModel?
    @State private var didLoadToken = false
    // The immutable settings snapshot handed to `proxy.start`, so the Keychain
    // save on `.connected` persists the exact token that authenticated — not
    // whatever the (still-editable) field holds by the time the handshake lands.
    @State private var connectingSettings: ProxyController.Settings?

    // Owned here so bookmarks/history survive BrowserModel being recreated when
    // the proxy port changes.
    @State private var library = BrowserLibrary()

    var body: some View {
        NavigationStack {
            Form {
                Section("Setup") {
                    LabeledField("Server node id") {
                        TextField("", text: $serverNodeID)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Auth token") {
                        SecureField("", text: $authToken)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Relay URLs", hint: "comma-separated, optional") {
                        TextField("", text: $relayURLs)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("SOCKS bind port") {
                        TextField("", text: $socksPortText)
                            .keyboardType(.numberPad)
                            .autocorrectionDisabled()
                            .onChange(of: socksPortText) { _, newValue in
                                let filtered = newValue.filter { $0.isNumber }
                                if filtered != newValue {
                                    socksPortText = filtered
                                }
                            }
                    }
                    if let portValidationMessage {
                        Text(portValidationMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    if proxy.phase == .connecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Connecting to server…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { proxy.stop() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else {
                        Button("Start proxy") {
                            let settings = currentSettings()
                            connectingSettings = settings
                            proxy.start(settings)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(!canStartProxy)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if proxy.phase == .failed {
                        Text(proxy.lastError ?? proxy.status)
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
            .onChange(of: proxy.phase) { _, newPhase in
                // Persist the token only once it has actually authenticated, so a
                // typo'd credential (which starts fine but fails the handshake)
                // never overwrites a good one. Save the token from the snapshot the
                // connection used, not the live (still-editable) field.
                if newPhase == .connected, let token = connectingSettings?.authToken {
                    TokenStore.save(token)
                }
                syncBrowserPresentation()
            }
            .onChange(of: proxy.socksPort) { syncBrowserPresentation() }
            .onAppear {
                loadStoredToken()
                syncBrowserPresentation()
            }
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

    /// Prefill the auth token from the Keychain on first appearance.
    private func loadStoredToken() {
        guard !didLoadToken else { return }
        didLoadToken = true
        if let token = TokenStore.load() {
            authToken = token
        }
    }

    /// Present-only: create the browser once the handshake lands and never tear
    /// it down here. A drop after connecting keeps the browser up (the tunnel
    /// auto-reconnects behind an overlay); teardown happens solely through the
    /// explicit-quit path — `stopAndDismiss` → `proxy.stop()` (socksPort == nil)
    /// → the `browserIsPresented` setter clears `browserModel`.
    private func syncBrowserPresentation() {
        guard proxy.phase == .connected, let socksPort = proxy.socksPort else { return }

        if browserModel == nil {
            browserModel = BrowserModel(socksPort: socksPort, library: library)
        } else if browserModel?.socksPort != socksPort {
            browserModel?.stopAll()
            browserModel = BrowserModel(socksPort: socksPort, library: library)
        }
    }
}

/// A form row whose label stays visible above the field even after the field
/// has content — unlike a placeholder, which disappears once the user types.
private struct LabeledField<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
