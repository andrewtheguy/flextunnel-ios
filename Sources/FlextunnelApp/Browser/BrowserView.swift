import SwiftUI
import UIKit
import WebKit

/// Full-screen browser chrome over proxied `WebPage`s. The location surface
/// follows Firefox iOS: site identity/search, URL text, and stop/reload as the
/// trailing page action. Tunnel status is this app's custom action outside that
/// standard browser surface.
struct BrowserView: View {
    @State var model: BrowserModel
    @ObservedObject var proxy: ProxyController
    @Environment(\.dismiss) private var dismiss
    @State private var showingTunnelStatus = false
    @State private var showingTabTray = false
    @State private var showBookmarkSaved = false
    @State private var showingFind = false

    var body: some View {
        VStack(spacing: 0) {
            AddressBarView(
                model: model,
                proxy: proxy,
                proxyAvailable: proxyAvailable,
                tunnelStatusIcon: tunnelStatusIcon,
                tunnelStatusColor: tunnelStatusColor,
                showingTunnelStatus: $showingTunnelStatus,
                onReconnect: { proxy.retryNow() },
                onStopAndReconfigure: stopAndDismiss)
            Divider()

            if let tab = model.selectedTab {
                if tab.isHome {
                    BrowserHomeView(
                        proxyAvailable: proxyAvailable,
                        onOpen: { model.navigate($0) })
                } else {
                    // Keep the WebView mounted and layer the failure screen over
                    // it, so retrying toggles an overlay instead of tearing down
                    // and recreating the web view (which flickers).
                    WebView(tab.page)
                        .webViewBackForwardNavigationGestures(.enabled)
                        .findNavigator(isPresented: $showingFind)
                        .overlay(alignment: .top) { progressBar(for: tab.page) }
                        .overlay {
                            if let warning = tab.certificateWarning {
                                BrowserCertificateWarningView(
                                    warning: warning,
                                    onProceed: { tab.resolveCertificateWarning(allow: true) },
                                    onGoBack: { tab.resolveCertificateWarning(allow: false) })
                            } else if let failure = tab.loadFailure {
                                BrowserLoadFailureView(
                                    failure: failure,
                                    onRetry: { tab.retryFailedLoad() })
                            }
                        }
                }
            } else {
                EmptyBrowserView(
                    proxyAvailable: proxyAvailable,
                    onNewTab: { model.addTab() })
            }

            Divider()
            BottomActionBar(
                model: model,
                proxyAvailable: proxyAvailable,
                showingTabTray: $showingTabTray,
                showingFind: $showingFind,
                onDisconnect: stopAndDismiss,
                onBookmarkSaved: flashBookmarkSaved)
        }
        .overlay(alignment: .bottom) {
            if showBookmarkSaved {
                BookmarkSavedToast()
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let toast = model.downloads.toast {
                DownloadStatusToast(toast: toast)
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: Bindable(model.downloads).pendingPrompt) { prompt in
            DownloadPromptView(
                prompt: prompt,
                onDownload: { model.downloads.confirm(prompt) },
                onCancel: { model.downloads.cancelPrompt() })
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        .animation(.easeInOut(duration: 0.25), value: model.downloads.toast)
        .onChange(of: model.downloads.toast) {
            // Auto-clear the terminal download toast after a moment.
            guard let shown = model.downloads.toast else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if model.downloads.toast == shown { model.downloads.toast = nil }
            }
        }
        .fullScreenCover(isPresented: $showingTabTray) {
            TabTrayView(model: model)
        }
        .onAppear { enforceProxyAvailability() }
        .onChange(of: proxy.socksAlive) { enforceProxyAvailability() }
        .onChange(of: proxy.tunnelConnected) { enforceProxyAvailability() }
        .onChange(of: proxy.socksPort) { enforceProxyAvailability() }
    }

    /// Whether the browser is usable: the SOCKS5 listener is up and this tab's
    /// port matches. Stays true while the tunnel link is down for a partial
    /// split-tunnel set (off-list targets still browse directly).
    private var proxyAvailable: Bool {
        proxy.canBrowse && proxy.socksPort == model.socksPort
    }

    private var tunnelStatusIcon: String {
        proxy.socksPort != nil ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
    }

    /// Green when the tunnel link is up, orange when browsing still works but the
    /// tunnel is down (off-list only), red when the proxy is unusable.
    private var tunnelStatusColor: Color {
        if proxy.tunnelConnected {
            return .green
        }
        if proxyAvailable {
            return .orange
        }
        if proxy.socksPort != nil {
            return .red
        }
        return .secondary
    }

    /// Keep navigation gated to the tunnel's availability. A drop no longer
    /// dismisses the browser — the page stays put and reconnect/quit live in the
    /// tunnel status popover; only an explicit Quit (`stopAndDismiss`) closes it.
    private func enforceProxyAvailability() {
        model.proxyIsAvailable = proxyAvailable
    }

    private func stopAndDismiss() {
        model.stopAll()
        proxy.stop()
        showingTunnelStatus = false
        showingTabTray = false
        dismiss()
    }

    @ViewBuilder
    private func progressBar(for page: WebPage) -> some View {
        if page.isLoading && page.estimatedProgress < 1 {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
        }
    }

    /// Briefly shows the "Bookmark Saved" toast, then fades it out.
    private func flashBookmarkSaved() {
        withAnimation(.spring(duration: 0.3)) { showBookmarkSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.3)) { showBookmarkSaved = false }
        }
    }

}

