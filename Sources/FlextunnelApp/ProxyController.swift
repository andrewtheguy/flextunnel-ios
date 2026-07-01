import Foundation
import Combine

/// Drives the in-process flextunnel SOCKS5 proxy via the Rust FFI
/// (libflextunnel.a). There is no VPN / Network Extension — `start()` spawns the
/// connect/serve loop inside this process and hands back the loopback port that
/// `ProxyWebView` points a WKWebView at.
@MainActor
final class ProxyController: ObservableObject {
    /// Lifecycle phase. Drives whether the browser is presented: it appears once
    /// we reach `.connected` (the first handshake landed). Because the core keeps
    /// the SOCKS5 listener serving and reconnects the tunnel on its own across
    /// drops, the browser then stays presented until an explicit quit.
    enum Phase: Equatable {
        case idle
        /// Initial connect attempt (no browser presented yet).
        case connecting
        /// Handshake landed at least once; browser is presented.
        case connected
        /// Initial connect failed (terminal; shown on the setup screen).
        case failed
    }

    @Published var status: String = "idle"
    @Published var lastError: String?
    /// Current lifecycle phase; drives whether the browser is presented.
    @Published private(set) var phase: Phase = .idle
    /// Loopback SOCKS5 port the core bound (fixed), or nil while stopped.
    @Published var socksPort: UInt16?
    /// The SOCKS5 serve loop is alive (FFI health == 1). This — not the tunnel
    /// link — gates browsing: while it's up, off-list targets connect directly
    /// even if the tunnel is down.
    @Published var socksAlive: Bool = false
    /// The tunnel link to the server is up (handshake live). On-list targets (in
    /// the routed tunnel set) only work while this is true; off-list targets don't.
    @Published var tunnelConnected: Bool = false
    /// Non-secret settings for the currently running proxy, safe to show in UI.
    @Published private(set) var connectionSummary: ConnectionSummary?
    /// The tunnel set the server pushed: domains/CIDRs routed through the tunnel.
    /// Nil until the first handshake; retained across drops by the core.
    @Published private(set) var forwardedRoutes: ForwardedRoutes?

    private var handle: OpaquePointer?
    private var healthTimer: Timer?
    /// Give up on a stalled first handshake after this long.
    private static let connectTimeout: TimeInterval = 20
    private var connectDeadline: Date?
    /// Last settings that drove a launch, replayed by the manual Reconnect.
    private var lastSettings: Settings?

    /// Connection parameters entered in the UI.
    struct Settings {
        var serverNodeID: String
        var authToken: String
        var socksPort: UInt16
        var relayURLs: [String]
    }

    struct ConnectionSummary {
        var serverNodeID: String
        var relayURLs: [String]
        var dnsServer: String?
    }

    /// The tunnel set as reported by the core: the domains/CIDRs routed through
    /// the tunnel (off-list targets connect directly). The set is required, so it
    /// is never empty once connected.
    struct ForwardedRoutes {
        var connected: Bool
        var domains: [String]
        var cidrs: [String]

        /// A `*` domain or a default-route CIDR means everything is tunneled, so a
        /// tunnel drop is a full outage (nothing is off-list to browse directly).
        var isFullTunnel: Bool {
            domains.contains("*") || cidrs.contains { $0 == "0.0.0.0/0" || $0 == "::/0" }
        }
    }

    /// True when everything is routed through the tunnel (full-tunnel set), so a
    /// drop leaves nothing to browse directly.
    var isFullTunnel: Bool { forwardedRoutes?.isFullTunnel ?? false }

    /// Whether the browser is usable right now. Fails closed to match the core,
    /// which routes nothing until the first handshake learns the tunnel set: the
    /// SOCKS5 listener must be up and either the tunnel is connected or the route
    /// policy is known to be a partial split (off-list targets browse directly).
    /// While `forwardedRoutes` is still nil (pre-handshake or mid-relaunch) or the
    /// set is full-tunnel while the link is down, browsing stays blocked.
    var canBrowse: Bool {
        guard socksAlive else { return false }
        if tunnelConnected { return true }
        guard let routes = forwardedRoutes else { return false }
        return !routes.isFullTunnel
    }

    init() {
        flextunnel_init_logging()
    }

