import Foundation
import Network
import Observation
import WebKit
import os.log

/// A single browser tab: an iOS 26 `WebPage` whose traffic is routed through the
/// in-app flextunnel SOCKS5 listener at 127.0.0.1:<socksPort> via
/// `WebPage.Configuration.websiteDataStore.proxyConfigurations`.
///
/// SOCKS5 passes the hostname to the proxy (ATYP_DOMAIN), so DNS is resolved on
/// the flextunnel **server**, not the device — the same mechanism that lets Onion
/// Browser resolve `.onion` names through Tor's local SOCKS proxy.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let page: WebPage

    /// Surfaces the last navigation failure (e.g. proxy unreachable). The key
    /// POC signal that distinguishes "proxy reachable" from a failed/bypassed load.
    var lastError: String?

    private let log = Logger(subsystem: "com.example.flextunnel", category: "webview")

    private init(page: WebPage) {
        self.page = page
    }

    /// Build a tab whose `WebPage` is proxied through the loopback SOCKS5 listener.
    /// A dedicated non-persistent data store keeps the proxy applied cleanly and
    /// avoids any unproxied cache leaking in.
    static func make(socksPort: UInt16) -> BrowserTab {
        var config = WebPage.Configuration()
        config.websiteDataStore = .nonPersistent()

        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: socksPort)!)
        config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]

        return BrowserTab(page: WebPage(configuration: config))
    }

    // MARK: - Derived state (reads WebPage's @Observable properties)

    /// Page title, falling back to the host, then a placeholder.
    var displayTitle: String {
        let title = page.title
        if !title.isEmpty { return title }
        if let host = page.url?.host() { return host }
        return "New Tab"
    }

    var canGoBack: Bool { !page.backForwardList.backList.isEmpty }
    var canGoForward: Bool { !page.backForwardList.forwardList.isEmpty }

    // MARK: - Navigation

    func load(_ url: URL) {
        lastError = nil
        log.info("loading \(url.absoluteString, privacy: .public) via in-app SOCKS5")
        page.load(URLRequest(url: url))
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        page.load(item)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        page.load(item)
    }

    func reload() {
        lastError = nil
        page.reload()
    }

    func stop() {
        page.stopLoading()
    }

    /// Drains the page's navigation events for this tab's lifetime, logging
    /// outcomes and recording failures into `lastError`. Driven from the view via
    /// `.task(id:)` so it follows the selected tab.
    func observeNavigations() async {
        do {
            for try await _ in page.navigations {
                lastError = nil
            }
            log.info("navigations stream ended for \(self.page.url?.absoluteString ?? "?", privacy: .public)")
        } catch {
            let message = error.localizedDescription
            log.error("navigation failed: \(message, privacy: .public)")
            lastError = message
        }
    }
}
