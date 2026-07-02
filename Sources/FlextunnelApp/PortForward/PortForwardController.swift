import Foundation
import Combine

/// Owns the persisted forward list and the live `PortForwarder`s. Forwards are
/// stored as JSON in Application Support (same at-rest treatment as
/// `BrowserLibrary`: Data Protection until first unlock, excluded from backups —
/// targets are internal hostnames, the same sensitivity class as history).
///
/// Enabled forwards auto-start whenever the SOCKS5 listener is up and stop when
/// it goes away; `ContentView` feeds proxy state in via `syncProxy`.
@MainActor
final class PortForwardController: ObservableObject {
    struct RuntimeStatus: Equatable {
        var state: PortForwardState = .stopped
        var connectionCount: Int = 0
    }

    @Published private(set) var forwards: [PortForward]
    @Published private(set) var runtime: [UUID: RuntimeStatus] = [:]

    private var forwarders: [UUID: PortForwarder] = [:]
    /// The SOCKS port forwards currently relay through; nil while the proxy is down.
    private var socksPort: UInt16?
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        Self.prepareDirectory(dir)
        fileURL = dir.appendingPathComponent("forwards.json")
        forwards = Self.load([PortForward].self, from: fileURL) ?? []
    }

    // MARK: - Proxy lifecycle

    /// Reconciles the running forwarders with the proxy state. Any effective
    /// port change (up, down, or rebind) restarts everything on the new port.
    func syncProxy(socksAlive: Bool, socksPort: UInt16?) {
        let newPort = socksAlive ? socksPort : nil
        guard newPort != self.socksPort else { return }
        self.socksPort = newPort
        stopAllForwarders()
        if newPort != nil {
            forwards.filter(\.enabled).forEach(startForwarder)
        }
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

    // MARK: - Forwarders

    private func startForwarder(_ forward: PortForward) {
        guard let socksPort else { return }
        stopForwarder(id: forward.id)
        let forwarder = PortForwarder(forward: forward, socksPort: socksPort)
        let id = forward.id
        forwarder.onStatus = { [weak self] state, count in
            Task { @MainActor in
                self?.runtime[id] = RuntimeStatus(state: state, connectionCount: count)
            }
        }
        forwarders[id] = forwarder
        forwarder.start()
    }

    private func stopForwarder(id: UUID) {
        forwarders.removeValue(forKey: id)?.cancel()
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
