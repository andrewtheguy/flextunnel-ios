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

/// Owns the user's bookmarks and browsing history and persists both to
/// UserDefaults as JSON, by product choice, so they survive across launches.
///
/// Privacy tradeoff worth keeping in mind: in a tunnel browser, history (and
/// bookmarked URLs) is sensitive — it records exactly what was browsed. Yet
/// UserDefaults is only guarded by the device file-protection class and can be
/// included in device backups, unlike the auth token, which `TokenStore` pins
/// to the Keychain with `…ThisDeviceOnly` so it never leaves the device. If
/// that tradeoff is unacceptable, switch history to session-only or secure,
/// non-syncing storage. (WebKit's own data store stays non-persistent; this is
/// our own lightweight record, independent of it.)
@MainActor
@Observable
final class BrowserLibrary {
    private(set) var bookmarks: [Bookmark]
    private(set) var history: [HistoryEntry]

    /// Upper bound on stored history entries; the oldest are dropped past this.
    private static let historyLimit = 500

    private let defaults: UserDefaults
    private static let bookmarksKey = "bookmarks"
    private static let historyKey = "history"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarks = Self.decode([Bookmark].self, from: defaults, key: Self.bookmarksKey) ?? []
        history = Self.decode([HistoryEntry].self, from: defaults, key: Self.historyKey) ?? []
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
        Self.encode(bookmarks, into: defaults, key: Self.bookmarksKey)
    }

    private func persistHistory() {
        Self.encode(history, into: defaults, key: Self.historyKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, into defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
