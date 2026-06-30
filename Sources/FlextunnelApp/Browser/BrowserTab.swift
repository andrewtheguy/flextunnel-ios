import Foundation
import Network
import Observation
import Security
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
    var certificateWarning: BrowserCertificateWarning?

    private let log = Logger(subsystem: "com.example.flextunnel", category: "webview")
    private let certificateTrustStore: BrowserCertificateTrustStore
    private let navigationDecider: BrowserNavigationDecider
    private let library: BrowserLibrary
    private var lastAttemptedURL: URL?

    /// When true, the home view is shown even though `page` still holds a loaded
    /// document — set by `goBack()` stepping off the first page, cleared by any
    /// load or by `goForward()` returning to the page.
    private var presentingHome = false
    private var certificateWarningContinuation: CheckedContinuation<Bool, Never>?

    /// Drains `page.navigations` for the tab's whole lifetime, independent of
    /// which tab is selected. Cancelled when the tab is closed.
    private var observationTask: Task<Void, Never>?

    private init(
        page: WebPage,
        certificateTrustStore: BrowserCertificateTrustStore,
        navigationDecider: BrowserNavigationDecider,
        library: BrowserLibrary
    ) {
        self.page = page
        self.certificateTrustStore = certificateTrustStore
        self.navigationDecider = navigationDecider
        self.library = library
    }

    /// Build a tab whose `WebPage` is proxied through the loopback SOCKS5 listener.
    /// The shared non-persistent data store keeps all tabs in one ephemeral session.
    static func make(
        socksPort: UInt16,
        websiteDataStore: WKWebsiteDataStore,
        certificateTrustStore: BrowserCertificateTrustStore,
        library: BrowserLibrary,
        downloads: BrowserDownloadManager
    ) -> BrowserTab {
        var config = WebPage.Configuration()
        config.websiteDataStore = websiteDataStore

        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: socksPort)!)
        config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]

        let navigationDecider = BrowserNavigationDecider(certificateTrustStore: certificateTrustStore)
        let tab = BrowserTab(
            page: WebPage(configuration: config, navigationDecider: navigationDecider),
            certificateTrustStore: certificateTrustStore,
            navigationDecider: navigationDecider,
            library: library)
        navigationDecider.certificateWarningHandler = { [weak tab] warning in
            await tab?.requestCertificateWarning(warning) ?? false
        }
        navigationDecider.downloadHandler = { request, suggestedFilename in
            Task { await downloads.download(request, suggestedFilename: suggestedFilename) }
        }
        tab.observationTask = Task { [weak tab] in await tab?.observeNavigations() }
        return tab
    }

    /// Cancels the lifetime navigation observer. Called when the tab is closed.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        resolveCertificateWarning(allow: false)
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

    /// Back is enabled whenever we're off the home view: it either steps through
    /// the page's web history or, on the first page, returns to home.
    var canGoBack: Bool { !isHome }
    var canGoForward: Bool {
        if presentingHome && page.url != nil { return true }
        return !page.backForwardList.forwardList.isEmpty
    }

    var visibleURL: URL? {
        if presentingHome { return nil }
        return loadFailure?.url ?? page.url ?? lastAttemptedURL
    }

    /// True before the tab has navigated anywhere — no committed page, no
    /// attempted load, no failure. Drives the placeholder home view.
    var isHome: Bool {
        visibleURL == nil
    }

    var siteSecurity: BrowserSiteSecurity? {
        guard let url = page.url ?? loadFailure?.url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        guard scheme == "https" else {
            return .notSecure
        }

        let port = url.port ?? 443
        if certificateTrustStore.isTrusted(host: host, port: port) {
            return .certificateException
        }
        if loadFailure != nil {
            return .notSecure
        }
        return .secure
    }

    // MARK: - Navigation

    func load(_ url: URL, displayAddress: String? = nil) {
        presentingHome = false
        lastAttemptedURL = url
        addressText = displayAddress ?? url.absoluteString
        loadFailure = nil
        log.info("loading host \(Self.logHost(for: url), privacy: .public) via in-app SOCKS5")
        page.load(URLRequest(url: url))
    }

    func goBack() {
        // On the first page there's no web history to step into, so back
        // returns to the home view instead.
        guard let item = page.backForwardList.backList.last else {
            goHome()
            return
        }
        presentingHome = false
        lastAttemptedURL = item.url
        addressText = item.url.absoluteString
        loadFailure = nil
        page.load(item)
    }

    func goForward() {
        // Returning from home re-reveals the already-loaded page.
        if presentingHome, let url = page.url {
            presentingHome = false
            lastAttemptedURL = url
            addressText = url.absoluteString
            loadFailure = nil
            return
        }
        guard let item = page.backForwardList.forwardList.first else { return }
        lastAttemptedURL = item.url
        addressText = item.url.absoluteString
        loadFailure = nil
        page.load(item)
    }

    /// Reveals the home view without unloading `page`, so `goForward()` can
    /// return to it.
    private func goHome() {
        presentingHome = true
        loadFailure = nil
        addressText = ""
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

    func resolveCertificateWarning(allow: Bool) {
        certificateWarning = nil
        certificateWarningContinuation?.resume(returning: allow)
        certificateWarningContinuation = nil
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
            // Record into history once the page has fully loaded, so the title
            // (which arrives with the document) is available.
            if case .finished = event, let url = page.url {
                library.recordVisit(title: page.title, url: url)
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
        // A navigation we cancelled to hand off as a download reports a policy
        // interruption — not a real failure, so don't show the error screen.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }

        let attemptedURL = failingURL(from: error) ?? lastAttemptedURL ?? page.url
        let message = Self.userFacingMessage(for: nsError)
        log.error("navigation failed: \(nsError.localizedDescription, privacy: .private)")

        if let attemptedURL {
            let previousAttempt = lastAttemptedURL
            lastAttemptedURL = attemptedURL
            if addressText.isEmpty || previousAttempt != attemptedURL {
                addressText = attemptedURL.absoluteString
            }
            loadFailure = BrowserLoadFailure(
                url: attemptedURL,
                message: message,
                reason: nsError.localizedDescription)
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

    private func requestCertificateWarning(_ warning: BrowserCertificateWarning) async -> Bool {
        certificateWarningContinuation?.resume(returning: false)
        certificateWarningContinuation = nil

        return await withCheckedContinuation { continuation in
            certificateWarning = warning
            certificateWarningContinuation = continuation
        }
    }
}

struct BrowserLoadFailure {
    let url: URL
    /// Friendly one-line summary mapped from the error code.
    let message: String
    /// The underlying system error description — the specific reason the load
    /// failed, shown when it adds detail beyond `message`.
    let reason: String
}

enum BrowserSiteSecurity: Equatable {
    case secure
    case notSecure
    case certificateException
}

struct BrowserCertificateWarning: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let port: Int
    /// Why trust evaluation failed (e.g. "certificate has expired"), surfaced
    /// in the interstitial so the user can see the cause like Chrome does.
    let reason: String

    var displayHost: String {
        port == 443 ? host : "\(host):\(port)"
    }
}

@MainActor
final class BrowserCertificateTrustStore {
    private var trustedHosts = Set<String>()

    func isTrusted(host: String, port: Int) -> Bool {
        trustedHosts.contains(key(host: host, port: port))
    }

    func trust(host: String, port: Int) {
        trustedHosts.insert(key(host: host, port: port))
    }

    private func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}

@MainActor
final class BrowserNavigationDecider: WebPage.NavigationDeciding {
    var certificateWarningHandler: ((BrowserCertificateWarning) async -> Bool)?
    /// Invoked with the request (and any server-suggested filename) when a
    /// navigation turns out to be a download. iOS 26's `WebPage` can't deliver
    /// the download itself, so we cancel the navigation and fetch it separately.
    var downloadHandler: ((URLRequest, String?) -> Void)?

    private let certificateTrustStore: BrowserCertificateTrustStore

    init(certificateTrustStore: BrowserCertificateTrustStore) {
        self.certificateTrustStore = certificateTrustStore
    }

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload {
            downloadHandler?(action.request, nil)
            return .cancel
        }
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        // A response WebKit can't display is a download. Cancel here (otherwise
        // the navigation hangs, since WebPage has no download delegate) and hand
        // it to the proxied downloader.
        guard response.canShowMimeType else {
            if let url = response.response.url {
                downloadHandler?(URLRequest(url: url), response.response.suggestedFilename)
            }
            return .cancel
        }
        return .allow
    }

    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port
        guard let reason = Self.serverTrustFailureReason(serverTrust) else {
            return (.performDefaultHandling, nil)
        }

        if certificateTrustStore.isTrusted(host: host, port: port) {
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        let warning = BrowserCertificateWarning(host: host, port: port, reason: reason)
        guard await certificateWarningHandler?(warning) == true else {
            return (.cancelAuthenticationChallenge, nil)
        }

        certificateTrustStore.trust(host: host, port: port)
        return (.useCredential, URLCredential(trust: serverTrust))
    }

    /// Evaluates the server trust: nil when valid, otherwise a human-readable
    /// reason (e.g. "certificate has expired", hostname mismatch) from the
    /// trust evaluation error.
    private static func serverTrustFailureReason(_ serverTrust: SecTrust) -> String? {
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            return nil
        }
        if let error {
            return (error as Error).localizedDescription
        }
        return "The certificate could not be verified."
    }
}
