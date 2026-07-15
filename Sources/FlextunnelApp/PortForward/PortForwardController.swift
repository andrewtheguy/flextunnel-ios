import Foundation
import Combine

/// Owns persisted forward definitions and reconciles them with the Rust core's
/// server-direct listener manager. Forward definitions persist; enablement is
/// per-session and is never encoded by `PortForward`.
@MainActor
final class PortForwardController: ObservableObject {
    struct RuntimeStatus: Equatable {
        var state: PortForwardState = .stopped
        var connectionCount: Int = 0
        var lastConnectionError: String?
    }

    @Published private(set) var forwards: [PortForward]
    @Published private(set) var runtime: [UUID: RuntimeStatus] = [:]

    private weak var proxy: ProxyController?
    private var sessionID: UUID?
    /// A setup failure auto-disables only if the native listener never reached
    /// `.listening` during this start attempt.
    private var everListened: Set<UUID> = []
    /// Initial bind failures remain visible after the toggle is auto-disabled.
    private var retainedSetupErrors: [UUID: String] = [:]
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        Self.prepareDirectory(dir)
        fileURL = dir.appendingPathComponent("forwards.json")
        forwards = Self.load([PortForward].self, from: fileURL) ?? []
    }

    // MARK: - Tunnel lifecycle

    /// Attach to the current native session. A replacement session gets the
    /// complete desired set immediately; a stopped session clears runtime state.
    func syncProxy(_ proxy: ProxyController) {
        let newID = proxy.forwardingSessionID
        if newID == sessionID {
            refreshRuntime()
            return
        }
        sessionID = newID
        self.proxy = newID == nil ? nil : proxy
        everListened.removeAll()
        retainedSetupErrors.removeAll()
        runtime = forwards.reduce(into: [:]) { $0[$1.id] = RuntimeStatus() }
        if newID != nil {
            applyDesired()
            refreshRuntime()
        }
    }

    /// A relaunched native session owns fresh sockets. Reapply the complete set;
    /// this is also harmless if the session replacement notification already did.
    func rebindAfterSuspension() {
        guard sessionID != nil else { return }
        applyDesired()
        refreshRuntime()
    }

    // MARK: - CRUD

    func add(_ forward: PortForward) {
        forwards.append(forward)
        persist()
        everListened.remove(forward.id)
        retainedSetupErrors[forward.id] = nil
        applyDesired()
    }

    func update(_ forward: PortForward) {
        guard let index = forwards.firstIndex(where: { $0.id == forward.id }) else { return }
        forwards[index] = forward
        persist()
        everListened.remove(forward.id)
        retainedSetupErrors[forward.id] = nil
        runtime[forward.id] = RuntimeStatus()
        applyDesired()
    }

    func remove(atOffsets offsets: IndexSet) {
        let ids = offsets.map { forwards[$0].id }
        forwards.remove(atOffsets: offsets)
        for id in ids {
            everListened.remove(id)
            retainedSetupErrors[id] = nil
            runtime[id] = nil
        }
        persist()
        applyDesired()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        forwards[index].enabled = enabled
        everListened.remove(id)
        retainedSetupErrors[id] = nil
        runtime[id] = RuntimeStatus()
        persist()
        applyDesired()
    }

    func isLocalPortTaken(_ port: UInt16, excluding id: UUID?) -> Bool {
        forwards.contains { $0.localPort == port && $0.id != id }
    }

    func disableAll() {
        var changed = false
        for index in forwards.indices where forwards[index].enabled {
            forwards[index].enabled = false
            changed = true
        }
        guard changed else { return }
        everListened.removeAll()
        retainedSetupErrors.removeAll()
        runtime = forwards.reduce(into: [:]) { $0[$1.id] = RuntimeStatus() }
        persist()
        applyDesired()
    }

    // MARK: - Native manager

    private func applyDesired() {
        guard let proxy, proxy.sessionAlive, sessionID != nil else { return }
        if let error = proxy.setPortForwards(forwards) {
            for forward in forwards where forward.enabled {
                runtime[forward.id] = RuntimeStatus(state: .failed(error))
            }
            return
        }
        refreshRuntime()
    }

    func refreshRuntime() {
        guard let proxy, proxy.sessionAlive, sessionID != nil,
              let statuses = proxy.portForwardStatuses() else { return }

        var next = forwards.reduce(into: [UUID: RuntimeStatus]()) { result, forward in
            if let error = retainedSetupErrors[forward.id] {
                result[forward.id] = RuntimeStatus(state: .failed(error))
            } else {
                result[forward.id] = RuntimeStatus()
            }
        }
        var autoDisabled = false
        for forward in forwards where forward.enabled {
            guard let status = statuses[forward.id] else {
                next[forward.id] = RuntimeStatus(state: .starting)
                continue
            }
            if case .listening = status.state {
                everListened.insert(forward.id)
            }
            if case .failed = status.state, !everListened.contains(forward.id) {
                if let index = forwards.firstIndex(where: { $0.id == forward.id }) {
                    forwards[index].enabled = false
                    autoDisabled = true
                }
                if case .failed(let error) = status.state {
                    retainedSetupErrors[forward.id] = error
                }
            }
            next[forward.id] = RuntimeStatus(
                state: status.state,
                connectionCount: status.active,
                lastConnectionError: status.lastConnectionError)
        }
        runtime = next
        if autoDisabled {
            persist()
            applyDesired()
        }
    }

    // MARK: - Persistence

    private func persist() {
        Self.save(forwards, to: fileURL)
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)) ?? FileManager.default.temporaryDirectory
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
        try? data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
