import Foundation
import Combine

/// Drives the in-process flextunnel SOCKS5 proxy via the Rust FFI
/// (libflextunnel.a). There is no VPN / Network Extension — `start()` spawns the
/// connect/serve loop inside this process and hands back the loopback port that
/// `ProxyWebView` points a WKWebView at.
@MainActor
final class ProxyController: ObservableObject {
    /// Where the tunnel is in its lifecycle. The browser is only shown, and the
    /// status icon only goes green, once we reach `.connected` — i.e. the server
    /// handshake actually completed. `flextunnel_start` returning a handle only
    /// means the SOCKS listener bound and the connect loop was spawned; auth and
    /// signaling happen asynchronously afterwards, so treating that as success
    /// flashes a working browser that then vanishes when the connect fails.
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed
    }

    @Published var status: String = "idle"
    @Published var lastError: String?
    /// Current lifecycle phase; drives whether the browser is presented.
    @Published private(set) var phase: Phase = .idle
    /// Loopback SOCKS5 port the core bound (fixed), or nil while stopped.
    @Published var socksPort: UInt16?
    /// True only once the handshake completed and the serve loop is still alive.
    /// Gates the browser and the green status icon.
    @Published var healthy: Bool = false
    /// Non-secret settings for the currently running proxy, safe to show in UI.
    @Published private(set) var connectionSummary: ConnectionSummary?
    /// Split-tunnel set the server pushed: domains/CIDRs routed through the
    /// tunnel. Nil until the handshake completes; populated by polling.
    @Published private(set) var forwardedRoutes: ForwardedRoutes?

    private var handle: OpaquePointer?
    private var healthTimer: Timer?
    /// Give up on a stalled handshake after this long. `flextunnel_health` flips
    /// to 0 quickly on a fatal connect error, so this is only a backstop for a
    /// connect that hangs without ever failing outright.
    private static let connectTimeout: TimeInterval = 20
    private var connectDeadline: Date?

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

    /// The tunnel's forwarding set as reported by the core. An empty domains +
    /// cidrs while `connected` means the server runs no whitelist (everything is
    /// tunneled).
    struct ForwardedRoutes {
        var connected: Bool
        var domains: [String]
        var cidrs: [String]

        var isWhitelistActive: Bool { !domains.isEmpty || !cidrs.isEmpty }
    }

    init() {
        flextunnel_init_logging()
    }

    /// Build the FFI config JSON, start the proxy, and publish the bound port.
    func start(_ s: Settings) {
        lastError = nil
        stop() // tear down any previous session first

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
            lastError = "failed to encode config JSON"
            return
        }

        var buf = [CChar](repeating: 0, count: 1024)
        let handle = configStr.withCString { cstr in
            flextunnel_start(cstr, &buf, buf.count)
        }
        let resultStr = String(cString: buf)

        guard let handle else {
            lastError = "start failed: \(resultStr)"
            status = "error"
            phase = .failed
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
            lastError = "bad result JSON: \(resultStr)"
            status = "error"
            phase = .failed
            return
        }

        connectionSummary = ConnectionSummary(
            serverNodeID: s.serverNodeID,
            relayURLs: s.relayURLs,
            dnsServer: nil)
        socksPort = UInt16(port)
        // Not healthy yet: the handle only means the listener bound and the
        // connect loop spawned. Stay in `.connecting` until the handshake lands.
        healthy = false
        phase = .connecting
        connectDeadline = Date().addingTimeInterval(Self.connectTimeout)
        status = "connecting to server…"
        startHealthPolling()
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        connectDeadline = nil
        if let handle {
            flextunnel_stop(handle)
            self.handle = nil
        }
        socksPort = nil
        healthy = false
        phase = .idle
        connectionSummary = nil
        forwardedRoutes = nil
        if status != "error" { status = "idle" }
    }

    // MARK: - Healthcheck

    /// Poll the core so the UI tracks the real handshake: promote `.connecting`
    /// to `.connected` only once the tunnel reports connected, and surface a
    /// tunnel that gave up (bad node id / auth / unreachable server) instead of
    /// silently looking "running".
    private func startHealthPolling() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll() // first read without waiting a full interval
    }

    private func poll() {
        guard let handle else { return }

        // A dead serve loop is fatal in any phase: the connect gave up.
        if flextunnel_health(handle) == 0 {
            fail(phase == .connecting
                ? "couldn't connect — check server id / auth / reachability"
                : "tunnel ended — check server id / auth / reachability")
            return
        }

        refreshRoutes()
        let isConnected = forwardedRoutes?.connected == true

        switch phase {
        case .connecting:
            if isConnected {
                phase = .connected
                healthy = true
                status = "connected on 127.0.0.1:\(socksPort.map(String.init) ?? "?")"
            } else if let deadline = connectDeadline, Date() >= deadline {
                fail("timed out connecting — check server id / auth / reachability")
            }
        case .connected:
            // Handshake done; keep the liveness flag in sync so a later drop is
            // reflected (and tears the browser down) instead of looking healthy.
            healthy = isConnected
        case .idle, .failed:
            break
        }
    }

    /// Mark the session failed, stop polling, and surface the reason. The handle
    /// stays valid (so status stays inspectable) until the user taps Stop.
    private func fail(_ message: String) {
        healthy = false
        phase = .failed
        status = message
        if lastError == nil { lastError = message }
        healthTimer?.invalidate()
        healthTimer = nil
        connectDeadline = nil
    }

    /// Poll the core for the split-tunnel set learned during the handshake. The
    /// whitelist rides the handshake response, so a generous buffer is used.
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
