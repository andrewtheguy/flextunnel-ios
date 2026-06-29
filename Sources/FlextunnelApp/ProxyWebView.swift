import SwiftUI
import WebKit
import Network
import os.log

/// A WKWebView whose traffic is routed through the in-app flextunnel SOCKS5
/// listener at 127.0.0.1:<socksPort> using `WKWebsiteDataStore.proxyConfigurations`
/// (iOS 17+). No system proxy change and no VPN: only this web view is proxied.
///
/// SOCKS5 passes the hostname to the proxy (ATYP_DOMAIN), so DNS is resolved on
/// the flextunnel **server**, not the device — the same mechanism that lets
/// Onion Browser resolve `.onion` names through Tor's local SOCKS proxy.
struct ProxyWebView: UIViewRepresentable {
    let socksPort: UInt16
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: socksPort)!)
        let proxy = ProxyConfiguration(socksv5Proxy: endpoint)

        // A dedicated, non-persistent store so the proxy applies cleanly and no
        // unproxied cache leaks in. proxyConfigurations is iOS 17+.
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]

        let config = WKWebViewConfiguration()
        config.websiteDataStore = store

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.log.info("loading \(url.absoluteString, privacy: .public) via SOCKS5 127.0.0.1:\(socksPort)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reload only when the requested URL actually changes.
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    /// Logs navigation outcomes to the unified log (subsystem
    /// `com.example.flextunnel`, category `webview`). A load that fails to reach
    /// the proxy surfaces here as `didFail*` with an NSURLError — the signal that
    /// distinguishes "proxy unreachable" from "proxy bypassed (loaded direct)".
    final class Coordinator: NSObject, WKNavigationDelegate {
        let log = Logger(subsystem: "com.example.flextunnel", category: "webview")

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log.info("didFinish \(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            log.error("didFail: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            log.error("didFailProvisional: \(error.localizedDescription, privacy: .public)")
        }
    }
}
