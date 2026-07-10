import Foundation
import Network
import Observation
import WebKit
import os.log

/// One download tracked by the manager. Progress mutates in place so the
/// downloads list updates live.
@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State {
        case downloading
        case finished(URL)
        case failed(String)
    }

    let id = UUID()
    let sourceURL: URL
    let startedAt: Date
    var filename: String
    var state: State = .downloading
    var bytesWritten: Int64 = 0
    /// Expected total; ≤ 0 when the server didn't report a length.
    var totalBytes: Int64 = 0
    /// Maps this item back to its `URLSessionTask`.
    var taskIdentifier: Int?

    init(filename: String, sourceURL: URL, startedAt: Date) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.startedAt = startedAt
    }

    /// Download progress in 0...1, or nil when the total length is unknown
    /// (drives an indeterminate progress bar).
    var fractionComplete: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }
}

/// A download awaiting the user's confirmation, with metadata gathered up front
/// (from the navigation response, or a HEAD request) so we can show what's about
/// to be downloaded and how big it is.
struct DownloadPrompt: Identifiable, Equatable {
    let id = UUID()
    let request: URLRequest
    let filename: String
    /// Expected size in bytes; ≤ 0 when unknown.
    let byteCount: Int64
    let host: String?

    var sizeText: String {
        byteCount > 0 ? ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                      : "Unknown size"
    }

    /// Action-sheet message: size, then the source host when known.
    var detailText: String {
        guard let host else { return sizeText }
        return "\(sizeText) · \(host)"
    }
}

/// A terminal download notification shown briefly by the browser chrome, with
/// an explicit success/failure flag so styling doesn't depend on the message.
struct DownloadToast: Equatable {
    let message: String
    let isFailure: Bool

    static func succeeded(_ message: String) -> DownloadToast {
        DownloadToast(message: message, isFailure: false)
    }
    static let failed = DownloadToast(message: "Download failed", isFailure: true)
}

/// Firefox-style download manager. Files the WebView can't display are routed
/// here (iOS 26's `WebPage` has no download delegate), fetched through the same
/// in-app SOCKS5 proxy the tabs use, and tracked in `items` with live progress.
///
/// Session-only: the list lives in memory and `tmp/downloads/` is wiped on
/// launch, so nothing is orphaned across runs. Cookies are copied from the
/// shared data store so session-gated downloads work; other credentials (HTTP
/// auth, client certs) are not carried over.
@MainActor
@Observable
final class BrowserDownloadManager: NSObject, URLSessionDownloadDelegate {
    private(set) var items: [DownloadItem] = []
    /// A download awaiting user confirmation; drives the confirmation dialog.
    var pendingPrompt: DownloadPrompt?
    /// Transient confirmation for terminal events, shown briefly by the browser
    /// chrome.
    var toast: DownloadToast?

    private let socksPort: UInt16
    private let websiteDataStore: WKWebsiteDataStore
    private let log = Logger(subsystem: "com.example.flextunnel", category: "download")
    /// The tunnel set's host patterns, mirroring the tabs' split-tunneling;
    /// nil proxies every host.
    @ObservationIgnored private var proxyMatchDomains: [String]?
    /// Set when the match list changed while downloads were in flight; the next
    /// terminal download event rebuilds the session with the current list.
    @ObservationIgnored private var needsSessionRebuild = false

    init(socksPort: UInt16, proxyMatchDomains: [String]?, websiteDataStore: WKWebsiteDataStore) {
        self.socksPort = socksPort
        self.proxyMatchDomains = proxyMatchDomains
        self.websiteDataStore = websiteDataStore
        super.init()
        Self.resetDownloadsDirectory()
    }

    // Backing store so teardown can invalidate the session (releasing the
    // delegate retain `URLSession(delegate:)` holds) without force-creating one.
    @ObservationIgnored private var _session: URLSession?
    private var session: URLSession {
        if let _session { return _session }
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [
            .loopbackSocks5(port: socksPort, matchDomains: proxyMatchDomains)
        ]
        let created = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        _session = created
        return created
    }

    /// Applies an updated tunnel set. The proxy scoping is baked into the
    /// session's configuration, so an idle session is dropped now (the next
    /// download builds a fresh one); one with downloads in flight keeps its
    /// scoping until they settle, then the terminal delegate event rebuilds.
    func updateProxyMatchDomains(_ matchDomains: [String]?) {
        guard matchDomains != proxyMatchDomains else { return }
        proxyMatchDomains = matchDomains
        needsSessionRebuild = true
        rebuildSessionIfIdle()
    }

    private func rebuildSessionIfIdle() {
        guard needsSessionRebuild else { return }
        let busy = items.contains {
            if case .downloading = $0.state { return true } else { return false }
        }
        guard !busy else { return }
        needsSessionRebuild = false
        _session?.invalidateAndCancel()
        _session = nil
    }

    /// Cancels in-flight transfers, invalidates the session (so it stops
    /// retaining this delegate), and clears download state. Called when the
    /// owning `BrowserModel` shuts down. Idempotent.
    func shutdown() {
        _session?.invalidateAndCancel()
        _session = nil
        for item in items {
            if case .finished(let url) = item.state {
                try? FileManager.default.removeItem(at: url)
            }
        }
        items.removeAll()
        pendingPrompt = nil
        toast = nil
    }

    // MARK: - Confirmation

