import CoreLocation
import Foundation

/// Location-based background keep-alive for the port-forwarding session — the
/// same technique Termius and Blink use: while a continuous Core Location
/// session is running, iOS does not suspend the app, so the server-direct port
/// forwards stay reachable from other apps indefinitely instead of dying
/// ~30s after backgrounding.
///
/// Runs while a proxy-only session is up (`setSessionActive`) and the persisted
/// `enabled` preference is on (off by default, like Termius's opt-in setting).
/// The accuracy is deliberately coarse (100 km, like Blink's `geo track`) so
/// fixes come from cell towers rather than the GPS radio, and every fix is
/// discarded — the session exists only to keep the process alive, and it stops
/// with the session so the location indicator never outlives it.
@MainActor
final class BackgroundKeepAlive: NSObject, ObservableObject {
    /// The persisted "Keep alive in background" preference; off by default, so
    /// no location prompt until the user opts in.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            reconcile()
        }
    }
    @Published private(set) var authorization: CLAuthorizationStatus
    /// Whether the location session is currently running.
    @Published private(set) var isRunning = false

    private static let defaultsKey = "keepAliveInBackground"
    private let manager: CLLocationManager
    private var sessionActive = false

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Location permission is missing, so forwards die shortly after
    /// backgrounding — surfaced in the UI with a path to Settings.
    var denied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// Follows the proxy-only session: the keep-alive runs only while one is up.
    func setSessionActive(_ active: Bool) {
        sessionActive = active
        reconcile()
    }

    private func reconcile() {
        guard enabled && sessionActive else {
            stopUpdates()
            return
        }
        switch authorization {
        case .notDetermined:
            // Updates start from the grant's authorization callback.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdates()
        default:
            stopUpdates() // denied/restricted; see `denied`
        }
    }

    private func startUpdates() {
        guard !isRunning else { return }
        manager.desiredAccuracy = 100_000 // coarse on purpose: no GPS, minimal battery
        manager.pausesLocationUpdatesAutomatically = false
        // Requires the `location` UIBackgroundModes entry in Info.plist.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true
    }

    private func stopUpdates() {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        isRunning = false
    }
}

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.reconcile()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        // Fixes are discarded — the updates exist only to keep the app alive.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient fix failures (indoors, airplane mode) don't stop the
        // session; the running session is what keeps the app alive.
    }
}