/// Transient confirmation shown after a bookmark is saved.
private struct BookmarkSavedToast: View {
    var body: some View {
        Label("Bookmark Saved", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.green, in: Capsule())
            .shadow(radius: 6, y: 2)
    }
}

/// Transient confirmation shown when a download finishes or fails.
private struct DownloadStatusToast: View {
    let toast: DownloadToast

    var body: some View {
        Label(toast.message, systemImage: toast.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(toast.isFailure ? Color.red : Color.green, in: Capsule())
            .shadow(radius: 6, y: 2)
    }
}

/// Placeholder shown for a fresh tab that hasn't navigated yet — a wordmark and
/// a grid of search engines, mirroring Firefox iOS's default new-tab page so
/// startup isn't a blank web view. Tapping a tile loads it through the tunnel.
private struct BrowserHomeView: View {
    let proxyAvailable: Bool
    let onOpen: (String) -> Void

    /// Search engines offered as a starting point. Favicons aren't bundled here,
    /// so each tile uses a monogram in the engine's brand color.
    private struct SearchEngine: Identifiable {
        let id = UUID()
        let title: String
        let url: String
        let color: Color
        var monogram: String { String(title.prefix(1)) }
    }

    private let engines = [
        SearchEngine(title: "Google", url: "https://www.google.com/", color: Color(red: 0.26, green: 0.52, blue: 0.96)),
        SearchEngine(title: "DuckDuckGo", url: "https://duckduckgo.com/", color: Color(red: 0.87, green: 0.40, blue: 0.16)),
        SearchEngine(title: "Bing", url: "https://www.bing.com/", color: Color(red: 0.0, green: 0.46, blue: 0.49)),
    ]

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(.tint)

                    Text("flextunnel")
                        .font(.largeTitle.weight(.semibold))

