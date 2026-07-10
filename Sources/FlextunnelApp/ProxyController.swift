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
    /// Loopback SOCKS5 port the core actually bound, or nil while stopped. In
    /// browser mode this is a per-session random port (fixed for the session so
    /// it survives reconnects); in proxy-only mode it is the fixed port the user
    /// chose (shown so other apps can point at it).
    @Published var socksPort: UInt16?
    /// The SOCKS5 serve loop is alive (FFI health == 1). Only tunnel-set hosts
    /// depend on it: the browser splits at the connection layer (WebKit
    /// `matchDomains`), so off-list browsing works regardless of proxy health.
    @Published var socksAlive: Bool = false
    /// The tunnel link to the server is up (handshake live). On-list targets (in
    /// the routed tunnel set) only work while this is true; off-list targets don't.
    @Published var tunnelConnected: Bool = false
    /// The tunnel link has been down for longer than `reconnectGrace` while the
    /// SOCKS loop stayed alive: the core's own reconnect is presumed stuck, so
    /// the UI shows a disconnected state and offers a manual Retry.
    @Published private(set) var tunnelStuck: Bool = false
    /// Non-secret settings for the currently running proxy, safe to show in UI.
    @Published private(set) var connectionSummary: ConnectionSummary?
    /// The tunnel set the server pushed: domains/CIDRs routed through the tunnel.
    /// Nil until the first handshake; retained across drops by the core.
    @Published private(set) var forwardedRoutes: ForwardedRoutes?

    /// Called (on the main actor) from the poll loop when the Live-Activity-
    /// relevant state changes while the app is backgrounded with keep-alive — the
    /// hook `ContentView` uses to refresh the banner without SwiftUI's `.onChange`
    /// (which doesn't fire while backgrounded). Only invoked while
    /// `backgroundLiveActivityRefreshEnabled` is set.
    var onBackgroundLiveActivityRefresh: (() -> Void)?
    /// Set by `ContentView` while the app is in the background AND the keep-alive
    /// session is holding the process; gates `onBackgroundLiveActivityRefresh`.
    /// Clearing it resets the keep-alive refresh clock so the next background
    /// stint re-arms immediately.
    var backgroundLiveActivityRefreshEnabled = false {
        didSet { if !backgroundLiveActivityRefreshEnabled { lastBackgroundRefresh = nil } }
    }
    /// When the background Live Activity was last refreshed, so a periodic
    /// re-arm keeps its `staleDate` in the future while the app stays alive (even
    /// with no state change); nil until the first background refresh.
    private var lastBackgroundRefresh: Date?
    /// Re-arm cadence for the background refresh — shorter than the Live
    /// Activity's stale window (`LiveActivityController.staleAfter`, 90s) so the
    /// banner never falsely reads stale while the app is genuinely running, yet
    /// still goes stale within ~90s if the app actually stops updating.
    private static let backgroundRefreshInterval: TimeInterval = 60

    /// The subset of state the Live Activity reflects; compared across a poll to
    /// detect a meaningful change worth pushing to the banner.
    private struct LiveActivityState: Equatable {
        let phase: Phase
        let socksAlive: Bool
        let tunnelConnected: Bool
        let tunnelStuck: Bool
    }
    private var liveActivityState: LiveActivityState {
        LiveActivityState(
            phase: phase,
            socksAlive: socksAlive,
            tunnelConnected: tunnelConnected,
            tunnelStuck: tunnelStuck)
    }

    private var handle: OpaquePointer?
    private var healthTimer: Timer?
    /// Give up on a stalled first handshake after this long.
    private static let connectTimeout: TimeInterval = 20
    private var connectDeadline: Date?
    /// When the tunnel link dropped while connected; nil while the link is up.
    private var linkDownSince: Date?
    /// A link down longer than this stops reading as a transient reconnect.
    private static let reconnectGrace: TimeInterval = 30
    /// Last settings that drove a launch, replayed by the manual Reconnect.
    private var lastSettings: Settings?

    /// Connection parameters entered in the UI.
    struct Settings {
        var serverNodeID: String
        var authToken: String
        /// Loopback port for the SOCKS5 listener. Browser mode passes a random
        /// per-session port (kept internal); proxy-only mode passes a fixed,
        /// user-chosen port other apps on the device point at. `0` (OS-assigned
        /// ephemeral) is only a pre-session fallback.
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
        /// Server-side host aliases (`alias -> target`), informational only —
        /// the server resolves them; shown in the status popover like the
        /// server status page shows them.
        var hostAliases: [(alias: String, target: String)]
        /// Reverse-routing (agent) routes, informational only. Each carries a
        /// live connection status the core refreshes over the heartbeat.
        var agentRoutes: [AgentRoute]
        /// Server-side conditional DNS forwards (split-DNS), informational only —
        /// names under `suffix` resolve via `servers` on the server side; shown
        /// in the status popover like the server status page shows them.
        var dnsForwards: [(suffix: String, servers: [String])]
        /// Server-to-server bridge routes, informational only — targets matching
        /// a bridge's domains/CIDRs are forwarded to another flextunnel server.
        /// The rules are already part of the routed set, so nothing is enforced
        /// caller-side; shown in the status popover like the server status page.
        var bridges: [BridgeRoute]

        /// A `*` domain or a default-route CIDR means everything is tunneled, so a
        /// tunnel drop is a full outage (nothing is off-list to browse directly).
        var isFullTunnel: Bool {
            domains.contains("*") || cidrs.contains { $0 == "0.0.0.0/0" || $0 == "::/0" }
        }

        /// Host patterns for WebKit-level split-tunneling
        /// (`ProxyConfiguration.matchDomains`): matching hosts go through the
        /// SOCKS5 proxy, everything else connects directly from the network
        /// process (local DNS, HTTP/3, no loopback hop). Nil means the whole
        /// optimization is off and every host goes through the proxy — required
        /// when the set is full-tunnel or routes CIDRs, which hostname patterns
        /// can't express (an IP-literal URL must still reach the proxy's CIDR
        /// check).
        ///
        /// WebKit suffix-matches each entry (apex + all subdomains), a superset
        /// of the core's exact/`*.` rules, so both rule forms map to the bare
        /// domain. Over-matching is safe: the local proxy's routed set makes the
        /// exact tunnel-vs-direct call for whatever reaches it. Under-matching
        /// would break private hosts, so the list must cover everything the core
        /// would tunnel — including the always-tunneled `flextunnel.internal`
        /// namespace.
        var proxyMatchDomains: [String]? {
            guard !isFullTunnel, cidrs.isEmpty else { return nil }
            var bases = Set(domains.map { domain in
                domain.hasPrefix("*.") ? String(domain.dropFirst(2)).lowercased() : domain.lowercased()
            })
            bases.insert("flextunnel.internal")
            return bases.sorted()
        }
    }

    /// A single connection-path snapshot — one iroh path to the server — for the
    /// on-demand "connection path" readout. Mirrors the desktop's `ConnPath` and
    /// `ezvpn client status`; produced by `queryConnPath()`.
    struct ConnPath: Identifiable {
        /// Stable synthetic identity = the path's index in the snapshot. `display`
        /// can't be the id: it embeds the RTT, so it churns every refresh for the
        /// same path (breaking `ForEach` row identity) and two paths could collide.
        let id: Int
        var kind: Kind
        /// Human line like `Direct 1.2.3.4:52186 (rtt 1ms)` or
        /// `Relay https://… (rtt 42ms)`.
        var display: String
        /// Whether iroh currently routes traffic over this path.
        var selected: Bool

        enum Kind: String {
            case direct, relay, other

            /// Parse the FFI JSON token, defaulting to `.other` for anything
            /// unrecognized (a missing/old field or a future value).
            init(token: String?) {
                self = token.flatMap(Kind.init(rawValue:)) ?? .other
            }
        }
    }

    /// A reverse-routing (agent) alias plus the backing agent's live connection
    /// status as the core reports it: `connected`, `disconnected`, or `unknown`
    /// (the last when the tunnel is down or the heartbeat-fed view is stale).
    struct AgentRoute: Identifiable {
        var name: String
        var status: Status

        var id: String { name }

        enum Status: String {
            case connected, disconnected, unknown

            /// Parse the FFI JSON token, defaulting to `.unknown` for anything
            /// unrecognized (a missing/old field or a future value).
            init(token: String?) {
                self = token.flatMap(Status.init(rawValue:)) ?? .unknown
            }
        }
    }

    /// A server-to-server bridge route: targets matching `domains`/`cidrs` are
    /// forwarded to another flextunnel server (identified by `endpointID`).
    /// Informational only — the rules are already part of the routed set.
    struct BridgeRoute: Identifiable {
        var name: String
        var endpointID: String
        var domains: [String]
        var cidrs: [String]

        var id: String { name }

        /// A structured, multi-line summary for the status views: the bridge name,
        /// then its endpoint id and the routed domains/CIDRs as bulleted lists.
        var summary: String {
            var lines = ["\(name):", "  endpoint id: \(endpointID)"]
            if !domains.isEmpty {
                lines.append("  routed domains:")
                lines.append(contentsOf: domains.map { "    - \($0)" })
            }
            if !cidrs.isEmpty {
                lines.append("  routed CIDRs:")
                lines.append(contentsOf: cidrs.map { "    - \($0)" })
            }
            return lines.joined(separator: "\n")
        }
    }

    /// True when everything is routed through the tunnel (full-tunnel set), so a
    /// drop leaves nothing to browse directly.
    var isFullTunnel: Bool { forwardedRoutes?.isFullTunnel ?? false }

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
            // A fixed loopback port: a per-session random port in browser mode, the
            // user's chosen port in proxy-only mode. The core returns the actual
            // bound port below.
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

    /// Called on return to foreground. `connectDeadline` is wall-clock, so time
    /// spent suspended would count against a still-pending first connect and
    /// fail it spuriously on the first resumed poll; grant a fresh window.
    func noteForegrounded() {
        if phase == .connecting, connectDeadline != nil {
            connectDeadline = Date().addingTimeInterval(Self.connectTimeout)
        }
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
        linkDownSince = nil
        tunnelStuck = false
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

        // While the location keep-alive holds the app in the background, SwiftUI
        // stops firing the `.onChange` handlers that refresh the Live Activity —
        // so drive it from this poll (which keeps running under keep-alive)
        // instead: snapshot the banner-relevant state and, if it changed this
        // tick, ask `ContentView` to re-sync. Gated to the background+keep-alive
        // case so it never fights the foreground `.onChange` path.
        let liveStateBefore = liveActivityState
        defer {
            if backgroundLiveActivityRefreshEnabled {
                let changed = liveActivityState != liveStateBefore
                let elapsed = lastBackgroundRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
                // Refresh on a real change, or periodically to re-arm the stale
                // window so the banner stays fresh while the app is alive.
                if changed || elapsed >= Self.backgroundRefreshInterval {
                    lastBackgroundRefresh = Date()
                    onBackgroundLiveActivityRefresh?()
                }
            }
        }

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
                linkDownSince = nil
                tunnelStuck = false
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
        trackLinkOutage()

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
            if tunnelConnected {
                status = connectedStatus
            } else if tunnelStuck {
                status = "tunnel disconnected — retry to relaunch"
            } else {
                status = "tunnel reconnecting — off-list browsing active"
            }
        case .idle, .failed:
            break
        }
    }

    /// Track how long the tunnel link has been down while connected. Within the
    /// grace window a drop reads as "reconnecting" (the core retries on its own);
    /// past it the reconnect is presumed stuck and `tunnelStuck` flips the UI to
    /// a disconnected state offering a manual Retry. Time spent suspended counts
    /// on purpose: a link that died hours ago in the background should surface as
    /// disconnected on resume, not spin as "reconnecting".
    private func trackLinkOutage() {
        guard phase == .connected, !tunnelConnected else {
            linkDownSince = nil
            tunnelStuck = false
            return
        }
        let downSince = linkDownSince ?? Date()
        linkDownSince = downSince
        tunnelStuck = Date().timeIntervalSince(downSince) >= Self.reconnectGrace
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

        // host_aliases is a JSON array of [alias, target] pairs.
        let hostAliases = (obj["host_aliases"] as? [[String]] ?? [])
            .compactMap { pair -> (alias: String, target: String)? in
                pair.count == 2 ? (alias: pair[0], target: pair[1]) : nil
            }
        // agent_aliases is a JSON array of {"name","status"} objects.
        let agentRoutes = (obj["agent_aliases"] as? [[String: Any]] ?? [])
            .compactMap { entry -> AgentRoute? in
                guard let name = entry["name"] as? String else { return nil }
                return AgentRoute(
                    name: name,
                    status: .init(token: entry["status"] as? String))
            }
        // dns_forwards is a JSON array of {"suffix","servers"} objects.
        let dnsForwards = (obj["dns_forwards"] as? [[String: Any]] ?? [])
            .compactMap { entry -> (suffix: String, servers: [String])? in
                guard let suffix = entry["suffix"] as? String else { return nil }
                return (suffix: suffix, servers: entry["servers"] as? [String] ?? [])
            }
        // bridges is a JSON array of {"name","endpoint_id","domains","cidrs"}.
        let bridges = (obj["bridges"] as? [[String: Any]] ?? [])
            .compactMap { entry -> BridgeRoute? in
                guard let name = entry["name"] as? String else { return nil }
                return BridgeRoute(
                    name: name,
                    endpointID: entry["endpoint_id"] as? String ?? "",
                    domains: entry["domains"] as? [String] ?? [],
                    cidrs: entry["cidrs"] as? [String] ?? [])
            }
        forwardedRoutes = ForwardedRoutes(
            connected: obj["connected"] as? Bool ?? false,
            domains: obj["domains"] as? [String] ?? [],
            cidrs: obj["cidrs"] as? [String] ?? [],
            hostAliases: hostAliases,
            agentRoutes: agentRoutes,
            dnsForwards: dnsForwards,
            bridges: bridges)
    }

    /// One-shot snapshot of the live connection's iroh path(s) — a point-in-time
    /// readout (relay/direct) for the "connection path" status sheet, mirroring
    /// the desktop CTA. Empty while the tunnel link is down (the core routes over
    /// no path then), so callers only offer it while `tunnelConnected`.
    func queryConnPath() -> [ConnPath] {
        guard let handle else { return [] }
        var buf = [CChar](repeating: 0, count: 8 * 1024)
        guard flextunnel_conn_path(handle, &buf, buf.count) == 1 else { return [] }
        guard
            let data = String(cString: buf).data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let paths = obj["paths"] as? [[String: Any]]
        else { return [] }
        return paths.enumerated().compactMap { index, entry in
            guard let display = entry["display"] as? String else { return nil }
            return ConnPath(
                id: index,
                kind: .init(token: entry["kind"] as? String),
                display: display,
                selected: entry["selected"] as? Bool ?? false)
        }
    }

    deinit {
        healthTimer?.invalidate()
        if let handle { flextunnel_stop(handle) }
    }
}
