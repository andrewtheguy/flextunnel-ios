import SwiftUI
import UIKit

struct ContentView: View {
    /// What a successful connect presents: the in-app browser, or the proxy-only
    /// screen (SOCKS + port forwards for other apps, no browser). Raw values are
    /// the AppStorage encoding of the remembered choice.
    private enum SessionMode: String {
        case browser
        case proxyOnly

        var title: String {
            switch self {
            case .browser: return "Browse the web"
            case .proxyOnly: return "Forward ports"
            }
        }

        var description: String {
            switch self {
            case .browser:
                return "Open the built-in browser through the tunnel. "
                    + "Private hostnames resolve on the server."
            case .proxyOnly:
                return "Run the proxy without the browser and forward local ports "
                    + "to private hosts, so other apps on this device "
                    + "(SSH, RDP, databases…) can reach them at localhost."
            }
        }

        var icon: String {
            switch self {
            case .browser: return "safari.fill"
            case .proxyOnly: return "app.connected.to.app.below.fill"
            }
        }

        var cta: String {
            switch self {
            case .browser: return "Start Browsing"
            case .proxyOnly: return "Start Port Forwarding"
            }
        }

        var connectingLabel: String {
            switch self {
            case .browser: return "Starting browser session…"
            case .proxyOnly: return "Starting port forwarding…"
            }
        }
    }

    @StateObject private var proxy = ProxyController()
    @StateObject private var portForwards = PortForwardController()
    // Location-based background keep-alive, active while a proxy-only session
    // runs (see BackgroundKeepAlive.swift and docs/background-keep-alive.md).
    @StateObject private var keepAlive = BackgroundKeepAlive()

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
    // Remembered across launches: both modes share the config above, so the
    // choice is sticky and only the single CTA's label follows it.
    @AppStorage("lastSessionMode") private var sessionModeRaw = SessionMode.browser.rawValue
    @State private var proxyOnlyActive = false

    private var sessionMode: SessionMode {
        get { SessionMode(rawValue: sessionModeRaw) ?? .browser }
        nonmutating set { sessionModeRaw = newValue.rawValue }
    }

    // Best-effort background keep-alive: buys ~30s of runtime after backgrounding
    // so the SOCKS listener and port forwards outlive a brief app switch.
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    // Set when the background grace expired with nothing holding the process
    // (see the expiration handler): iOS suspended the app and defunct'd the
    // forward listeners, so the next foreground must rebind them.
    @State private var wasSuspended = false

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

                // Both modes share the config above; pick one, and the single
                // CTA below takes its label from the choice.
                Section("Use the tunnel to") {
                    ForEach([SessionMode.browser, .proxyOnly], id: \.rawValue) { mode in
                        ModeChoiceRow(
                            icon: mode.icon,
                            title: mode.title,
                            description: mode.description,
                            isSelected: sessionMode == mode,
                            disabled: proxy.phase == .connecting) {
                            sessionMode = mode
                        }
                    }
                }

                Section {
                    if proxy.phase == .connecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(sessionMode.connectingLabel)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { proxy.stop() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else {
                        Button(sessionMode.cta) {
                            startProxy(mode: sessionMode)
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
            .fullScreenCover(isPresented: proxyOnlyIsPresented) {
                ProxyOnlyView(
                    proxy: proxy,
                    store: portForwards,
                    keepAlive: keepAlive,
                    onStop: {
                        proxy.stop()
                        // Explicitly drop the cover: the binding's setter only
                        // runs on a dismissal attempt, so stopping alone would
                        // leave the screen up showing a dead proxy.
                        proxyOnlyActive = false
                    })
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
                syncKeepAlive()
            }
            .onChange(of: proxyOnlyActive) {
                syncKeepAlive()
            }
            .onChange(of: proxy.socksAlive) {
                syncForwards()
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            .onAppear {
                loadStoredToken()
                syncSessionPresentation()
                syncForwards()
                syncKeepAlive()
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
        // A fresh session starts with every forward off: the CTA never
        // auto-starts tunnels, the user enables what this session needs.
        // (Mid-session reconnects don't come through here, so they keep the
        // toggles as set.)
        portForwards.disableAll()
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
        portForwards.syncProxy(
            socksAlive: proxy.socksAlive,
            socksPort: proxy.socksPort,
            serverNodeID: proxy.connectionSummary?.serverNodeID)
    }

    // MARK: - Background keep-alive

    /// The location keep-alive follows the port-forwarding session: it runs
    /// whenever the proxy-only screen is up with a live SOCKS listener, and
    /// stops with it (so the location indicator never outlives the proxy).
    private func syncKeepAlive() {
        keepAlive.setSessionActive(proxyOnlyActive && proxy.socksPort != nil)
    }

    /// Best-effort fallback: extended execution buys ~30s after backgrounding,
    /// then iOS suspends the process and defuncts its sockets; the next
    /// foreground relaunches the session (see `recoverFromSuspension`).
    /// Port-forwarding sessions get real background persistence from the
    /// location session (`BackgroundKeepAlive`); browser sessions have no
    /// reason to outlive a backgrounded WebView.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard proxy.socksPort != nil, backgroundTask == .invalid else { break }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "flextunnel-proxy") {
                // Grace expired. Unless the location keep-alive is holding the
                // process, iOS suspends it now and defuncts the forward
                // listeners — remember that so the next foreground rebinds them.
                wasSuspended = !keepAlive.isRunning
                endBackgroundTask()
            }
        case .active:
            endBackgroundTask()
            proxy.noteForegrounded()
            if wasSuspended {
                wasSuspended = false
                recoverFromSuspension()
            }
        default:
            break
        }
    }

    /// iOS marks the process's sockets defunct while it is suspended, and the
    /// core can't recover from that on its own: its SOCKS listener keeps
    /// failing `accept()` (retried as transient, so health still reads alive
    /// and the UI shows connected) and its QUIC endpoint can wedge the same
    /// way. Relaunch the session — the same full stop/start a manual
    /// disconnect/connect performs, minus the screen teardown — and rebind the
    /// forward listeners, which were defunct'd with everything else.
    private func recoverFromSuspension() {
        guard proxy.phase == .connected else { return }
        proxy.retryNow()
        portForwards.rebindAfterSuspension()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// A radio-style choice row for one tunnel mode: icon, title, short
/// description, and a trailing selection mark. The CTA lives below the list
/// and takes its label from the selected mode.
private struct ModeChoiceRow: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let disabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                    .padding(.top, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.vertical, 4)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
