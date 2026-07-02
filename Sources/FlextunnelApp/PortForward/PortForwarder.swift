import Foundation
import Network

/// Runtime state of one forward's listener.
enum PortForwardState: Equatable {
    case stopped
    case listening
    case failed(String)
}

/// Serves one `PortForward`: accepts TCP connections on 127.0.0.1:<localPort>
/// and relays each to the remote target through the in-app SOCKS5 listener, so
/// the core's split-tunnel routing applies exactly as it does for the browser.
///
/// All state is confined to `queue`; Network.framework delivers every callback
/// there via `start(queue:)`. `onStatus` is invoked on that queue too — the
/// owner hops back to the main actor.
final class PortForwarder {
    /// Called on `queue` with (listener state, active connection count).
    var onStatus: ((PortForwardState, Int) -> Void)?

    private let forward: PortForward
    private let socksPort: UInt16
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var relays: [Relay] = []
    private var state: PortForwardState = .stopped

    init(forward: PortForward, socksPort: UInt16) {
        self.forward = forward
        self.socksPort = socksPort
        self.queue = DispatchQueue(label: "portforward.\(forward.localPort)")
    }

    func start() {
        queue.async { self.startListener() }
    }

    /// Stops the listener and drops every relay. Silences `onStatus` first so a
    /// late callback can't overwrite the owner's own "stopped" bookkeeping.
    func cancel() {
        queue.async {
            self.onStatus = nil
            self.listener?.cancel()
            self.listener = nil
            let open = self.relays
            self.relays.removeAll()
            open.forEach { $0.close() }
            self.state = .stopped
        }
    }

    // MARK: - Listener (on queue)

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: reachable from other apps on the device, never the LAN.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: forward.localPort)!)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            report(.failed(error.localizedDescription))
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report(.listening)
            case .failed(let error):
                self.listener?.cancel()
                self.listener = nil
                if case .posix(.EADDRINUSE) = error {
                    self.report(.failed("port \(self.forward.localPort) is in use"))
                } else {
                    self.report(.failed(error.localizedDescription))
                }
            case .cancelled:
                self.report(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] inbound in
            self?.accept(inbound)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ inbound: NWConnection) {
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
            switch state {
            case .ready:
                self?.pump(from: self!.inbound, to: self!.outbound)
                self?.pump(from: self!.outbound, to: self!.inbound)
            case .waiting, .failed, .cancelled:
                // .waiting would retry forever (e.g. SOCKS listener down, target
                // rejected); a forwarded client is better served by a fast close.
                self?.close()
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
