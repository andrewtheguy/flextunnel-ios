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

    /// Address-bar text for the active navigation. This intentionally does not
    /// mirror `page.url` blindly because provisional navigation failures can
    /// leave WebKit without a committed URL.
    var addressText = ""
    var loadFailure: BrowserLoadFailure?

    private let log = Logger(subsystem: "com.example.flextunnel", category: "webview")
    private var lastAttemptedURL: URL?

    /// Drains `page.navigations` for the tab's whole lifetime, independent of
    /// which tab is selected. Cancelled when the tab is closed.
    private var observationTask: Task<Void, Never>?

    private init(page: WebPage) {
        self.page = page
    }

    /// Build a tab whose `WebPage` is proxied through the loopback SOCKS5 listener.
    /// The shared non-persistent data store keeps all tabs in one ephemeral session.
    static func make(socksPort: UInt16, websiteDataStore: WKWebsiteDataStore) -> BrowserTab {
        var config = WebPage.Configuration()
        config.websiteDataStore = websiteDataStore

        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: socksPort)!)
        config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]

        let tab = BrowserTab(page: WebPage(configuration: config))
        tab.observationTask = Task { [weak tab] in await tab?.observeNavigations() }
        return tab
    }

    /// Cancels the lifetime navigation observer. Called when the tab is closed.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Derived state (reads WebPage's @Observable properties)

    /// Page title, falling back to the host, then a placeholder.
    var displayTitle: String {
        if loadFailure != nil {
            return "Problem Loading Page"
        }
        let title = page.title
        if !title.isEmpty { return title }
        if let host = page.url?.host() { return host }
        if !addressText.isEmpty { return addressText }
        return "New Tab"
    }

    var displaySubtitle: String {
        if let host = loadFailure?.url.host() { return host }
        if let host = page.url?.host() { return host }
        return addressText.isEmpty ? "New Tab" : addressText
    }

    var canGoBack: Bool { !page.backForwardList.backList.isEmpty }
    var canGoForward: Bool { !page.backForwardList.forwardList.isEmpty }

    // MARK: - Navigation

    func load(_ url: URL, displayAddress: String? = nil) {
        lastAttemptedURL = url
        addressText = displayAddress ?? url.absoluteString
        loadFailure = nil
        log.info("loading host \(Self.logHost(for: url), privacy: .public) via in-app SOCKS5")
        page.load(URLRequest(url: url))
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        lastAttemptedURL = item.url
        addressText = item.url.absoluteString
        loadFailure = nil
        page.load(item)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        lastAttemptedURL = item.url
        addressText = item.url.absoluteString
        loadFailure = nil
        page.load(item)
    }

    func reload() {
        if let failedURL = loadFailure?.url ?? lastAttemptedURL, loadFailure != nil {
            load(failedURL, displayAddress: addressText)
        } else {
            loadFailure = nil
            page.reload()
        }
    }

    func stop() {
        page.stopLoading()
    }

    func retryFailedLoad() {
        guard let url = loadFailure?.url ?? lastAttemptedURL else { return }
        load(url, displayAddress: addressText)
    }

    /// Drains the page's navigation events for this tab's lifetime, logging
    /// outcomes and recording failures into `loadFailure`. Started in `make` and
    /// cancelled in `stopObserving`, so it runs regardless of tab selection.
    private func observeNavigations() async {
        while !Task.isCancelled {
            do {
                for try await event in page.navigations {
                    handleNavigationEvent(event)
                }
                log.info("navigations stream ended for host \(Self.logHost(for: self.page.url), privacy: .public)")
                return
            } catch is CancellationError {
                return
            } catch {
                handleNavigationError(error)
            }
        }
    }

    private func handleNavigationEvent(_ event: WebPage.NavigationEvent) {
        switch event {
        case .committed, .finished:
            loadFailure = nil
            if let url = page.url {
                addressText = url.absoluteString
            }
        case .startedProvisionalNavigation, .receivedServerRedirect:
            break
        @unknown default:
            break
        }
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = underlyingNSError(from: error)
        guard nsError.code != NSURLErrorCancelled else { return }

        let attemptedURL = failingURL(from: error) ?? lastAttemptedURL ?? page.url
        let message = Self.userFacingMessage(for: nsError)
        log.error("navigation failed: \(nsError.localizedDescription, privacy: .private)")

        if let attemptedURL {
            let previousAttempt = lastAttemptedURL
            lastAttemptedURL = attemptedURL
            if addressText.isEmpty || previousAttempt != attemptedURL {
                addressText = attemptedURL.absoluteString
            }
            loadFailure = BrowserLoadFailure(url: attemptedURL, message: message)
        }
    }

    private func failingURL(from error: Error) -> URL? {
        if case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error {
            let nsError = underlying as NSError
            return nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        }

        let nsError = error as NSError
        return nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
    }

    private func underlyingNSError(from error: Error) -> NSError {
        if case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error {
            return underlying as NSError
        }
        return error as NSError
    }

    private static func userFacingMessage(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else {
            return "The page could not be loaded."
        }

        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "The server could not be found."
        case NSURLErrorTimedOut:
            return "The connection timed out."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "The network connection was lost."
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return "A secure connection could not be established."
        default:
            return "The page could not be loaded."
        }
    }

    private static func logHost(for url: URL?) -> String {
        url?.host() ?? "unknown"
    }
}

struct BrowserLoadFailure {
    let url: URL
    let message: String
}
