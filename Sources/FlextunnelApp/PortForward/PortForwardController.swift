import Foundation
import Combine

/// Owns the persisted forward list and the live `PortForwarder`s. Forwards are
/// stored as JSON in Application Support (same at-rest treatment as
/// `BrowserLibrary`: Data Protection until first unlock, excluded from backups —
/// targets are internal hostnames, the same sensitivity class as history).
///
/// Forward definitions persist; the enabled state is per-session by design —
/// it is never persisted (see `PortForward.CodingKeys`), so launches load
/// everything off, and a fresh session start in the same run disables
/// everything again (`disableAll`). A toggle turned on then lives with the
/// SOCKS5 listener (running while it's up, restarted across mid-session
/// reconnects and port changes, stopped when it goes away); `ContentView`
/// feeds proxy state in via `syncProxy`.
@MainActor
final class PortForwardController: ObservableObject {
    struct RuntimeStatus: Equatable {
        var state: PortForwardState = .stopped
        var connectionCount: Int = 0
    }

    @Published private(set) var forwards: [PortForward]
    @Published private(set) var runtime: [UUID: RuntimeStatus] = [:]

    private var forwarders: [UUID: PortForwarder] = [:]
    /// Forwards whose current forwarder reached `.listening` at least once.
    /// Distinguishes an *initial setup* failure (never listened — e.g. the
    /// local port is in use), which auto-stops the forward and flips its
    /// toggle back off, from a later failure (listeners dying around app
    /// suspension), which keeps it enabled so it resumes with the session.
    private var everListened: Set<UUID> = []
    /// The SOCKS port forwards currently relay through; nil while the proxy is down.
    private var socksPort: UInt16?
    /// One wrong-instance probe per proxy session, shared by all forwarders
    /// (see `InstanceProbe`); recreated whenever the session changes.
    private var probe: InstanceProbe?
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        Self.prepareDirectory(dir)
        fileURL = dir.appendingPathComponent("forwards.json")
        forwards = Self.load([PortForward].self, from: fileURL) ?? []
    }

    // MARK: - Proxy lifecycle

    /// Reconciles the running forwarders with the proxy state. Any effective
    /// port change (up, down, or rebind) restarts everything on the new port,
    /// with a fresh wrong-instance probe for the new session.
    func syncProxy(socksAlive: Bool, socksPort: UInt16?, serverNodeID: String?) {
        let newPort = socksAlive ? socksPort : nil
        guard newPort != self.socksPort else { return }
        self.socksPort = newPort
        stopAllForwarders()
        if let newPort, let serverNodeID {
            probe = InstanceProbe(socksPort: newPort, expectedNodeID: serverNodeID)
            forwards.filter(\.enabled).forEach(startForwarder)
        } else {
            probe = nil
        }
    }

    /// Called on return to foreground after the process was suspended (the
    /// background grace expired without the location keep-alive holding it).
    /// iOS defuncts the listeners' sockets during suspension, and a defunct
    /// `NWListener` may never report failure — it can sit in a stale `.ready`
    /// showing "listening" while clients can't connect — so every enabled
    /// forward is rebound rather than trusting the reported state. Open relays
    /// are dropped with it; connections that spanned a suspension are dead
    /// anyway.
    func rebindAfterSuspension() {
        guard socksPort != nil else { return } // proxy died; syncProxy owns teardown
        forwards.filter(\.enabled).forEach(startForwarder)
    }

    // MARK: - CRUD (persist + live-apply)

    func add(_ forward: PortForward) {
        forwards.append(forward)
        persist()
        if forward.enabled { startForwarder(forward) }
    }

    func update(_ forward: PortForward) {
        guard let index = forwards.firstIndex(where: { $0.id == forward.id }) else { return }
        forwards[index] = forward
        persist()
        stopForwarder(id: forward.id)
        if forward.enabled { startForwarder(forward) }
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets {
            stopForwarder(id: forwards[index].id)
            runtime[forwards[index].id] = nil
        }
        forwards.remove(atOffsets: offsets)
        persist()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard var forward = forwards.first(where: { $0.id == id }) else { return }
        forward.enabled = enabled
        update(forward)
    }

    /// Whether another forward already claims this local port (edit validation).
    func isLocalPortTaken(_ port: UInt16, excluding id: UUID?) -> Bool {
        forwards.contains { $0.localPort == port && $0.id != id }
    }

    /// Flip every forward off (stopping any that run). A fresh session start
    /// goes through this so forwards never auto-start with the session — the
    /// toggles are per-session opt-in; only a mid-session reconnect keeps them.
    func disableAll() {
        for forward in forwards where forward.enabled {
            setEnabled(false, id: forward.id)
        }
    }

    // MARK: - Forwarders

    private func startForwarder(_ forward: PortForward) {
        guard let socksPort, let probe else { return }
        stopForwarder(id: forward.id)
        let forwarder = PortForwarder(forward: forward, socksPort: socksPort, probe: probe)
        let id = forward.id
        everListened.remove(id) // a fresh attempt must prove itself again
        forwarder.onStatus = { [weak self] state, count in
            Task { @MainActor in
                self?.handleStatus(id: id, state: state, count: count)
            }
        }
        forwarders[id] = forwarder
        forwarder.start()
    }

    /// Runtime-status sink for the live forwarders. The toggle is start/stop:
    /// a failure before the forward ever listened means its initial setup
    /// failed, so the forward is stopped and its toggle flipped back off, with
    /// the reason left on the row (until the next start attempt resets it).
    private func handleStatus(id: UUID, state: PortForwardState, count: Int) {
        guard forwarders[id] != nil else { return } // stale callback after a stop
        if case .listening = state {
            everListened.insert(id)
        }
        if case .failed = state, !everListened.contains(id) {
            forwarders.removeValue(forKey: id)?.cancel()
            if let index = forwards.firstIndex(where: { $0.id == id }) {
                forwards[index].enabled = false
                persist()
            }
            runtime[id] = RuntimeStatus(state: state, connectionCount: 0)
            return
        }
        runtime[id] = RuntimeStatus(state: state, connectionCount: count)
    }

    private func stopForwarder(id: UUID) {
        forwarders.removeValue(forKey: id)?.cancel()
        everListened.remove(id)
        runtime[id] = RuntimeStatus()
    }

    private func stopAllForwarders() {
        forwarders.values.forEach { $0.cancel() }
        forwarders.removeAll()
        runtime = forwards.reduce(into: [:]) { $0[$1.id] = RuntimeStatus() }
    }

    // MARK: - Persistence (mirrors BrowserLibrary)

    private func persist() {
        Self.save(forwards, to: fileURL)
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PortForwards", isDirectory: true)
    }

    private static func prepareDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dir = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
