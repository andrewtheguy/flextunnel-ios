import Foundation

/// A local TCP port forward: connections accepted on 127.0.0.1:`localPort` are
/// relayed to `remoteHost:remotePort` through the in-app SOCKS5 listener, so the
/// core applies the same split-tunnel routing as the browser (on-list targets go
/// through the tunnel, off-list targets are dialed directly).
struct PortForward: Identifiable, Codable, Equatable {
    let id: UUID
    /// Optional display name; empty shows the target instead.
    var label: String
    var localPort: UInt16
    /// Hostname or IP literal. Kept a string end-to-end so hostnames reach the
    /// SOCKS proxy unresolved and DNS happens on the flextunnel server.
    var remoteHost: String
    var remotePort: UInt16
    /// Runtime-only by design: the start/stop toggle is per-session, so it is
    /// excluded from persistence (see `CodingKeys`) and every launch loads the
    /// forward switched off.
    var enabled: Bool = false

    /// Everything but `enabled` — what a forward *is* persists; whether it is
    /// running does not.
    private enum CodingKeys: String, CodingKey {
        case id, label, localPort, remoteHost, remotePort
    }

    init(
        id: UUID = UUID(),
        label: String = "",
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16,
        enabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.enabled = enabled
    }

    var displayName: String {
        label.isEmpty ? "\(remoteHost):\(remotePort)" : label
    }

    var routeDescription: String {
        "localhost:\(localPort) → \(remoteHost):\(remotePort)"
    }
}
