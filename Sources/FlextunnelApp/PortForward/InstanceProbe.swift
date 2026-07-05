import Foundation
import Network

/// Session-wide wrong-instance guard, mirroring the desktop forwarder: before
/// the first connection of a session is relayed, fetch
/// `http://flextunnel.internal/status.json` through the SOCKS port and require
/// the reported `server_node_id` to match this session's configured server, so
/// a forward that accidentally reaches some *other* SOCKS5 server on the port
/// fails loudly instead of sending traffic to the wrong place. Success latches
/// for the session; failures retry on the next connection. Misconfiguration
/// guard, not security — everything is loopback.
///
/// All state is confined to `queue`; concurrent callers share one in-flight
/// probe.
final class InstanceProbe {
    enum ProbeError: LocalizedError {
        /// The port answered, but not with the flextunnel status page — some
        /// other SOCKS5 (or non-SOCKS) server is on it.
        case notFlextunnel(String)
        /// A flextunnel answered, but it is connected to a different server.
        case wrongServer(reported: String, expected: String)
        case connectionFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notFlextunnel(let reason):
                return "the SOCKS port did not serve the flextunnel status page (\(reason))"
            case .wrongServer(let reported, let expected):
                return "the SOCKS port is served by a flextunnel connected to a different server (node id \(reported), expected \(expected))"
            case .connectionFailed(let reason):
                return "instance probe failed: \(reason)"
            case .timedOut:
                return "instance probe timed out"
            }
        }
    }

    /// Matches the desktop forwarder's SOCKS setup deadline: must exceed the
    /// core's tunnel-open timeout (~30s) so a slowly connecting tunnel isn't
    /// mistaken for a wrong instance.
    private static let timeout: TimeInterval = 35
    /// The status JSON is small; anything bigger is not our status page.
    private static let maxResponseBytes = 512 * 1024

    private let socksPort: UInt16
    private let expectedNodeID: String
    private let queue = DispatchQueue(label: "flextunnel.instance-probe")
    private var verified = false
    private var inFlight: NWConnection?
    /// Bumped whenever an attempt finishes, so late callbacks (a timeout firing
    /// after success, a receive on a canceled connection) are ignored.
    private var generation = 0
    private var waiters: [(Result<Void, Error>) -> Void] = []

    init(socksPort: UInt16, expectedNodeID: String) {
        self.socksPort = socksPort
        self.expectedNodeID = expectedNodeID
    }

    /// Delivers the verification result on `callbackQueue` — immediately once a
    /// probe has succeeded this session, otherwise after joining the (single)
    /// in-flight probe.
    func verify(on callbackQueue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.verified {
                callbackQueue.async { completion(.success(())) }
                return
            }
            self.waiters.append { result in callbackQueue.async { completion(result) } }
            if self.inFlight == nil {
                self.startProbe()
            }
        }
    }

    // MARK: - Probe (on queue)

    private func startProbe() {
        let gen = generation
        let params = NWParameters.tcp
        let privacy = NWParameters.PrivacyContext(description: "flextunnel-instance-probe")
        privacy.proxyConfigurations = [
            ProxyConfiguration(socksv5Proxy: .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: socksPort)!))
        ]
        params.setPrivacyContext(privacy)
        // A name endpoint, so the reserved host reaches the proxy unresolved
        // and the server intercepts it — like every forwarded connection.
        let conn = NWConnection(host: "flextunnel.internal", port: 80, using: params)
        inFlight = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                self.sendRequest(conn, gen: gen)
            case .waiting(let error), .failed(let error):
                // .waiting would retry forever (SOCKS listener down, CONNECT
                // rejected); fail fast like the relays do.
                self.finish(gen, .failure(ProbeError.connectionFailed(error.localizedDescription)))
            default:
                break
            }
        }
        conn.start(queue: queue)

        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.finish(gen, .failure(ProbeError.timedOut))
        }
    }

    private func sendRequest(_ conn: NWConnection, gen: Int) {
        let request = "GET /status.json HTTP/1.1\r\nHost: flextunnel.internal\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, gen == self.generation else { return }
            if let error {
                self.finish(gen, .failure(ProbeError.connectionFailed(error.localizedDescription)))
            }
        })
        receiveResponse(conn, gen: gen, accumulated: Data())
    }

    /// Accumulate until EOF (the server sends `Connection: close` and finishes
    /// the stream), then check the response.
    private func receiveResponse(_ conn: NWConnection, gen: Int, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, gen == self.generation else { return }
            var accumulated = accumulated
            if let data {
                accumulated.append(data)
            }
            if let error {
                self.finish(gen, .failure(ProbeError.connectionFailed(error.localizedDescription)))
            } else if isComplete {
                self.finish(gen, self.checkResponse(accumulated))
            } else if accumulated.count > Self.maxResponseBytes {
                self.finish(gen, .failure(ProbeError.notFlextunnel("oversized response")))
            } else {
                self.receiveResponse(conn, gen: gen, accumulated: accumulated)
            }
        }
    }

    private func finish(_ gen: Int, _ result: Result<Void, Error>) {
        guard gen == generation else { return }
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        if case .success = result {
            verified = true
        }
        let pending = waiters
        waiters = []
        pending.forEach { $0(result) }
    }

    // MARK: - Response parsing

    private struct StatusPage: Decodable {
        let serverNodeID: String

        enum CodingKeys: String, CodingKey {
            case serverNodeID = "server_node_id"
        }
    }

    private func checkResponse(_ response: Data) -> Result<Void, Error> {
        guard let headEnd = response.range(of: Data("\r\n\r\n".utf8)) else {
            return .failure(ProbeError.notFlextunnel("no HTTP response head"))
        }
        guard let head = String(data: response[..<headEnd.lowerBound], encoding: .utf8) else {
            return .failure(ProbeError.notFlextunnel("response head is not UTF-8"))
        }
        let statusLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1] == "200" else {
            return .failure(ProbeError.notFlextunnel("unexpected HTTP response: \(statusLine)"))
        }
        guard let page = try? JSONDecoder().decode(StatusPage.self, from: response[headEnd.upperBound...]) else {
            return .failure(ProbeError.notFlextunnel("no server_node_id in status JSON"))
        }
        guard page.serverNodeID.lowercased() == expectedNodeID.lowercased() else {
            return .failure(ProbeError.wrongServer(reported: page.serverNodeID, expected: expectedNodeID))
        }
        return .success(())
    }
}
