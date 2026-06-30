import Foundation
import Network
import Observation
import WebKit
import os.log

/// Downloads files through the same in-app SOCKS5 proxy the tabs use, then hands
/// the finished file to a share sheet so the user can save it to Files.
///
/// iOS 26's `WebPage` exposes no `WKDownload` delegate, so a download navigation
/// would otherwise stall the web view. The navigation decider cancels those
/// navigations and routes them here, where a proxied `URLSession` fetches the
/// file independently. Cookies are copied from the shared data store so
/// session-gated downloads still work; other credentials (HTTP auth, client
/// certs) are not carried over.
@MainActor
@Observable
final class BrowserDownloadManager {
    /// A finished download awaiting the user's save/share action.
    struct ReadyFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Set when a download finishes; drives a share sheet. Cleared once shown.
    var readyFile: ReadyFile?
    /// Transient status text for the toast (nil when idle).
    var status: String?

    private let socksPort: UInt16
    private let websiteDataStore: WKWebsiteDataStore
    private let log = Logger(subsystem: "com.example.flextunnel", category: "download")

    init(socksPort: UInt16, websiteDataStore: WKWebsiteDataStore) {
        self.socksPort = socksPort
        self.websiteDataStore = websiteDataStore
    }

    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: socksPort)!)
        config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        return URLSession(configuration: config)
    }()

    func download(_ request: URLRequest, suggestedFilename: String?) async {
        guard let url = request.url else { return }
        let filename = Self.sanitizedFilename(suggestedFilename, url: url)
        status = "Downloading \(filename)…"
        log.info("downloading \(filename, privacy: .public) via in-app SOCKS5")

        var req = request
        await applyCookies(to: &req, url: url)

        do {
            let (tempURL, _) = try await session.download(for: req)
            let dest = try moveToTemporary(tempURL, filename: filename)
            status = nil
            readyFile = ReadyFile(url: dest)
        } catch {
            log.error("download failed: \(error.localizedDescription, privacy: .private)")
            status = "Download failed"
        }
    }

    /// Copies cookies from the shared web data store onto the outgoing request so
    /// downloads behind a login work.
    private func applyCookies(to request: inout URLRequest, url: URL) async {
        let store = websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let matching = cookies.filter { Self.cookie($0, appliesTo: url) }
        guard !matching.isEmpty else { return }
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    private static func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }

        let domain = cookie.domain.lowercased()
        let domainMatches: Bool
        if domain.hasPrefix(".") {
            domainMatches = host == domain.dropFirst() || host.hasSuffix(domain)
        } else {
            domainMatches = host == domain
        }
        return domainMatches && url.path.hasPrefix(cookie.path)
    }

    private func moveToTemporary(_ tempURL: URL, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static func sanitizedFilename(_ suggested: String?, url: URL) -> String {
        let fallback = url.lastPathComponent
        let raw = suggested?.isEmpty == false ? suggested! : fallback
        let cleaned = raw.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "/" ? "download" : cleaned
    }
}
