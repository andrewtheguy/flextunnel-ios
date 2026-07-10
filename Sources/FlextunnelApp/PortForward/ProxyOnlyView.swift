import SwiftUI
import UIKit

/// Full-screen proxy-only session: tunnel status, the bound SOCKS endpoint, and
/// the managed port forwards — no browser. Other apps on the device reach the
/// forwards (and the SOCKS proxy itself) at 127.0.0.1 while this app is alive;
/// the location keep-alive (see `BackgroundKeepAlive`) holds the session in the
/// background, falling back to best-effort (~30s before suspension) when
/// location permission is denied.
struct ProxyOnlyView: View {
    @ObservedObject var proxy: ProxyController
    @ObservedObject var store: PortForwardController
    @ObservedObject var keepAlive: BackgroundKeepAlive
    let onStop: () -> Void

    @State private var editingDraft: ForwardDraft?
    /// Drives the on-demand connection-path snapshot sheet.
    @State private var showingConnPath = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                forwardsSection
                backgroundSection

                Section {
                    // Offered whenever the link is down, not just when the proxy
                    // died: if the core's own reconnect is stuck this is the only
                    // way out — it relaunches the session.
                    if !proxy.socksAlive || !proxy.tunnelConnected {
                        Button {
                            proxy.retryNow()
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }
                    }
                    Button(role: .destructive, action: onStop) {
                        Label("Stop Proxy", systemImage: "stop.circle")
                    }
                }
            }
            .navigationTitle("Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingDraft = ForwardDraft()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add port forward")
                }
            }
            .sheet(item: $editingDraft) { draft in
                ForwardEditSheet(
                    draft: draft,
                    socksPort: proxy.socksPort,
                    isLocalPortTaken: { store.isLocalPortTaken($0, excluding: draft.existingID) },
                    onSave: { forward in
                        if draft.existingID != nil {
                            store.update(forward)
                        } else {
                            store.add(forward)
                        }
                    })
            }
            .sheet(isPresented: $showingConnPath) {
                ConnPathSheet(query: { proxy.queryConnPath() })
            }
        }
    }

    // MARK: - Status

    /// Mirrors the browser's TunnelStatusPopover row-for-row so both surfaces
    /// report the tunnel at the same level of detail.
    private var statusSection: some View {
        Section("Tunnel") {
            HStack {
                Label(healthTitle, systemImage: healthIcon)
                    .font(.headline)
                    .foregroundStyle(healthColor)
                Spacer()
                if proxy.socksAlive && !proxy.tunnelConnected && !proxy.tunnelStuck {
                    ProgressView()
                }
            }

            InfoRow("State", proxy.status)
            InfoRow("SOCKS proxy", proxy.socksAlive ? "running" : "stopped",
                    valueColor: proxy.socksAlive ? .green : .red)
            InfoRow("Tunnel link", tunnelLinkText, valueColor: healthColor)
            if let port = proxy.socksPort {
                InfoRow("Bound SOCKS", "127.0.0.1:\(port)", monospace: true)
            }
            if let summary = proxy.connectionSummary {
                InfoRow("Server node id", summary.serverNodeID, monospace: true)
                InfoRow("Relay URLs", summary.relayURLs.isEmpty
                    ? "iroh defaults"
                    : summary.relayURLs.joined(separator: "\n"))
                InfoRow("iroh DNS discovery", summary.dnsServer ?? "iroh discovery")
            }

            forwardedRoutesRows

            // One-shot snapshot of the live iroh path, shown in its own sheet — a
            // point-in-time check. Only offered while the link is up (the snapshot
            // is empty otherwise), so it appears and disappears with the tunnel,
            // mirroring the desktop CTA.
            if proxy.tunnelConnected {
                Button {
                    showingConnPath = true
                } label: {
                    Label("Connection path", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }

            if let error = proxy.lastError {
                InfoRow("Last error", error, valueColor: .red)
            }

            if proxy.socksAlive && !proxy.tunnelConnected {
                Text(proxy.tunnelStuck
                    ? "The tunnel hasn't reconnected on its own — Reconnect relaunches the session. Direct forwards keep working; tunneled forwards are unavailable."
                    : "Direct forwards keep working; tunneled forwards are unavailable until the link recovers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The tunnel set the server pushed — same presentation as the popover:
    /// "Full tunnel" or the routed domains/CIDRs, shown even while the link is
    /// down so it's clear which forward targets are temporarily unavailable.
    @ViewBuilder
    private var forwardedRoutesRows: some View {
        if let routes = proxy.forwardedRoutes {
            if routes.isFullTunnel {
                InfoRow("Tunnel set", "Full tunnel (all traffic)")
            } else {
                if !routes.domains.isEmpty {
                    InfoRow("Tunneled domains", routes.domains.joined(separator: "\n"), monospace: true)
                }
                if !routes.cidrs.isEmpty {
                    InfoRow("Tunneled CIDRs", routes.cidrs.joined(separator: "\n"), monospace: true)
                }
            }
            if !routes.hostAliases.isEmpty {
                InfoRow(
                    "Host aliases",
                    routes.hostAliases.map { "\($0.alias) → \($0.target)" }.joined(separator: "\n"),
                    monospace: true)
            }
            if !routes.dnsForwards.isEmpty {
                InfoRow(
                    "DNS forwards",
                    routes.dnsForwards
                        .map { "\($0.suffix) (+ subdomains) → \($0.servers.joined(separator: ", "))" }
                        .joined(separator: "\n"),
                    monospace: true)
            }
            if !routes.bridges.isEmpty {
                InfoRow(
                    "Bridge routes",
                    routes.bridges.map(\.summary).joined(separator: "\n\n"),
                    monospace: true)
            }
            if !routes.agentRoutes.isEmpty {
                InfoRow(
                    "Agent routes",
                    routes.agentRoutes
                        .map { "\($0.name) — \($0.status.rawValue)" }
                        .joined(separator: "\n"),
                    monospace: true)
            }
        }
    }

    // MARK: - Forwards

    private var forwardsSection: some View {
        Section {
            if store.forwards.isEmpty {
                Text("No port forwards. Tap + to forward a local port to a private host through the tunnel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.forwards) { forward in
                ForwardRow(
                    forward: forward,
                    status: store.runtime[forward.id] ?? .init(),
                    routes: proxy.forwardedRoutes,
                    onToggle: { store.setEnabled($0, id: forward.id) })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingDraft = ForwardDraft(forward: forward)
                    }
            }
            .onDelete { store.remove(atOffsets: $0) }
        } header: {
            Text("Port forwards")
        } footer: {
            Text("Forwards listen on localhost (127.0.0.1 and ::1) and are reachable from other apps on this device while flextunnel is running.")
        }
    }

    // MARK: - Background keep-alive

    /// The keep-alive setting, its live status, and — when location permission
    /// is missing — the path to fix it.
    private var backgroundSection: some View {
        Section {
            Toggle("Keep alive in background", isOn: $keepAlive.enabled)
            if keepAlive.enabled {
                if keepAlive.denied {
                    Text("Location access is denied, so iOS suspends the app about 30 seconds after backgrounding and forwards stop until you return.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Allow location in Settings", systemImage: "location.slash")
                    }
                } else {
                    InfoRow(
                        "Background keep-alive",
                        keepAlive.isRunning ? "active" : "starts with the session",
                        valueColor: keepAlive.isRunning ? .green : nil)
                }
            }
        } header: {
            Text("Background")
        } footer: {
            Text(keepAlive.enabled
                ? "A coarse location session (fixes are discarded, nothing is stored or sent) keeps iOS from suspending the app, so forwards stay reachable while you use other apps. It stops when you stop the proxy. Expect the location indicator and some extra battery use."
                : "iOS suspends the app about 30 seconds after backgrounding; forwards stop until you return.")
        }
    }

    private var tunnelLinkText: String {
        if proxy.tunnelConnected { return "connected" }
        if !proxy.socksAlive { return "down" }
        return proxy.tunnelStuck ? "disconnected" : "reconnecting"
    }

    private var healthTitle: String {
        if proxy.tunnelConnected { return "Tunnel connected" }
        if proxy.tunnelStuck { return "Tunnel disconnected" }
        if proxy.socksAlive { return "Tunnel reconnecting" }
        return "Tunnel unavailable"
    }

    private var healthIcon: String {
        if proxy.tunnelConnected { return "bolt.horizontal.circle.fill" }
        return proxy.tunnelStuck ? "bolt.slash.circle" : "bolt.horizontal.circle"
    }

    private var healthColor: Color {
        if proxy.tunnelConnected { return .green }
        if proxy.tunnelStuck { return .red }
        if proxy.socksAlive { return .orange }
        return .red
    }
}

// MARK: - Forward row

private struct ForwardRow: View {
    let forward: PortForward
    let status: PortForwardController.RuntimeStatus
    let routes: ProxyController.ForwardedRoutes?
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(forward.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    routeBadge
                }
                Text(forward.routeDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusLine
            }
            Spacer()
            Toggle("", isOn: Binding(get: { forward.enabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var routeBadge: some View {
        if forward.enabled, let routes {
            let tunneled = RouteMatch.isTunneled(host: forward.remoteHost, routes: routes)
            Text(tunneled ? "tunneled" : "direct")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tunneled ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(tunneled ? .green : .orange)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status.state {
        case .listening:
            Text(status.connectionCount > 0
                 ? "listening · \(status.connectionCount) active"
                 : "listening")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
        case .stopped:
            Text(forward.enabled ? "stopped" : "off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add/Edit sheet

/// Editable copy of a forward driving the sheet; `existingID` is nil for Add.
private struct ForwardDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var label = ""
    var localPortText = ""
    var remoteHost = ""
    var remotePortText = ""
    var enabled = true

    init() {}

    init(forward: PortForward) {
        existingID = forward.id
        label = forward.label
        localPortText = String(forward.localPort)
        remoteHost = forward.remoteHost
        remotePortText = String(forward.remotePort)
        enabled = forward.enabled
    }
}

private struct ForwardEditSheet: View {
    @State var draft: ForwardDraft
    let socksPort: UInt16?
    let isLocalPortTaken: (UInt16) -> Bool
    let onSave: (PortForward) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Local") {
                    TextField("Local port (e.g. 8080)", text: $draft.localPortText)
                        .keyboardType(.numberPad)
                        .onChange(of: draft.localPortText) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            if filtered != newValue { draft.localPortText = filtered }
                        }
                    if let localPort = parsedLocalPort, localPort < 1024 {
                        Text("Ports below 1024 usually can't be bound by apps.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Remote target") {
                    TextField("Host or IP (resolved through tunnel)", text: $draft.remoteHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Port (e.g. 22)", text: $draft.remotePortText)
                        .keyboardType(.numberPad)
                        .onChange(of: draft.remotePortText) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            if filtered != newValue { draft.remotePortText = filtered }
                        }
                }
                Section("Options") {
                    TextField("Label (optional)", text: $draft.label)
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                if let message = validationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(draft.existingID == nil ? "Add Forward" : "Edit Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let forward = builtForward {
                            onSave(forward)
                            dismiss()
                        }
                    }
                    .disabled(builtForward == nil)
                }
            }
        }
    }

    private var parsedLocalPort: UInt16? { parsePort(draft.localPortText) }
    private var parsedRemotePort: UInt16? { parsePort(draft.remotePortText) }
    private var trimmedHost: String {
        draft.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parsePort(_ text: String) -> UInt16? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }

    /// Non-nil once every field validates; drives Save.
    private var builtForward: PortForward? {
        guard let localPort = parsedLocalPort,
              let remotePort = parsedRemotePort,
              !trimmedHost.isEmpty,
              localPort != socksPort,
              !isLocalPortTaken(localPort) else { return nil }
        return PortForward(
            id: draft.existingID ?? UUID(),
            label: draft.label.trimmingCharacters(in: .whitespacesAndNewlines),
            localPort: localPort,
            remoteHost: trimmedHost,
            remotePort: remotePort,
            enabled: draft.enabled)
    }

    private var validationMessage: String? {
        if draft.localPortText.isEmpty && trimmedHost.isEmpty && draft.remotePortText.isEmpty {
            return nil // pristine form; no nagging
        }
        if !draft.localPortText.isEmpty && parsedLocalPort == nil {
            return "Local port must be 1–65535."
        }
        if let localPort = parsedLocalPort {
            if localPort == socksPort {
                return "Port \(localPort) is the SOCKS proxy port."
            }
            if isLocalPortTaken(localPort) {
                return "Another forward already uses local port \(localPort)."
            }
        }
        if !draft.remotePortText.isEmpty && parsedRemotePort == nil {
            return "Remote port must be 1–65535."
        }
        return nil
    }
}

/// Same shape as the tunnel popover's DetailRow (private to BrowserView.swift);
/// duplicated here rather than shared — it's a trivial two-Text row.
private struct InfoRow: View {
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
    }
}
