import SwiftUI

/// Flextunnel is a private-network access browser: it reaches private resources
/// through the flextunnel SOCKS5 tunnel, split-tunnel by default (traffic to
/// off-list resources bypasses the proxy) with the option to route all traffic
/// through it. It behaves like a mainstream browser plus private-resource access
/// — not a privacy/anonymity browser. Only resources in the server's routed
/// tunnel set are tunneled, which is where its access protection applies.
@main
struct FlextunnelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
