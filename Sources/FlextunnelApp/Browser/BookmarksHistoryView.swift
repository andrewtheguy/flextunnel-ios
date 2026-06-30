import SwiftUI

/// Sheet presenting the user's saved bookmarks and browsing history in two
/// segments. Tapping a row loads it in the selected tab; rows swipe to delete.
struct BookmarksHistoryView: View {
    @Bindable var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .bookmarks

    private enum Section: Hashable {
        case bookmarks, history
    }

    private var library: BrowserLibrary { model.library }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    Text("Bookmarks").tag(Section.bookmarks)
                    Text("History").tag(Section.history)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                Group {
                    switch section {
                    case .bookmarks: bookmarksList
                    case .history: historyList
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                if section == .history && !library.history.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear History", role: .destructive) { library.clearHistory() }
                    }
                }
            }
        }
    }

    // MARK: - Bookmarks

    @ViewBuilder
    private var bookmarksList: some View {
        if library.bookmarks.isEmpty {
            ContentUnavailableView(
                "No Bookmarks",
                systemImage: "bookmark",
                description: Text("Use the share button to save a page."))
        } else {
            List {
                ForEach(library.bookmarks) { bookmark in
                    Button { open(bookmark.url) } label: {
                        rowLabel(title: bookmark.name, url: bookmark.url, detail: nil)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    offsets.map { library.bookmarks[$0] }.forEach(library.removeBookmark)
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historyList: some View {
        if library.history.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "clock",
                description: Text("Pages you visit will appear here."))
        } else {
            List {
                ForEach(library.history) { entry in
                    Button { open(entry.url) } label: {
                        rowLabel(
                            title: entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title,
                            url: entry.url,
                            detail: entry.lastVisited.formatted(.relative(presentation: .named)))
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    offsets.map { library.history[$0] }.forEach(library.removeHistory)
                }
            }
        }
    }

    // MARK: - Shared

    private func rowLabel(title: String, url: URL, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(url.host() ?? url.absoluteString)
                    .lineLimit(1)
                if let detail {
                    Text("·")
                    Text(detail)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func open(_ url: URL) {
        model.navigate(url.absoluteString)
        dismiss()
    }
}
