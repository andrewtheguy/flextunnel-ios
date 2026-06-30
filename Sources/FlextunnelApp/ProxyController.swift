import Foundation
import Combine

/// Drives the in-process flextunnel SOCKS5 proxy via the Rust FFI
/// (libflextunnel.a). There is no VPN / Network Extension — `start()` spawns the
/// connect/serve loop inside this process and hands back the loopback port that
/// `ProxyWebView` points a WKWebView at.
@MainActor
final class ProxyController: ObservableObject {
    @Published var status: String = "idle"
    @Published var lastError: String?
    /// Loopback SOCKS5 port the core bound (fixed), or nil while stopped.
    @Published var socksPort: UInt16?
    /// Latest healthcheck result: true while the serve loop is alive.
    @Published var healthy: Bool = false
    /// Non-secret settings for the currently running proxy, safe to show in UI.
    @Published private(set) var connectionSummary: ConnectionSummary?

    private var handle: OpaquePointer?
    private var healthTimer: Timer?

    /// Connection parameters entered in the UI.
    struct Settings {
        var serverNodeID: String
        var authToken: String
        var socksPort: UInt16
        var relayURLs: [String]
    }

    struct ConnectionSummary {
        var serverNodeID: String
        var requestedSocksPort: UInt16
        var relayURLs: [String]
        var dnsServer: String?
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
            return
        }

        connectionSummary = ConnectionSummary(
            serverNodeID: s.serverNodeID,
            requestedSocksPort: s.socksPort,
            relayURLs: s.relayURLs,
            dnsServer: nil)
        socksPort = UInt16(port)
        healthy = true
        status = "running on 127.0.0.1:\(port)"
        startHealthPolling()
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let handle {
            flextunnel_stop(handle)
            self.handle = nil
        }
        socksPort = nil
        healthy = false
        connectionSummary = nil
        if status != "error" { status = "idle" }
    }

    // MARK: - Healthcheck

    /// Poll the core's liveness probe so the UI reflects a tunnel that gave up
    /// (e.g. bad node id / auth / unreachable server) instead of silently
    /// looking "running".
    private func startHealthPolling() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    private func checkHealth() {
        guard let handle else { return }
        switch flextunnel_health(handle) {
        case 1:
            healthy = true
        case 0:
            // The serve loop ended. Surface it and stop polling; the handle stays
            // valid until the user taps Stop.
            healthy = false
            status = "stopped — tunnel ended (check server id / auth / reachability)"
            healthTimer?.invalidate()
            healthTimer = nil
        default:
            healthy = false
        }
    }

    deinit {
        healthTimer?.invalidate()
        if let handle { flextunnel_stop(handle) }
    }
}
