import SwiftUI
import UIKit
import WebKit

/// Full-screen browser chrome over the proxied `WebPage`s, laid out like Firefox
/// iOS / Onion Browser: a top address bar (tunnel status, URL field, reload/stop),
/// the web view with a thin progress bar, and a bottom action toolbar
/// (back/forward, share, bookmark, tab tray, overflow menu).
struct BrowserView: View {
    @State var model: BrowserModel
    @ObservedObject var proxy: ProxyController
    @Environment(\.dismiss) private var dismiss
    @State private var showingTunnelStatus = false
    @State private var showingTabTray = false

    var body: some View {
        VStack(spacing: 0) {
            AddressBarView(
                model: model,
                proxyAvailable: proxyAvailable,
                tunnelStatusIcon: tunnelStatusIcon,
                tunnelStatusColor: tunnelStatusColor,
                showingTunnelStatus: $showingTunnelStatus)
            Divider()

            if let tab = model.selectedTab {
                if let failure = tab.loadFailure {
                    BrowserLoadFailureView(
                        failure: failure,
                        onRetry: { tab.retryFailedLoad() })
                } else {
                    WebView(tab.page)
                        .webViewBackForwardNavigationGestures(.enabled)
                        .overlay(alignment: .top) { progressBar(for: tab.page) }
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
                onDisconnect: stopAndDismiss)
        }
        .popover(isPresented: $showingTunnelStatus) {
            TunnelStatusPopover(
                proxy: proxy,
                boundPort: model.socksPort,
                onDismiss: { showingTunnelStatus = false },
                onStopAndReconfigure: stopAndDismiss)
                .presentationCompactAdaptation(.sheet)
        }
        .fullScreenCover(isPresented: $showingTabTray) {
            TabTrayView(model: model)
        }
        .alert("Insecure Connection", isPresented: certificateWarningIsPresented) {
            Button("Cancel", role: .cancel) {
                model.selectedTab?.resolveCertificateWarning(allow: false)
            }
            Button("Continue", role: .destructive) {
                model.selectedTab?.resolveCertificateWarning(allow: true)
            }
        } message: {
            if let warning = model.selectedTab?.certificateWarning {
                Text("The certificate for \(warning.displayHost) cannot be verified. Continue only if you trust this server.")
            } else {
                Text("")
            }
        }
        .onAppear { enforceProxyAvailability() }
        .onChange(of: proxy.healthy) { enforceProxyAvailability() }
        .onChange(of: proxy.socksPort) { enforceProxyAvailability() }
    }

    private var proxyAvailable: Bool {
        proxy.healthy && proxy.socksPort == model.socksPort
    }

    private var tunnelStatusIcon: String {
        if proxyAvailable {
            return "checkmark.shield.fill"
        }
        if proxy.socksPort != nil || proxy.status == "error" {
            return "exclamationmark.shield.fill"
        }
        return "shield.slash.fill"
    }

    private var tunnelStatusColor: Color {
        if proxyAvailable {
            return .green
        }
        if proxy.socksPort != nil || proxy.status == "error" {
            return .red
        }
        return .secondary
    }

    private var certificateWarningIsPresented: Binding<Bool> {
        Binding {
            model.selectedTab?.certificateWarning != nil
        } set: { isPresented in
            if !isPresented {
                model.selectedTab?.resolveCertificateWarning(allow: false)
            }
        }
    }

    private func enforceProxyAvailability() {
        model.proxyIsAvailable = proxyAvailable
        guard proxyAvailable else {
            model.stopAll()
            showingTunnelStatus = false
            showingTabTray = false
            dismiss()
            return
        }
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

/// Top chrome: tunnel status icon, the editable address field, and reload/stop.
private struct AddressBarView: View {
    @Bindable var model: BrowserModel
    let proxyAvailable: Bool
    let tunnelStatusIcon: String
    let tunnelStatusColor: Color
    @Binding var showingTunnelStatus: Bool
    @State private var editText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 10) {
            Button {
                showingTunnelStatus = true
            } label: {
                Image(systemName: tunnelStatusIcon)
                    .foregroundStyle(tunnelStatusColor)
                    .imageScale(.large)
            }
            .accessibilityLabel("Tunnel status")

            TextField("Search or enter address", text: $editText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    guard proxyAvailable else { return }
                    model.navigate(editText)
                    addressFocused = false
                }
                .disabled(!proxyAvailable)

            if let tab = tab {
                Button {
                    if tab.page.isLoading { tab.stop() } else { tab.reload() }
                } label: {
                    Image(systemName: tab.page.isLoading ? "xmark" : "arrow.clockwise")
                        .imageScale(.large)
                }
                .disabled(!proxyAvailable)
                .accessibilityLabel(tab.page.isLoading ? "Stop loading" : "Reload")
            } else {
                Button {
                    model.addTab()
                } label: {
                    Image(systemName: "plus")
                        .imageScale(.large)
                }
                .disabled(!proxyAvailable)
                .accessibilityLabel("New tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        // Reflect the active tab's URL when not editing; show the raw URL while editing.
        .onChange(of: model.selectedID) { syncAddress(model.selectedTab?.addressText) }
        .onChange(of: tab?.addressText) { if !addressFocused { syncAddress(tab?.addressText) } }
        .onChange(of: addressFocused) { if addressFocused { editText = tab?.addressText ?? editText } }
        .onAppear { syncAddress(tab?.addressText) }
    }

    private func syncAddress(_ address: String?) {
        editText = address ?? ""
    }
}

/// Bottom toolbar: back, forward, share, bookmark (placeholder), tab tray, menu.
private struct BottomActionBar: View {
    @Bindable var model: BrowserModel
    let proxyAvailable: Bool
    @Binding var showingTabTray: Bool
    let onDisconnect: () -> Void

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

            if let url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!proxyAvailable)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Placeholder — bookmarking is not implemented yet.
            Button {} label: { Image(systemName: "bookmark") }
                .disabled(true)

            Spacer()

            Button { showingTabTray = true } label: { tabCountIcon }
                .accessibilityLabel("Show tabs")

            Spacer()

            Menu {
                if let url {
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
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
        .padding(.vertical, 10)
        .background(.bar)
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
    let onStopAndReconfigure: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Label(healthTitle, systemImage: healthIcon)
                        .font(.headline)
                        .foregroundStyle(healthColor)

                    Spacer(minLength: 0)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss status")
                }

                VStack(alignment: .leading, spacing: 10) {
                    DetailRow("State", proxy.status)
                    DetailRow("Health", proxy.healthy ? "alive" : "down", valueColor: healthColor)
                    DetailRow("Browser proxy", "SOCKS5 only")
                    DetailRow("Bound SOCKS", "127.0.0.1:\(proxy.socksPort ?? boundPort)")

                    if let summary = proxy.connectionSummary {
                        DetailRow("Requested port", "\(summary.requestedSocksPort)")
                        DetailRow("Server node id", summary.serverNodeID, monospace: true)
                        DetailRow("Relay URLs", relayURLsText(summary.relayURLs))
                        DetailRow("DNS discovery", summary.dnsServer ?? "default")
                    }
                }

                if let error = proxy.lastError {
                    DetailRow("Last error", error, valueColor: .red)
                }

                Divider()

                Button(role: .destructive, action: onStopAndReconfigure) {
                    Label("Stop and Reconfigure", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .frame(minWidth: 300, idealWidth: 340, maxHeight: 520)
    }

    private var healthTitle: String {
        proxy.healthy ? "Tunnel is healthy" : "Tunnel is unavailable"
    }

    private var healthIcon: String {
        proxy.healthy ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var healthColor: Color {
        proxy.healthy ? .green : .red
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