    /// Gathers metadata and presents a confirmation prompt instead of starting
    /// immediately. `response` is the navigation response when one is available
    /// (it already carries size/filename); otherwise a HEAD request fetches them.
    func requestDownload(_ request: URLRequest, response: URLResponse?) async {
        guard let url = request.url else { return }

        let filename: String
        let byteCount: Int64
        if let response {
            filename = Self.sanitizedFilename(response.suggestedFilename, url: url)
            byteCount = response.expectedContentLength
        } else {
            (filename, byteCount) = await headMetadata(for: request, url: url)
        }

        pendingPrompt = DownloadPrompt(
            request: request,
            filename: filename,
            byteCount: byteCount,
            host: url.host())
    }

    /// Confirms the prompt and begins the actual download.
    func confirm(_ prompt: DownloadPrompt) {
        pendingPrompt = nil
        Task { await startDownload(prompt.request, suggestedFilename: prompt.filename) }
    }

    func cancelPrompt() {
        pendingPrompt = nil
    }

    /// Probes the URL with a HEAD request (through the proxy, with cookies) to
    /// learn the filename and size. Falls back to URL-derived values on failure.
    private func headMetadata(for request: URLRequest, url: URL) async -> (filename: String, byteCount: Int64) {
        var head = request
        head.httpMethod = "HEAD"
        await applyCookies(to: &head, url: url)
        do {
            let (_, response) = try await session.data(for: head)
            return (Self.sanitizedFilename(response.suggestedFilename, url: url), response.expectedContentLength)
        } catch {
            return (Self.sanitizedFilename(nil, url: url), -1)
        }
    }

    // MARK: - Starting downloads

    func startDownload(_ request: URLRequest, suggestedFilename: String?) async {
        guard let url = request.url else { return }
        let filename = Self.sanitizedFilename(suggestedFilename, url: url)
        log.info("downloading \(filename, privacy: .public)")

        var req = request
        await applyCookies(to: &req, url: url)

        let item = DownloadItem(filename: filename, sourceURL: url, startedAt: Date())
        let task = session.downloadTask(with: req)
        item.taskIdentifier = task.taskIdentifier
        items.insert(item, at: 0)
        task.resume()
    }

    // MARK: - List management

    func remove(_ item: DownloadItem) {
        if let id = item.taskIdentifier {
            session.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == id }?.cancel()
            }
        }
        if case .finished(let url) = item.state {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        for item in items { remove(item) }
    }

    // MARK: - URLSessionDownloadDelegate (delegateQueue is .main)

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            guard let item = item(for: downloadTask.taskIdentifier) else { return }
            item.bytesWritten = totalBytesWritten
            item.totalBytes = totalBytesExpectedToWrite
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must move the file synchronously: URLSession deletes `location` once
        // this call returns.
        let suggested = downloadTask.response?.suggestedFilename
        let sourceURL = downloadTask.originalRequest?.url
        let dest = Self.moveToDownloads(location, suggested: suggested, sourceURL: sourceURL)

        MainActor.assumeIsolated {
            defer { rebuildSessionIfIdle() }
            guard let item = item(for: downloadTask.taskIdentifier) else { return }
            guard let dest else {
                item.state = .failed("Could not save the file.")
                toast = .failed
                return
            }
            item.filename = dest.lastPathComponent
            item.state = .finished(dest)
            toast = .succeeded("Downloaded \(item.filename)")
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        // A user-initiated cancel (from remove) isn't a failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }

        MainActor.assumeIsolated {
            defer { rebuildSessionIfIdle() }
            guard let item = item(for: task.taskIdentifier) else { return }
            if case .finished = item.state { return }
            log.error("download failed: \(error.localizedDescription, privacy: .private)")
            item.state = .failed(error.localizedDescription)
            toast = .failed
        }
    }

    private func item(for taskIdentifier: Int) -> DownloadItem? {
        items.first { $0.taskIdentifier == taskIdentifier }
    }

    // MARK: - Cookies

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
        return domainMatches && Self.path(url.path, matchesCookiePath: cookie.path)
    }

    /// RFC 6265 §5.1.4 path-match: the cookie-path is a prefix of the request
    /// path *at a path boundary*, so `/foo` matches `/foo` and `/foo/bar` but
    /// not `/foobar`.
    private static func path(_ requestPath: String, matchesCookiePath cookiePath: String) -> Bool {
        if cookiePath.isEmpty || cookiePath == "/" { return true }
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return requestPath[boundary] == "/"
    }

    // MARK: - Files

    nonisolated private static func downloadsDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    /// Wipes and recreates `tmp/downloads/` so files from a previous session
    /// (e.g. after a force-quit) don't linger.
    private static func resetDownloadsDirectory() {
        let dir = downloadsDirectory()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Moves a just-finished temp file into `tmp/downloads/` under a unique,
    /// extension-preserving name. Returns nil on failure.
    nonisolated private static func moveToDownloads(_ tempURL: URL, suggested: String?, sourceURL: URL?) -> URL? {
        let dir = downloadsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = sanitizedFilename(suggested, url: sourceURL ?? tempURL)
        var dest = dir.appendingPathComponent(name)
        // Avoid clobbering an existing file from an earlier same-named download.
        if FileManager.default.fileExists(atPath: dest.path) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let unique = ext.isEmpty ? "\(base)-\(UUID().uuidString.prefix(8))"
                                     : "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
            dest = dir.appendingPathComponent(unique)
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    nonisolated private static func sanitizedFilename(_ suggested: String?, url: URL) -> String {
        let fallback = url.lastPathComponent
        let raw = suggested?.isEmpty == false ? suggested! : fallback
        let cleaned = raw.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject reserved/path-resolving names so `appendingPathComponent` can't
        // land on the directory itself or its parent (`.`/`..`).
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned == "/" {
            return "download"
        }
        return cleaned
    }
}
