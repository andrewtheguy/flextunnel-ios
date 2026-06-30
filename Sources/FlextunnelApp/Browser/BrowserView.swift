import SwiftUI
import WebKit

/// Full-screen browser chrome over the proxied `WebPage`s: a lightweight tab
/// strip, the web view with a thin progress bar, and a bottom toolbar with
/// back/forward, reload-or-stop, and the address bar.
struct BrowserView: View {
    @State var model: BrowserModel
    @ObservedObject var proxy: ProxyController
    @Environment(\.dismiss) private var dismiss
    @State private var showingTunnelStatus = false

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(model: model, proxyAvailable: proxyAvailable)
            Divider()

            let tab = model.selectedTab
            WebView(tab.page)
                .webViewBackForwardNavigationGestures(.enabled)
                .overlay(alignment: .top) { progressBar(for: tab.page) }
                .overlay(alignment: .bottom) { errorBanner(for: tab) }

            Divider()
            BottomToolbarView(
                model: model,
                proxyAvailable: proxyAvailable,
                tunnelStatusIcon: tunnelStatusIcon,
                tunnelStatusColor: tunnelStatusColor,
                showingTunnelStatus: $showingTunnelStatus)
        }
        .popover(isPresented: $showingTunnelStatus) {
            TunnelStatusPopover(
                proxy: proxy,
                boundPort: model.socksPort,
                onDismiss: { showingTunnelStatus = false },
                onStopAndReconfigure: stopAndDismiss)
                .presentationCompactAdaptation(.sheet)
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

    private func enforceProxyAvailability() {
        model.proxyIsAvailable = proxyAvailable
        guard proxyAvailable else {
            model.stopAll()
            showingTunnelStatus = false
            dismiss()
            return
        }
    }

    private func stopAndDismiss() {
        model.stopAll()
        proxy.stop()
        showingTunnelStatus = false
        dismiss()
    }

    @ViewBuilder
    private func progressBar(for page: WebPage) -> some View {
        if page.isLoading && page.estimatedProgress < 1 {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private func errorBanner(for tab: BrowserTab) -> some View {
        if let error = tab.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).font(.footnote).lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    tab.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                }
            }
            .padding(10)
            .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

/// Horizontal strip of tab chips with a trailing "+" to open a new tab.
private struct TabStripView: View {
    @Bindable var model: BrowserModel
    let proxyAvailable: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isSelected: tab.id == model.selectedID,
                        onSelect: { model.select(tab) },
                        onClose: { model.closeTab(tab) },
                        showClose: model.tabs.count > 1)
                }
                Button(action: model.addTab) {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.bordered)
                .disabled(!proxyAvailable)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct TabChip: View {
    let tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let showClose: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Text(tab.displayTitle)
                    .font(.footnote)
                    .lineLimit(1)
                    .frame(maxWidth: 140)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            if showClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor : .clear))
    }
}

/// Back / forward / reload-or-stop controls plus the address bar.
private struct BottomToolbarView: View {
    @Bindable var model: BrowserModel
    let proxyAvailable: Bool
    let tunnelStatusIcon: String
    let tunnelStatusColor: Color
    @Binding var showingTunnelStatus: Bool
    @State private var editText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 12) {
            Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!proxyAvailable || !tab.canGoBack)
            Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!proxyAvailable || !tab.canGoForward)
            Button {
                if tab.page.isLoading { tab.stop() } else { tab.reload() }
            } label: {
                Image(systemName: tab.page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(!proxyAvailable)

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

            Button {
                showingTunnelStatus = true
            } label: {
                Image(systemName: tunnelStatusIcon)
                    .foregroundStyle(tunnelStatusColor)
            }
            .accessibilityLabel("Tunnel status")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        // Reflect the active tab's URL when not editing; show the raw URL while editing.
        .onChange(of: model.selectedID) { syncAddress(tab.page.url) }
        .onChange(of: tab.page.url) { if !addressFocused { syncAddress(tab.page.url) } }
        .onChange(of: addressFocused) { if addressFocused { editText = tab.page.url?.absoluteString ?? editText } }
        .onAppear { syncAddress(tab.page.url) }
    }

    private func syncAddress(_ url: URL?) {
        editText = url?.absoluteString ?? ""
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
