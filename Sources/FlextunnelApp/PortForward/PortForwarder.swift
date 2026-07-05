import Foundation
import Network
import os

/// Runtime state of one forward's listener.
enum PortForwardState: Equatable {
    case stopped
    case listening
    case failed(String)
}

/// Serves one `PortForward`: accepts TCP connections on the local port and
/// relays each to the remote target through the in-app SOCKS5 listener, so the
/// core's split-tunnel routing applies exactly as it does for the browser.
///
/// Unlike the SOCKS bind (IPv4-only, bound by the core), a forward listens on
/// **both loopback stacks** — 127.0.0.1 and ::1 — because it exists for other
/// apps on the device, and a client connecting to `localhost` may try ::1
/// first. The forward is usable while either stack is bound; it only reports
/// failure when both are down.
///
/// All state is confined to `queue`; Network.framework delivers every callback
/// there via `start(queue:)`. `onStatus` is invoked on that queue too — the
/// owner hops back to the main actor.
final class PortForwarder {
    /// Called on `queue` with (listener state, active connection count).
    var onStatus: ((PortForwardState, Int) -> Void)?

    private enum ListenerState {
        case pending
        case ready
        case failed(String)
    }

    private let forward: PortForward
    private let socksPort: UInt16
    /// Session-shared wrong-instance guard; every accepted connection awaits it
    /// (instant after the session's first success).
    private let probe: InstanceProbe
    private let queue: DispatchQueue
    private let log = Logger(subsystem: "com.example.flextunnel", category: "portforward")
    /// Keyed by loopback host ("127.0.0.1" / "::1").
    private var listeners: [String: NWListener] = [:]
    private var listenerStates: [String: ListenerState] = [:]
    private var relays: [Relay] = []
    private var state: PortForwardState = .stopped

    init(forward: PortForward, socksPort: UInt16, probe: InstanceProbe) {
        self.forward = forward
        self.socksPort = socksPort
        self.probe = probe
        self.queue = DispatchQueue(label: "portforward.\(forward.localPort)")
    }

    func start() {
        queue.async {
            self.startListener(host: "127.0.0.1")
            self.startListener(host: "::1")
        }
    }

    /// Stops the listeners and drops every relay. Silences `onStatus` first so
    /// a late callback can't overwrite the owner's own "stopped" bookkeeping.
    func cancel() {
        queue.async {
            self.onStatus = nil
            self.listeners.values.forEach { $0.cancel() }
            self.listeners.removeAll()
            self.listenerStates.removeAll()
            let open = self.relays
            self.relays.removeAll()
            open.forEach { $0.close() }
            self.state = .stopped
        }
    }

    // MARK: - Listeners (on queue)

