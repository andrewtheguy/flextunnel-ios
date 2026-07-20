import SwiftUI

/// On-demand "connection path" readout: a point-in-time snapshot of how the
/// current session reaches the server (the live iroh relay/direct paths),
/// mirroring the desktop's connection-path modal and `ezvpn client status`.
///
/// Presented as a sheet from the tunnel-status surfaces (browser popover and the
/// proxy-only screen), which only offer it while the tunnel link is up — the
/// core routes over no path while disconnected, so the snapshot would be empty.
/// The snapshot is captured on appear and re-captured by Refresh; like the
/// desktop modal it is a point-in-time check, not a live field.
struct ConnPathSheet: View {
    /// Snapshots the live paths + custom-relay health right now
    /// (`ProxyController.queryConnPath()`).
    let query: () -> ProxyController.ConnectionSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot = ProxyController.ConnectionSnapshot()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if snapshot.paths.isEmpty {
                        Text("No path yet — still establishing. Close this and try again in a moment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.paths) { path in
                            ConnPathRow(path: path)
                        }
                    }
                } footer: {
                    Text("Snapshot taken just now — how this session reaches the server. Direct paths are peer-to-peer; relay paths hop through an iroh relay.")
                }

                if !snapshot.customRelays.isEmpty {
                    Section {
                        ForEach(snapshot.customRelays) { relay in
                            CustomRelayRow(relay: relay)
                        }
                    } header: {
                        Text("Custom relays")
                    } footer: {
                        Text("Health is a one-shot check of each relay's /healthz endpoint. It confirms the relay is reachable, not that a relay auth token is accepted.")
                    }
                }
            }
            .navigationTitle("Connection path")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        snapshot = query()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .onAppear { snapshot = query() }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One custom-relay row: its URL and a colored health status from the on-demand
/// `/healthz` probe (`working` = up / down / unknown).
private struct CustomRelayRow: View {
    let relay: ProxyController.CustomRelay

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(relay.url)
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(dotColor)
        }
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        switch relay.working {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }

    private var statusText: String {
        switch relay.working {
        case .some(true): return "Working"
        case .some(false):
            if let error = relay.error, !error.isEmpty {
                return "Not working — \(error)"
            }
            return "Not working"
        case .none: return "Status unavailable"
        }
    }
}

/// One path row: a transport-colored dot, the human-readable path line, and an
/// "active" pill on the path iroh currently routes over.
private struct ConnPathRow: View {
    let path: ProxyController.ConnPath

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(path.display)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if path.selected {
                Text("active")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        switch path.kind {
        case .direct: return .green
        case .relay: return .orange
        case .other: return .gray
        }
    }
}
