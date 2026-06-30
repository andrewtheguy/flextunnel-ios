import Foundation
import Observation

/// A saved page: a user-facing name (defaults to the page title) and its URL.
struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let url: URL
    let dateAdded: Date

    init(id: UUID = UUID(), name: String, url: URL, dateAdded: Date) {
        self.id = id
        self.name = name
        self.url = url
        self.dateAdded = dateAdded
    }
}

/// One visited page, kept newest-first in `BrowserLibrary.history`.
struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let url: URL
    var lastVisited: Date

    init(id: UUID = UUID(), title: String, url: URL, lastVisited: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.lastVisited = lastVisited
    }
}

/// Owns the user's bookmarks and browsing history and persists both as JSON
/// files in the app container, matching how mainstream browsers store history.
///
/// Because history (and bookmarked URLs) is sensitive in a tunnel browser, the
/// files follow the protections mainstream iOS browsers rely on rather than the
/// weaker UserDefaults plist:
/// - written with Data Protection `…UntilFirstUserAuthentication` (encrypted at
///   rest, readable after the first unlock so it survives backgrounding);
/// - excluded from iCloud / device backups, so the record never leaves the
///   device — like the auth token in `TokenStore`.
/// (WebKit's own data store stays non-persistent; this is our own lightweight
/// record, independent of it.)
@MainActor
@Observable
final class BrowserLibrary {
    private(set) var bookmarks: [Bookmark]
    private(set) var history: [HistoryEntry]

    /// Upper bound on stored history entries; the oldest are dropped past this.
    private static let historyLimit = 500

    private let bookmarksURL: URL
    private let historyURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        Self.prepareDirectory(dir)
        bookmarksURL = dir.appendingPathComponent("bookmarks.json")
        historyURL = dir.appendingPathComponent("history.json")
        bookmarks = Self.load([Bookmark].self, from: bookmarksURL) ?? []
        history = Self.load([HistoryEntry].self, from: historyURL) ?? []
        Self.purgeLegacyUserDefaults()
    }

    // MARK: - Bookmarks

    func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// Adds a bookmark, newest-first. No-op if the URL is already bookmarked.
    func addBookmark(name: String, url: URL) {
        guard !isBookmarked(url) else { return }
        bookmarks.insert(Bookmark(name: name, url: url, dateAdded: Date()), at: 0)
        persistBookmarks()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks()
    }

    /// Removes the bookmark matching `url`, if any (used by the share toggle).
    func removeBookmark(url: URL) {
        bookmarks.removeAll { $0.url == url }
        persistBookmarks()
    }

    func toggleBookmark(name: String, url: URL) {
        if isBookmarked(url) {
            removeBookmark(url: url)
        } else {
            addBookmark(name: name, url: url)
        }
    }

    // MARK: - History

    /// Records a visit, keeping history newest-first. Ignores non-http(s) URLs.
    /// If the most-recent entry is the same URL, its title/timestamp are updated
    /// in place rather than appending a duplicate.
    func recordVisit(title: String, url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }

        if let first = history.first, first.url == url {
            history[0].title = title
            history[0].lastVisited = Date()
        } else {
            history.insert(HistoryEntry(title: title, url: url, lastVisited: Date()), at: 0)
            if history.count > Self.historyLimit {
                history.removeLast(history.count - Self.historyLimit)
            }
        }
        persistHistory()
    }

    func removeHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    // MARK: - Persistence

    private func persistBookmarks() {
        Self.save(bookmarks, to: bookmarksURL)
    }

    private func persistHistory() {
        Self.save(history, to: historyURL)
    }

    /// `Application Support/BrowserLibrary` — the conventional spot for app data
    /// the user doesn't manage directly.
    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BrowserLibrary", isDirectory: true)
    }

    /// Creates the directory and marks it excluded from backups, which also
    /// excludes its contents.
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
        // Encrypted at rest, readable after first unlock; best-effort.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Removes browsing data left in UserDefaults by earlier builds so the
    /// sensitive record doesn't linger in the weaker, backup-eligible store.
    private static func purgeLegacyUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "bookmarks")
        UserDefaults.standard.removeObject(forKey: "history")
    }
}
