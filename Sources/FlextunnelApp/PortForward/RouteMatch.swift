import Foundation
import Network

/// Advisory-only mirror of the core's split-tunnel decision, used to badge a
/// forward target as tunneled or direct. The core (and the server) remain the
/// authority; a mismatch here mislabels a badge, nothing more.
enum RouteMatch {
    /// Whether `host` (hostname or IP literal) falls in the routed tunnel set.
    static func isTunneled(host: String, routes: ProxyController.ForwardedRoutes) -> Bool {
        if routes.isFullTunnel { return true }
        let normalized = host.lowercased()

        // IP literals are gated by CIDRs, never by domain wildcards — same rule
        // as the core's RoutedSet.
        if let ip = IPv4Address(normalized) {
            return routes.cidrs.contains { cidrContains($0, ip) }
        }
        if IPv6Address(normalized) != nil {
            // Non-catch-all IPv6 CIDR matching is skipped; the badge is advisory.
            return false
        }

        return routes.domains.contains { pattern in
            let pattern = pattern.lowercased()
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                return normalized == suffix || normalized.hasSuffix("." + suffix)
            }
            return normalized == pattern
        }
    }

    /// IPv4 CIDR containment (`10.0.0.0/8`); a bare IP matches as /32.
    private static func cidrContains(_ cidr: String, _ ip: IPv4Address) -> Bool {
        let parts = cidr.split(separator: "/")
        guard let first = parts.first, let base = IPv4Address(String(first)) else { return false }
        let bits: UInt32
        switch parts.count {
        case 1: bits = 32
        case 2:
            guard let parsed = UInt32(parts[1]), parsed <= 32 else { return false }
            bits = parsed
        default: return false
        }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return (value(of: base) & mask) == (value(of: ip) & mask)
    }

    private static func value(of ip: IPv4Address) -> UInt32 {
        ip.rawValue.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}
