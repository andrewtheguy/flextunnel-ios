import ActivityKit
import Foundation
import os

/// Owns the single tunnel Live Activity: request it once the session connects,
/// push state updates as the link flaps, and end it on an explicit Stop. This is
/// UX only — it neither grants nor relies on background execution (see the
/// keep-alive note in `ContentView.handleScenePhase`). If the user has Live
/// Activities disabled system-wide, every call is a no-op.
@MainActor
final class LiveActivityController {
    private var activity: Activity<TunnelActivityAttributes>?
    private let log = Logger(subsystem: "com.andrewtheguy.flextunnel", category: "LiveActivity")

    /// Reattach to a Live Activity that outlived a previous run (Live Activities
    /// survive force-quit/relaunch). Without this the fresh `nil` reference would
    /// orphan that banner — `end()` couldn't reach it and `start()` would spawn a
    /// duplicate. Only one is ever expected; end any extras defensively. Callers
    /// then `syncLiveActivity()` (from `onAppear`) to reconcile it with real state.
    init() {
        let survivors = Activity<TunnelActivityAttributes>.activities
        activity = survivors.first
        for extra in survivors.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// How long a pushed state stays trustworthy. Past this the widget flips to a
    /// "status unknown — open app" look (via `context.isStale`) instead of showing
    /// a confidently-stale value. This matters while the app keeps running but
    /// stops updating (e.g. a location-keep-alive session in the background); when
    /// the app is actually suspended the banner is instead dismissed outright
    /// (`ContentView`'s background-task expiration handler calls `end()`).
    private static let staleAfter: TimeInterval = 90

    /// Start the activity, or update it if one is already live (so callers can
    /// treat this as idempotent "reflect the connected state"). If a previous
    /// activity is `.ended`/`.dismissed` (e.g. a survivor reattached on launch),
    /// drop it and request a fresh one so the banner reappears for a still-
    /// connected session.
    func start(serverLabel: String, modeTitle: String, state: TunnelActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let current = activity {
            switch current.activityState {
            case .active, .stale:
                update(state)
                return
            case .ended, .dismissed:
                // Already gone/ending (e.g. a survivor reattached on launch). Pull
                // it now so it can't linger alongside the fresh one, then request.
                Task { await current.end(nil, dismissalPolicy: .immediate) }
                activity = nil
            @unknown default:
                break
            }
        }
        let attributes = TunnelActivityAttributes(serverLabel: serverLabel, modeTitle: modeTitle)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content(state),
                pushType: nil
            )
        } catch {
            log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ state: TunnelActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(content(state)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Await variant of `end()` for the background-task expiration handler: the
    /// caller must hold the task assertion until the dismissal actually registers,
    /// otherwise the app can suspend before the async end lands and the banner is
    /// left behind.
    func endNow() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func content(
        _ state: TunnelActivityAttributes.ContentState
    ) -> ActivityContent<TunnelActivityAttributes.ContentState> {
        .init(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }
}