    private func startListener(host: String) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: reachable from other apps on the device, never the LAN.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: forward.localPort)!)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            recordListenerFailure(host, reason: error.localizedDescription)
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listenerStates[host] = .ready
                self.recomputeState()
            case .failed(let error):
                self.listeners.removeValue(forKey: host)?.cancel()
                if case .posix(.EADDRINUSE) = error {
                    self.recordListenerFailure(host, reason: "port \(self.forward.localPort) is in use")
                } else {
                    self.recordListenerFailure(host, reason: error.localizedDescription)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] inbound in
            self?.accept(inbound)
        }
        listeners[host] = listener
        listenerStates[host] = .pending
        listener.start(queue: queue)
    }

    private func recordListenerFailure(_ host: String, reason: String) {
        listenerStates[host] = .failed(reason)
        recomputeState()
    }

    /// One usable stack is enough to be "listening"; failure is reported only
    /// once every listener has failed (pending ones may still come up).
    private func recomputeState() {
        var failures: [String] = []
        var hasPending = false
        for state in listenerStates.values {
            switch state {
            case .ready:
                report(.listening)
                return
            case .failed(let reason):
                failures.append(reason)
            case .pending:
                hasPending = true
            }
        }
        if !hasPending, let reason = failures.first {
            report(.failed(reason))
        }
    }

    /// Relaying starts only once the wrong-instance probe has succeeded this
    /// session (the kernel buffers the client meanwhile); on failure the
    /// connection is dropped so the client sees a fast close, never bytes
    /// flowing to the wrong place.
    private func accept(_ inbound: NWConnection) {
        probe.verify(on: queue) { [weak self] result in
            guard let self else {
                inbound.cancel()
                return
            }
            switch result {
            case .success:
                self.startRelay(inbound)
            case .failure(let error):
                self.log.error("forward localhost:\(self.forward.localPort): \(error.localizedDescription)")
                inbound.cancel()
            }
        }
    }

    private func startRelay(_ inbound: NWConnection) {
        let relay = Relay(inbound: inbound, outbound: makeOutbound())
        relay.onClose = { [weak self, weak relay] in
            guard let self, let relay else { return }
            self.relays.removeAll { $0 === relay }
            self.report(self.state)
        }
        relays.append(relay)
        report(state)
        relay.start(on: queue)
    }

    /// Connection to the remote target routed through the SOCKS5 listener. The
    /// host stays a name endpoint, so hostnames reach the proxy unresolved
    /// (server-side DNS) — the same mechanism the WebView tabs use.
    private func makeOutbound() -> NWConnection {
        let params = NWParameters.tcp
        let privacy = NWParameters.PrivacyContext(description: "flextunnel-forward")
        privacy.proxyConfigurations = [
            ProxyConfiguration(socksv5Proxy: .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: socksPort)!))
        ]
        params.setPrivacyContext(privacy)
        return NWConnection(
            host: NWEndpoint.Host(forward.remoteHost),
            port: NWEndpoint.Port(rawValue: forward.remotePort)!,
            using: params)
    }

    private func report(_ newState: PortForwardState) {
        state = newState
        onStatus?(newState, relays.count)
    }
}

/// Splices one accepted connection to its proxied outbound counterpart. Confined
/// to the forwarder's queue. Pumping starts only once the outbound side is ready
/// (its SOCKS CONNECT has completed); until then the kernel buffers the client.
private final class Relay {
    var onClose: (() -> Void)?

    private let inbound: NWConnection
    private let outbound: NWConnection
    private var finishedDirections = 0
    private var closed = false

    init(inbound: NWConnection, outbound: NWConnection) {
        self.inbound = inbound
        self.outbound = outbound
    }

    func start(on queue: DispatchQueue) {
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.inbound, to: self.outbound)
                self.pump(from: self.outbound, to: self.inbound)
            case .waiting, .failed, .cancelled:
                // .waiting would retry forever (e.g. SOCKS listener down, target
                // rejected); a forwarded client is better served by a fast close.
                self.close()
            default:
                break
            }
        }
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting, .failed:
                self?.close()
            default:
                break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    /// One direction of the splice. Backpressure comes from chaining: the next
    /// receive is issued only after the previous send completes, so a slow
    /// reader throttles the fast side.
    private func pump(from src: NWConnection, to dst: NWConnection) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if error != nil {
                self.close()
                return
            }
            if let data, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.closed else { return }
                    if sendError != nil {
                        self.close()
                    } else if isComplete {
                        self.finish(toward: dst)
                    } else {
                        self.pump(from: src, to: dst)
                    }
                })
            } else if isComplete {
                self.finish(toward: dst)
            } else {
                self.pump(from: src, to: dst)
            }
        }
    }

    /// EOF on one direction: propagate a half-close (FIN) and keep the other
    /// direction flowing; tear down once both directions have finished.
    private func finish(toward dst: NWConnection) {
        dst.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in })
        finishedDirections += 1
        if finishedDirections == 2 {
            close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        inbound.cancel()
        outbound.cancel()
        onClose?()
        onClose = nil
    }
}