    /// User-initiated start (also the manual Reconnect target). Builds the FFI
    /// config, starts the proxy, and publishes the bound port.
    func start(_ s: Settings) {
        lastSettings = s
        lastError = nil
        teardownHandle() // tear down any previous handle first

        let configDict: [String: Any] = [
            "server_node_id": s.serverNodeID,
            "auth_token": s.authToken,
            "socks_port": Int(s.socksPort),
            "relay_urls": s.relayURLs,
            "dns_server": NSNull(),
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: configDict),
            let configStr = String(data: data, encoding: .utf8)
        else {
            fail("failed to encode config JSON")
            return
        }

        var buf = [CChar](repeating: 0, count: 1024)
        let handle = configStr.withCString { cstr in
            flextunnel_start(cstr, &buf, buf.count)
        }
        let resultStr = String(cString: buf)

        guard let handle else {
            fail("start failed: \(resultStr)")
            return
        }
        self.handle = handle

        guard
            let resultData = resultStr.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
            let port = obj["socks_port"] as? Int, (1...65535).contains(port)
        else {
            flextunnel_stop(handle)
            self.handle = nil
            fail("bad result JSON: \(resultStr)")
            return
        }

        connectionSummary = ConnectionSummary(
            serverNodeID: s.serverNodeID,
            relayURLs: s.relayURLs,
            dnsServer: nil)
        socksPort = UInt16(port)
        // Not usable yet: the handle only means the listener bound and the connect
        // loop spawned. Stay in `.connecting` until the first handshake lands.
        socksAlive = false
        tunnelConnected = false
        phase = .connecting
        connectDeadline = Date().addingTimeInterval(Self.connectTimeout)
        status = "connecting to server…"
        startHealthPolling()
    }

    /// Explicit user quit: fully tear down.
    func stop() {
        connectDeadline = nil
        teardownHandle()
        phase = .idle
        status = "idle"
    }

    /// Manual reconnect. Only needed if the proxy fully died — the core
    /// reconnects the tunnel link on its own — so this relaunches the session.
    func retryNow() {
        guard let lastSettings else { return }
        start(lastSettings)
    }

    private func stopPolling() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Stop the FFI handle and polling and clear per-session state.
    private func teardownHandle() {
        stopPolling()
        connectDeadline = nil
        if let handle {
            flextunnel_stop(handle)
            self.handle = nil
        }
        socksPort = nil
        socksAlive = false
        tunnelConnected = false
        connectionSummary = nil
        forwardedRoutes = nil
    }

    /// Terminal initial-connect failure: surfaced on the setup screen.
    private func fail(_ reason: String) {
        teardownHandle()
        phase = .failed
        status = reason
        if lastError == nil { lastError = reason }
    }

    // MARK: - Healthcheck

    private func startHealthPolling() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll() // first read without waiting a full interval
    }

    private func poll() {
        guard let handle else { return }

        // health == 0 means the serve loop ended. Before the first connect that's
        // a fatal initial failure; after, the whole proxy died (rare — the core
        // keeps the loop alive and retries the tunnel across drops).
        if flextunnel_health(handle) == 0 {
            switch phase {
            case .connecting:
                fail("couldn't connect — check server id / auth / reachability")
            case .connected:
                // Proxy died; keep the browser mounted but mark it unusable so the
                // popover can offer a manual Reconnect.
                socksAlive = false
                tunnelConnected = false
                status = "proxy stopped — tap Reconnect"
                stopPolling()
            case .idle, .failed:
                break
            }
            return
        }

        socksAlive = true
        refreshRoutes()
        tunnelConnected = forwardedRoutes?.connected == true

        switch phase {
        case .connecting:
            if tunnelConnected {
                phase = .connected
                status = connectedStatus
            } else if let deadline = connectDeadline, Date() >= deadline {
                fail("timed out connecting — check server id / auth / reachability")
            }
        case .connected:
            // A tunnel-link drop is not a failure: the core keeps SOCKS5 serving
            // (off-list still browses) and reconnects on its own. Reflect the link
            // state; on-list targets fail per-tab until it recovers.
            status = tunnelConnected
                ? connectedStatus
                : "tunnel reconnecting — off-list browsing active"
        case .idle, .failed:
            break
        }
    }

    private var connectedStatus: String {
        "connected on 127.0.0.1:\(socksPort.map(String.init) ?? "?")"
    }

    /// Poll the core for the tunnel set learned during the handshake. It rides the
    /// handshake response, so a generous buffer is used.
    private func refreshRoutes() {
        guard let handle else { return }
        var buf = [CChar](repeating: 0, count: 64 * 1024)
        guard flextunnel_routes(handle, &buf, buf.count) == 1 else { return }
        guard
            let data = String(cString: buf).data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        forwardedRoutes = ForwardedRoutes(
            connected: obj["connected"] as? Bool ?? false,
            domains: obj["domains"] as? [String] ?? [],
            cidrs: obj["cidrs"] as? [String] ?? [])
    }

    deinit {
        healthTimer?.invalidate()
        if let handle { flextunnel_stop(handle) }
    }
}
