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

    init(socksPort: UInt16) {
        self.socksPort = socksPort
        let first = BrowserTab.make(socksPort: socksPort, websiteDataStore: websiteDataStore)
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
        let tab = BrowserTab.make(socksPort: socksPort, websiteDataStore: websiteDataStore)
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
        guard let url = Self.resolve(text) else { return }
        guard let tab = selectedTab ?? addTab() else { return }
        tab.load(url)
    }

    func stopAll() {
        tabs.forEach { $0.stop() }
        proxyIsAvailable = false
    }

    static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Already a full URL with a scheme.
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        // Looks like a bare hostname/URL: no spaces and contains a dot.
        if !trimmed.contains(" "), trimmed.contains(".") {
            let scheme = trimmed.hasSuffix(".onion") || trimmed.contains(".onion/") ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(trimmed)") {
                return url
            }
        }

        // Otherwise treat as a search query.
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}
