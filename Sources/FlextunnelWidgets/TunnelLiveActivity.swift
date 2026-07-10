import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen banner + Dynamic Island rendering for the tunnel session. Colors
/// follow tunnel-link state: green when connected, orange while reconnecting. Once
/// the pushed state goes stale (`context.isStale` — the app stopped updating, e.g.
/// it was suspended in the background), everything dims to a neutral "status
/// unknown, open app" look so we never show a confidently-wrong "Connected".
struct TunnelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TunnelActivityAttributes.self) { context in
            LockScreenView(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Flextunnel", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusPill(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Open app to refresh" : context.attributes.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(statusColor(context.state, isStale: context.isStale))
            } compactTrailing: {
                Circle()
                    .fill(statusColor(context.state, isStale: context.isStale))
                    .frame(width: 8, height: 8)
            } minimal: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(statusColor(context.state, isStale: context.isStale))
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: TunnelActivityAttributes
    let state: TunnelActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(statusColor(state, isStale: isStale))
            VStack(alignment: .leading, spacing: 2) {
                Text("Flextunnel")
                    .font(.headline)
                    .lineLimit(1)
                Text(isStale ? "Open app to refresh" : attributes.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(state: state, isStale: isStale)
        }
    }
}

private struct StatusPill: View {
    let state: TunnelActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Text(statusText(state, isStale: isStale))
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(state, isStale: isStale))
            .lineLimit(1)
    }
}

/// Neutral once stale; otherwise green connected / orange reconnecting.
private func statusColor(_ state: TunnelActivityAttributes.ContentState, isStale: Bool) -> Color {
    if isStale { return .secondary }
    if state.tunnelConnected { return .green }
    if state.socksAlive { return .orange }
    return .secondary
}

private func statusText(_ state: TunnelActivityAttributes.ContentState, isStale: Bool) -> String {
    isStale ? "Unknown" : state.statusText
}
