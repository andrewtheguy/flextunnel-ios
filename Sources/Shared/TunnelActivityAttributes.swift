import ActivityKit
import Foundation

/// Live Activity model, compiled into both the app (which starts/updates/ends the
/// activity) and the widget extension (which renders it). Purely a status
/// surface — it does not extend background runtime; it just shows the last-known
/// tunnel state on the lock screen / Dynamic Island so the session is glanceable.
struct TunnelActivityAttributes: ActivityAttributes {
    /// Dynamic part: refreshed while the app runs (foreground or its brief
    /// background window). When the app is suspended it shows the last value.
    struct ContentState: Codable, Hashable {
        /// Tunnel link to the server is up (on-list targets reachable).
        var tunnelConnected: Bool
        /// SOCKS5 listener is serving (off-list browsing works even if the link
        /// is down).
        var socksAlive: Bool
        /// Short human status, e.g. "Connected" / "Reconnecting…".
        var statusText: String
    }

    /// Static part: fixed for the life of the activity. The title is always
    /// "Flextunnel" (hardcoded in the widget); this is the helpful line under
    /// it, e.g. "SOCKS proxy on localhost:18080".
    var subtitle: String
}
