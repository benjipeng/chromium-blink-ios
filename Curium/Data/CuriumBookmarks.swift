import Foundation

struct CuriumBookmark: Identifiable, Hashable, Sendable {
    let id: Int64
    let parentID: Int64?
    let url: URL
    let title: String

    var host: String { url.host() ?? url.absoluteString }
    var displayTitle: String { title.isEmpty ? host : title }
}

/// A page offered for saving: what the sheet was opened from.
struct CuriumBookmarkPage: Equatable, Sendable {
    let url: URL
    let title: String
}

struct CuriumBookmarkFolder: Identifiable, Hashable, Sendable {
    static let favoritesID: Int64 = 1

    let id: Int64
    let parentID: Int64?
    let title: String

    var isFavorites: Bool { id == Self.favoritesID }
    var symbol: String { isFavorites ? "star" : "folder" }
}

enum CuriumBookmarkItem: Identifiable, Sendable {
    case folder(CuriumBookmarkFolder)
    case bookmark(CuriumBookmark)

    var id: Int64 {
        switch self {
        case .folder(let folder): folder.id
        case .bookmark(let bookmark): bookmark.id
        }
    }

    var parentID: Int64? {
        switch self {
        case .folder(let folder): folder.parentID
        case .bookmark(let bookmark): bookmark.parentID
        }
    }
}

struct CuriumBookmarkTree: Sendable {
    struct Destination: Identifiable {
        let id: Int64?
        let title: String
        let symbol: String
    }

    private let children: [Int64?: [CuriumBookmarkItem]]
    private let folders: [Int64: CuriumBookmarkFolder]
    private let bookmarksByURL: [String: CuriumBookmark]
    private let bookmarkedURLs: Set<String>
    let favorites: [CuriumBookmark]

    init(items: [CuriumBookmarkItem] = []) {
        children = Dictionary(grouping: items, by: \.parentID)
        var folders: [Int64: CuriumBookmarkFolder] = [:]
        var bookmarksByURL: [String: CuriumBookmark] = [:]
        var favorites: [CuriumBookmark] = []
        for item in items {
            switch item {
            case .folder(let folder): folders[folder.id] = folder
            case .bookmark(let bookmark):
                bookmarksByURL[bookmark.url.absoluteString] = bookmark
                if bookmark.parentID == CuriumBookmarkFolder.favoritesID {
                    favorites.append(bookmark)
                }
            }
        }
        self.folders = folders
        self.bookmarksByURL = bookmarksByURL
        self.bookmarkedURLs = Set(bookmarksByURL.keys)
        self.favorites = favorites
    }

    func items(in folderID: Int64?) -> [CuriumBookmarkItem] { children[folderID] ?? [] }
    func folder(_ id: Int64) -> CuriumBookmarkFolder? { folders[id] }
    func bookmark(for url: URL) -> CuriumBookmark? { bookmarksByURL[url.absoluteString] }
    func isBookmarked(_ url: URL) -> Bool { bookmarkedURLs.contains(url.absoluteString) }

    func destinations(excluding movedFolderID: Int64? = nil) -> [Destination] {
        var result = [Destination(id: nil, title: "Bookmarks", symbol: "book")]
        func visit(_ parentID: Int64?, path: [String]) {
            for case .folder(let folder) in items(in: parentID) where folder.id != movedFolderID {
                let path = path + [folder.title]
                result.append(Destination(id: folder.id, title: path.joined(separator: " › "), symbol: folder.symbol))
                visit(folder.id, path: path)
            }
        }
        visit(nil, path: [])
        return result
    }
}
