import SwiftUI
import UIKit

struct ContentView: View {
    /// What a successful connect presents: the in-app browser, or the proxy-only
    /// screen (SOCKS + port forwards for other apps, no browser).
    private enum SessionMode {
        case browser
        case proxyOnly
    }

    @StateObject private var proxy = ProxyController()
    @StateObject private var portForwards = PortForwardController()

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
    @State private var sessionMode: SessionMode = .browser
    @State private var proxyOnlyActive = false

    // Best-effort background keep-alive: buys ~30s of runtime after backgrounding
    // so the SOCKS listener and port forwards outlive a brief app switch.
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

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
                        VStack(spacing: 10) {
                            Button("Start proxy") {
                                startProxy(mode: .browser)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)

                            // Same tunnel, no browser: run SOCKS5 + port forwards
                            // for other apps on this device.
                            Button("Start proxy only (no browser)") {
                                startProxy(mode: .proxyOnly)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        }
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
            .fullScreenCover(isPresented: proxyOnlyIsPresented) {
                ProxyOnlyView(proxy: proxy, store: portForwards, onStop: { proxy.stop() })
                    .interactiveDismissDisabled(proxy.socksPort != nil)
            }
            .onChange(of: proxy.phase) { _, newPhase in
                // Persist the token only once it has actually authenticated, so a
                // typo'd credential (which starts fine but fails the handshake)
                // never overwrites a good one. Save the token from the snapshot the
                // connection used, not the live (still-editable) field.
                if newPhase == .connected, let token = connectingSettings?.authToken {
                    TokenStore.save(token)
                }
                syncSessionPresentation()
            }
            .onChange(of: proxy.socksPort) {
                syncSessionPresentation()
                syncForwards()
            }
            .onChange(of: proxy.socksAlive) { syncForwards() }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            .onAppear {
                loadStoredToken()
                syncSessionPresentation()
                syncForwards()
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

    /// Mirror of `browserIsPresented`: a tunnel drop never dismisses the screen;
    /// only an explicit Stop (socksPort == nil) lets the cover go.
    private var proxyOnlyIsPresented: Binding<Bool> {
        Binding {
            proxyOnlyActive
        } set: { isPresented in
            if !isPresented, proxy.socksPort == nil {
                proxyOnlyActive = false
            }
        }
    }

    private func startProxy(mode: SessionMode) {
        sessionMode = mode
        let settings = currentSettings()
        connectingSettings = settings
        proxy.start(settings)
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

    /// Present-only: reveal the mode's screen once the handshake lands and never
    /// tear it down here. A drop after connecting keeps it up (the tunnel
    /// auto-reconnects); teardown happens solely through the explicit-quit path —
    /// Stop → `proxy.stop()` (socksPort == nil) → the presentation binding's
    /// setter clears the state.
    private func syncSessionPresentation() {
        guard proxy.phase == .connected, let socksPort = proxy.socksPort else { return }

        switch sessionMode {
        case .browser:
            if browserModel == nil {
                browserModel = BrowserModel(socksPort: socksPort, library: library)
            } else if browserModel?.socksPort != socksPort {
                browserModel?.stopAll()
                browserModel = BrowserModel(socksPort: socksPort, library: library)
            }
        case .proxyOnly:
            proxyOnlyActive = true
        }
    }

    /// Keep the enabled forwards' lifecycles tied to the SOCKS listener: start
    /// when it's alive, stop when it goes away, rebind on a port change. Runs in
    /// both modes — the forwards are useful while browsing too.
    private func syncForwards() {
        portForwards.syncProxy(socksAlive: proxy.socksAlive, socksPort: proxy.socksPort)
    }

    // MARK: - Background keep-alive

    /// Best-effort only: extended execution buys ~30s after backgrounding, then
    /// iOS suspends the process (sockets survive; the core reconnects the tunnel
    /// link on its own once resumed). No Network Extension, so nothing stronger
    /// is available.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard proxy.socksPort != nil, backgroundTask == .invalid else { break }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "flextunnel-proxy") {
                endBackgroundTask()
            }
        case .active:
            endBackgroundTask()
            proxy.noteForegrounded()
        default:
            break
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
