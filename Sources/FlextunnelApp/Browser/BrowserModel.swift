import Foundation
import Observation
import WebKit

/// Owns the browser's tab list and the shared SOCKS5 port. Every tab is proxied
/// through the same in-app listener (flextunnel allows one instance at a time).
@MainActor
@Observable
final class BrowserModel {
    let socksPort: UInt16
    private(set) var tabs: [BrowserTab]
    var selectedID: BrowserTab.ID?
    var proxyIsAvailable = true
    private let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private let certificateTrustStore = BrowserCertificateTrustStore()

    init(socksPort: UInt16) {
        self.socksPort = socksPort
        let first = BrowserTab.make(
            socksPort: socksPort,
            websiteDataStore: websiteDataStore,
            certificateTrustStore: certificateTrustStore)
        self.tabs = [first]
        self.selectedID = first.id
    }

    var selectedTab: BrowserTab? {
        if let selectedID, let selected = tabs.first(where: { $0.id == selectedID }) {
            return selected
        }
        return tabs.first
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
    }

    /// Opens a fresh proxied tab at the home page and selects it.
    @discardableResult
    func addTab() -> BrowserTab? {
        guard proxyIsAvailable else { return nil }
        let tab = BrowserTab.make(
            socksPort: socksPort,
            websiteDataStore: websiteDataStore,
            certificateTrustStore: certificateTrustStore)
        tabs.append(tab)
        selectedID = tab.id
        return tab
    }

    /// Closes a tab. Reselects a neighbor if the closed tab was active, or leaves
    /// the browser with no selected tab when the last tab is closed.
    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.stopObserving()
        tabs.remove(at: index)
        if selectedID == tab.id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Resolves address-bar text and loads it in the selected tab.
    /// - URL-like input (no spaces, contains a dot, or already has a scheme) loads
    ///   directly; a missing scheme is prepended (`http://` for `.onion`, else `https://`).
    /// - Anything else is treated as a query and sent to DuckDuckGo.
    func navigate(_ text: String) {
        guard proxyIsAvailable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = Self.resolve(trimmed) else { return }
        guard let tab = selectedTab ?? addTab() else { return }
        tab.load(url, displayAddress: trimmed)
    }

    func stopAll() {
        tabs.forEach { $0.stop() }
        proxyIsAvailable = false
    }

    static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = webURL(from: trimmed) {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    private static func webURL(from text: String) -> URL? {
        if let localhostURL = localhostURL(from: text) {
            return localhostURL
        }

        let lowercased = text.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return validHTTPURL(from: text)
        }

        if lowercased.contains("://") {
            return nil
        }

        return bareHostURL(from: text)
    }

    private static func localhostURL(from text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        guard let components = URLComponents(string: "http://\(text)"),
              components.host?.lowercased() == "localhost" else {
            return nil
        }
        return components.url
    }

    private static func validHTTPURL(from text: String) -> URL? {
        guard !text.contains(" "),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              hostIsNavigable(host) else {
            return nil
        }
        return components.url
    }

    private static func bareHostURL(from text: String) -> URL? {
        guard !text.contains(" "), text.contains("."), Double(text) == nil else { return nil }

        // Parse with a default scheme so the host is isolated from any port or
        // path, then pick the real scheme from the parsed host. Onion services
        // are served over plain HTTP (the onion layer handles encryption /
        // authentication; CA certs for .onion are rare), so any `.onion` host —
        // regardless of case or port — uses http; everything else stays https.
        guard var components = URLComponents(string: "https://\(text)"),
              let host = components.host,
              hostIsNavigable(host) else {
            return nil
        }
        if host.lowercased().hasSuffix(".onion") {
            components.scheme = "http"
        }
        return components.url
    }

    private static func hostIsNavigable(_ host: String) -> Bool {
        host == "localhost" || host.contains(".")
    }
}