                    Text("Search or enter an address to browse through your tunnel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("SEARCH ENGINES")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(engines) { engine in
                            Button {
                                onOpen(engine.url)
                            } label: {
                                engineTile(engine)
                            }
                            .buttonStyle(.plain)
                            .disabled(!proxyAvailable)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func engineTile(_ engine: SearchEngine) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(engine.color)
                .frame(width: 60, height: 60)
                .overlay {
                    Text(engine.monogram)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }

            Text(engine.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

private struct EmptyBrowserView: View {
    let proxyAvailable: Bool
    let onNewTab: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Tabs")
                .font(.title3.weight(.semibold))

            Button(action: onNewTab) {
                Label("New Tab", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!proxyAvailable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct BrowserLoadFailureView: View {
    let failure: BrowserLoadFailure
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)

            Text("Problem Loading Page")
                .font(.title3.weight(.semibold))

            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 320)

            if failure.reason != failure.message {
                Text(failure.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 320)
            }

            Text(failure.url.host() ?? failure.url.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button(action: onRetry) {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// Full-screen interstitial for an untrusted TLS certificate — Chrome-style:
/// states the connection isn't private, shows the specific reason and host, and
/// offers going back or proceeding anyway (which trusts the host for the
/// session). Replaces a modal alert so it reads like the load-failure page.
private struct BrowserCertificateWarningView: View {
    let warning: BrowserCertificateWarning
    let onProceed: () -> Void
    let onGoBack: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.red)

            Text("Your connection is not private")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(warning.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 320)

            Text(warning.displayHost)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            VStack(spacing: 10) {
                Button(action: onGoBack) {
                    Text("Go Back").frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive, action: onProceed) {
                    Text("Continue Anyway").frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// Top chrome: app-specific tunnel status plus Firefox-style location surface.
private struct AddressBarView: View {
    @Bindable var model: BrowserModel
    let proxy: ProxyController
    let proxyAvailable: Bool
    let tunnelStatusIcon: String
    let tunnelStatusColor: Color
    @Binding var showingTunnelStatus: Bool
    let onReconnect: () -> Void
    let onStopAndReconfigure: () -> Void
    @State private var editText = ""
    @State private var showingSiteSecurity = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                leadingLocationButton(for: tab)

                ZStack(alignment: .leading) {
                    TextField("Search or enter address", text: $editText)
                        .textFieldStyle(.plain)
                        .keyboardType(.webSearch)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .opacity(addressFocused ? 1 : 0)
                        .allowsHitTesting(addressFocused)
                        .onSubmit {
                            guard proxyAvailable else { return }
                            model.navigate(editText)
                            addressFocused = false
                        }
                        .disabled(!proxyAvailable)

                    if !addressFocused {
                        Button {
                            beginEditing(tab)
                        } label: {
                            AddressDisplayText(tab: tab)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!proxyAvailable)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36)

                trailingLocationButton(for: tab)
            }
            .frame(height: 36)
            .padding(.leading, 2)
            .padding(.trailing, 4)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(.separator).opacity(0.18), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .popover(isPresented: $showingSiteSecurity) {
                if let tab {
                    SiteSecurityPopover(tab: tab)
                        .presentationCompactAdaptation(.popover)
                }
            }

            tunnelStatusButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: model.selectedID) { syncAddress(model.selectedTab?.addressText) }
        .onChange(of: tab?.addressText) { if !addressFocused { syncAddress(tab?.addressText) } }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                editText = tab?.addressText ?? editText
            } else {
                syncAddress(tab?.addressText)
            }
        }
        .onAppear { syncAddress(tab?.addressText) }
    }

    private var tunnelStatusButton: some View {
        Button {
            showingTunnelStatus = true
        } label: {
            Image(systemName: tunnelStatusIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tunnelStatusColor)
                .frame(width: 40, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tunnel status")
        .popover(isPresented: $showingTunnelStatus, arrowEdge: .top) {
            TunnelStatusPopover(
                proxy: proxy,
                boundPort: model.socksPort,
                onDismiss: { showingTunnelStatus = false },
                onReconnect: onReconnect,
                onStopAndReconfigure: onStopAndReconfigure)
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private func leadingLocationButton(for tab: BrowserTab?) -> some View {
        if addressFocused || tab?.siteSecurity == nil {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 36)
                .accessibilityHidden(true)
        } else if let tab {
            Button {
                showingSiteSecurity = true
            } label: {
                Image(systemName: siteSecurityIcon(for: tab.siteSecurity))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(siteSecurityColor(for: tab.siteSecurity))
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(siteSecurityAccessibilityLabel(for: tab.siteSecurity))
        }
    }

    @ViewBuilder
    private func trailingLocationButton(for tab: BrowserTab?) -> some View {
        if addressFocused {
            if !editText.isEmpty {
                Button {
                    editText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear address")
            }
        } else if let tab {
            Button {
                if tab.page.isLoading {
                    tab.stop()
                } else {
                    tab.reload()
                }
            } label: {
                Image(systemName: tab.page.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!proxyAvailable)
            .accessibilityLabel(tab.page.isLoading ? "Stop loading" : "Reload")
        }
    }

    private func beginEditing(_ tab: BrowserTab?) {
        guard proxyAvailable else { return }
        editText = tab?.addressText ?? editText
        addressFocused = true
    }

    private func syncAddress(_ address: String?) {
        editText = address ?? ""
    }

    private func siteSecurityIcon(for security: BrowserSiteSecurity?) -> String {
        switch security {
        case .secure:
            return "lock.fill"
        case .notSecure:
            return "info.circle"
        case .certificateException:
            return "lock.slash.fill"
        case nil:
            return "magnifyingglass"
        }
    }

    private func siteSecurityColor(for security: BrowserSiteSecurity?) -> Color {
        switch security {
        case .secure:
            return .secondary
        case .notSecure:
            return .secondary
        case .certificateException:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func siteSecurityAccessibilityLabel(for security: BrowserSiteSecurity?) -> String {
        switch security {
        case .secure:
            return "Secure connection"
        case .notSecure:
            return "Connection is not secure"
        case .certificateException:
            return "Certificate exception"
        case nil:
            return "Search or enter address"
        }
    }
}

@MainActor
private struct AddressDisplayText: View {
    let tab: BrowserTab?

    var body: some View {
        if let tab,
           let parts = AddressDisplayParts(tab: tab) {
            HStack(spacing: 0) {
                if !parts.subduedPrefix.isEmpty {
                    Text(parts.subduedPrefix)
                        .foregroundStyle(.secondary)
                }
                Text(parts.primaryText)
                    .foregroundStyle(.primary)
            }
            .font(.body)
            .lineLimit(1)
            .truncationMode(.head)
        } else if let address = tab?.addressText, !address.isEmpty {
            Text(address)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
        } else {
            Text("Search or enter address")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

@MainActor
private struct AddressDisplayParts {
    let subduedPrefix: String
    let primaryText: String

    init?(tab: BrowserTab) {
        guard let url = tab.visibleURL,
              let host = url.host(),
              !host.isEmpty else {
            return nil
        }

        let displayHost = Self.displayHost(host)
        let portSuffix = Self.portSuffix(for: url)
        guard Self.canSplit(host: displayHost) else {
            subduedPrefix = ""
            primaryText = displayHost + portSuffix
            return
        }

        let labels = displayHost.split(separator: ".").map(String.init)
        let registrableCount = Self.registrableLabelCount(for: labels)
        guard labels.count > registrableCount else {
            subduedPrefix = ""
            primaryText = displayHost + portSuffix
            return
        }

        subduedPrefix = labels.dropLast(registrableCount).joined(separator: ".") + "."
        primaryText = labels.suffix(registrableCount).joined(separator: ".") + portSuffix
    }

    /// Number of trailing labels making up the registrable domain (the part to
    /// emphasize). This is a pragmatic stand-in for the Public Suffix List,
    /// erring toward not dimming the registrant:
    /// - a known multi-label public suffix (`example.co.uk`) → 3;
    /// - a longer gTLD (`.com`, `.dev`, …) → 2 (the usual eTLD+1);
    /// - an unknown 2-letter ccTLD (`co.ke`, `github.io`, …), where 2-label and
    ///   private suffixes are common and the registrable boundary is unknowable
    ///   without the full PSL → no split, so the whole host stays primary rather
    ///   than risk promoting the suffix over the registrant.
    private static func registrableLabelCount(for labels: [String]) -> Int {
        guard labels.count >= 3 else { return 2 }
        let lastTwo = labels.suffix(2).joined(separator: ".").lowercased()
        if multiLabelPublicSuffixes.contains(lastTwo) { return 3 }
        if labels[labels.count - 1].count <= 2 { return labels.count }
        return 2
    }

    private static let multiLabelPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "ne.jp", "or.jp", "go.jp", "ac.jp",
        "co.nz", "net.nz", "org.nz", "govt.nz",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "co.kr", "co.za", "com.br", "com.cn", "com.mx", "com.tr",
        "com.sg", "com.hk", "com.tw", "co.il", "com.ar",
    ]

    private static func displayHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private static func portSuffix(for url: URL) -> String {
        guard let port = url.port else { return "" }
        let scheme = url.scheme?.lowercased()
        if scheme == "https", port == 443 { return "" }
        if scheme == "http", port == 80 { return "" }
        return ":\(port)"
    }

    private static func canSplit(host: String) -> Bool {
        if host == "localhost" { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return true
    }
}

@MainActor
private struct SiteSecurityPopover: View {
    let tab: BrowserTab

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)

            if let url = tab.visibleURL {
                Text(hostText(for: url))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 300, alignment: .leading)
    }

    private var title: String {
        switch tab.siteSecurity {
        case .secure:
            return "Secure Connection"
        case .notSecure:
            return "Not Secure"
        case .certificateException:
            return "Certificate Exception"
        case nil:
            return "Site Information"
        }
    }

    private var message: String {
        switch tab.siteSecurity {
        case .secure:
            return "The connection uses HTTPS."
        case .notSecure:
            return "The connection does not use HTTPS."
        case .certificateException:
            return "You allowed this certificate for the current browser session."
        case nil:
            return "No site information is available."
        }
    }

    private var icon: String {
        switch tab.siteSecurity {
        case .secure:
            return "lock.fill"
        case .notSecure:
            return "info.circle"
        case .certificateException:
            return "lock.slash.fill"
        case nil:
            return "info.circle"
        }
    }

    private var color: Color {
        switch tab.siteSecurity {
        case .secure:
            return .green
        case .notSecure:
            return .red
        case .certificateException:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func hostText(for url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// Bottom toolbar: back, forward, share, bookmark (placeholder), tab tray, menu.
private struct BottomActionBar: View {
    @Bindable var model: BrowserModel
    let proxyAvailable: Bool
    @Binding var showingTabTray: Bool
    @Binding var showingFind: Bool
    let onDisconnect: () -> Void
    let onBookmarkSaved: () -> Void
    @State private var showingLibrary = false
    @State private var showingDownloads = false
    @State private var shareItem: ShareItem?
    @State private var bookmarkDraft: BookmarkDraft?
    /// A draft requested from inside the share popout, applied once it dismisses
    /// so we never present two sheets at once.
    @State private var pendingShareDraft: BookmarkDraft?

    /// Wraps the URL being shared so it can drive `.sheet(item:)`.
    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        let tab = model.selectedTab
        let url = tab?.page.url
        HStack {
            Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!proxyAvailable || tab?.canGoBack != true)

            Spacer()

            Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!proxyAvailable || tab?.canGoForward != true)

            Spacer()

            Button { showingDownloads = true } label: {
                Image(systemName: downloadsActive ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .accessibilityLabel("Downloads")

            Spacer()

            if let url {
                Button { shareItem = ShareItem(url: url) } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(!proxyAvailable)
                    .accessibilityLabel("Share")
            } else {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button { showingLibrary = true } label: { Image(systemName: "bookmark") }
                .accessibilityLabel("Bookmarks and history")

            Spacer()

            Button { showingTabTray = true } label: { tabCountIcon }
                .accessibilityLabel("Show tabs")

            Spacer()

            Menu {
                if let url {
                    if model.library.isBookmarked(url) {
                        Button {
                            model.library.removeBookmark(url: url)
                        } label: {
                            Label("Remove Bookmark", systemImage: "bookmark.slash")
                        }
                    } else {
                        Button {
                            bookmarkDraft = BookmarkDraft(
                                name: tab?.displayTitle ?? (url.host() ?? url.absoluteString),
                                url: url)
                        } label: {
                            Label("Add Bookmark", systemImage: "bookmark")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    Button {
                        showingFind = true
                    } label: {
                        Label("Find in Page", systemImage: "magnifyingglass")
                    }
                }
                Divider()
                if let url {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open in Safari (bypasses tunnel)", systemImage: "safari")
                    }
                }
                if let tab = tab {
                    Button {
                        model.closeTab(tab)
                    } label: {
                        Label("Close Tab", systemImage: "xmark.square")
                    }
                }
                Divider()
                Button(role: .destructive, action: onDisconnect) {
                    Label("Disconnect Tunnel", systemImage: "stop.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
        .imageScale(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.bar)
        .sheet(isPresented: $showingLibrary) {
            BookmarksHistoryView(model: model)
        }
        .sheet(isPresented: $showingDownloads) {
            DownloadsView(model: model)
        }
        .sheet(item: $shareItem) { item in
            BrowserShareSheet(
                url: item.url,
                activities: [bookmarkActivity(for: item.url)],
                onDismiss: {
                    shareItem = nil
                    // Present the editor only after the popout has gone, so the
                    // two sheets never overlap.
                    if let draft = pendingShareDraft {
                        pendingShareDraft = nil
                        DispatchQueue.main.async { bookmarkDraft = draft }
                    }
                })
                .ignoresSafeArea()
        }
        .sheet(item: $bookmarkDraft) { draft in
            BookmarkEditView(draft: draft) { name, url in
                model.library.addBookmark(name: name, url: url)
                onBookmarkSaved()
            }
        }
    }

    /// Builds the share-popout bookmark action. Removal happens immediately;
    /// adding stashes a draft so the editor opens once the popout dismisses.
    private func bookmarkActivity(for url: URL) -> BookmarkActivity {
        let library = model.library
        if library.isBookmarked(url) {
            return BookmarkActivity(mode: .remove) { library.removeBookmark(url: url) }
        }
        let name = model.selectedTab?.displayTitle ?? (url.host() ?? url.absoluteString)
        return BookmarkActivity(mode: .add) { pendingShareDraft = BookmarkDraft(name: name, url: url) }
    }

    private var downloadsActive: Bool {
        model.downloads.items.contains { if case .downloading = $0.state { return true } else { return false } }
    }

    private var tabCountIcon: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(lineWidth: 2)
            .frame(width: 26, height: 26)
            .overlay {
                Text("\(model.tabs.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
    }
}

private struct TunnelStatusPopover: View {
    @ObservedObject var proxy: ProxyController
    let boundPort: UInt16
    let onDismiss: () -> Void
    let onReconnect: () -> Void
    let onStopAndReconfigure: () -> Void

    /// The SOCKS proxy is up but the tunnel link is (re)establishing. Browsing may
    /// still work (off-list) while this is true; the core reconnects on its own.
    private var isReconnecting: Bool {
        proxy.socksAlive && !proxy.tunnelConnected
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Label(healthTitle, systemImage: healthIcon)
                        .font(.headline)
                        .foregroundStyle(healthColor)

                    Spacer(minLength: 0)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss status")
                }

                VStack(alignment: .leading, spacing: 10) {
                    DetailRow("State", proxy.status)
                    DetailRow("SOCKS proxy", proxy.socksAlive ? "running" : "stopped",
                              valueColor: proxy.socksAlive ? .green : .red)
                    DetailRow("Tunnel link", tunnelLinkText, valueColor: healthColor)
                    DetailRow("Bound SOCKS", "127.0.0.1:\(proxy.socksPort ?? boundPort)")

                    if let summary = proxy.connectionSummary {
                        DetailRow("Server node id", summary.serverNodeID, monospace: true)
                        DetailRow("Relay URLs", relayURLsText(summary.relayURLs))
                        DetailRow("DNS discovery", summary.dnsServer ?? "iroh discovery")
                    }

                    forwardedRoutesRows
                }

                if let error = proxy.lastError {
                    DetailRow("Last error", error, valueColor: .red)
                }

                Divider()

                // Tunnel status lives here in the popover so the page underneath
                // is never disturbed. While the link is down the core reconnects on
                // its own (off-list browsing keeps working); only a fully stopped
                // proxy needs a manual Reconnect.
                if isReconnecting {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Reconnecting…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if proxy.canBrowse {
                            Text("Off-list browsing works; on-list (tunneled) routes are temporarily unavailable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !proxy.socksAlive {
                    Button(action: onReconnect) {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive, action: onStopAndReconfigure) {
                    Label("Stop and Reconfigure", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .frame(minWidth: 300, idealWidth: 340, maxHeight: 520)
    }

    /// The tunnel set the server pushed: the domains/CIDRs routed through the
    /// tunnel (everything else browses directly). Shown even while the link is
    /// down so the user can see which routes are temporarily unavailable.
    @ViewBuilder
    private var forwardedRoutesRows: some View {
        if let routes = proxy.forwardedRoutes {
            if routes.isFullTunnel {
                DetailRow("Tunnel set", "Full tunnel (all traffic)")
            } else {
                if !routes.domains.isEmpty {
                    DetailRow("Tunneled domains", routes.domains.joined(separator: "\n"), monospace: true)
                }
                if !routes.cidrs.isEmpty {
                    DetailRow("Tunneled CIDRs", routes.cidrs.joined(separator: "\n"), monospace: true)
                }
            }
            if !routes.hostAliases.isEmpty {
                DetailRow(
                    "Host aliases",
                    routes.hostAliases.map { "\($0.alias) → \($0.target)" }.joined(separator: "\n"),
                    monospace: true)
            }
            if !routes.agentAliases.isEmpty {
                DetailRow(
                    "Agent routes",
                    routes.agentAliases.joined(separator: "\n"),
                    monospace: true)
            }
        }
    }

    private var tunnelLinkText: String {
        if proxy.tunnelConnected { return "connected" }
        return proxy.socksAlive ? "reconnecting" : "down"
    }

    private var healthTitle: String {
        if proxy.tunnelConnected { return "Tunnel connected" }
        if proxy.canBrowse { return "Tunnel reconnecting" }
        return "Tunnel unavailable"
    }

    private var healthIcon: String {
        proxy.tunnelConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
    }

    private var healthColor: Color {
        if proxy.tunnelConnected { return .green }
        if proxy.canBrowse { return .orange }
        return .red
    }

    private func relayURLsText(_ relayURLs: [String]) -> String {
        relayURLs.isEmpty ? "iroh defaults" : relayURLs.joined(separator: "\n")
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    let valueColor: Color?
    let monospace: Bool

    init(_ title: String, _ value: String, valueColor: Color? = nil, monospace: Bool = false) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
        self.monospace = monospace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(monospace ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(valueColor ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
