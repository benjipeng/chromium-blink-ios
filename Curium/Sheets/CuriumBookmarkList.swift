import SwiftUI

struct CuriumBookmarkList: View {
    let library: CuriumLibrary
    let folderID: Int64?
    /// The page the sheet was opened from; it can be saved into the level on screen.
    let currentPage: CuriumBookmarkPage?
    let open: (URL, Bool) -> Void

    @State private var editMode: EditMode = .inactive
    @State private var editor: Editor?
    @State private var deletingFolder: CuriumBookmarkFolder?

    private struct Editor: Identifiable {
        let id = UUID()
        let subject: CuriumBookmarkEditor.Subject
    }

    var body: some View {
        let items = library.bookmarks.items(in: folderID)

        VStack(spacing: 0) {
            if folderID == nil {
                CuriumSheetHeader(title: "Bookmarks")
            }
            List {
                if let currentPage, !editMode.isEditing {
                    Section { currentPageRow(currentPage) }
                }
                ForEach(items) { item in
                    row(item)
                }
                .onMove { source, destination in
                    library.moveBookmarkItems(in: folderID, fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .overlay {
                if items.isEmpty && (currentPage == nil || editMode.isEditing) {
                    ContentUnavailableView {
                        Label("No Bookmarks", systemImage: "bookmark")
                    } description: {
                        Text("Add a folder here or choose this folder when saving a bookmark.")
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(folderID.flatMap(library.bookmarks.folder)?.title ?? "Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(folderID == nil ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    editor = Editor(subject: .newFolder(parentID: folderID))
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Spacer()

                Button {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                } label: {
                    if editMode.isEditing {
                        Label("Done", systemImage: "checkmark")
                    } else {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                .disabled(!editMode.isEditing && !canEdit(items))
            }
        }
        .sheet(item: $editor) { editor in
            CuriumBookmarkEditor(library: library, subject: editor.subject)
        }
        .alert("Delete Folder?", isPresented: Binding(
            get: { deletingFolder != nil },
            set: { if !$0 { deletingFolder = nil } }
        ), presenting: deletingFolder) { folder in
            Button("Delete", role: .destructive) { library.deleteBookmarkItem(.folder(folder)) }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("“\(folder.title)” and all its bookmarks and folders will be deleted.")
        }
    }

    /// One row, three states: add the page here, move it here, or confirm it is here.
    @ViewBuilder
    private func currentPageRow(_ page: CuriumBookmarkPage) -> some View {
        let saved = library.bookmarks.bookmark(for: page.url)
        let title = page.title.isEmpty ? (page.url.host() ?? page.url.absoluteString) : page.title
        if let saved, saved.parentID == folderID {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved Here")
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            } icon: {
                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
            }
            .accessibilityIdentifier("curium.bookmarks.current")
        } else {
            Button {
                Task { _ = await library.saveBookmark(url: page.url, title: saved?.title ?? page.title, in: folderID) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(saved == nil ? "Add This Page" : "Move This Page Here")
                            .foregroundStyle(.tint)
                        Text(saved.map { "\(title) · in \(location(of: $0))" } ?? title)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                } icon: {
                    Image(systemName: saved == nil ? "bookmark" : "arrow.down.to.line")
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("curium.bookmarks.current")
        }
    }

    private func location(of bookmark: CuriumBookmark) -> String {
        bookmark.parentID.flatMap(library.bookmarks.folder)?.title ?? "Bookmarks"
    }

    private func canEdit(_ items: [CuriumBookmarkItem]) -> Bool {
        items.contains { $0.id != CuriumBookmarkFolder.favoritesID }
    }

    @ViewBuilder
    private func row(_ item: CuriumBookmarkItem) -> some View {
        if case .folder(let folder) = item, folder.isFavorites {
            folderLink(folder)
        } else if editMode.isEditing {
            Button {
                edit(item)
            } label: {
                HStack {
                    label(item)
                    Spacer()
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the editor to rename or move this item")
            .contextMenu {
                itemActions(item)
                deleteButton(item)
            }
        } else {
            browseRow(item)
                .swipeActions(allowsFullSwipe: false) {
                    deleteButton(item)
                }
                .contextMenu { itemActions(item) }
        }
    }

    @ViewBuilder
    private func browseRow(_ item: CuriumBookmarkItem) -> some View {
        switch item {
        case .folder(let folder):
            folderLink(folder)
        case .bookmark(let bookmark):
            Button { open(bookmark.url, false) } label: { label(item) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in the current tab")
        }
    }

    private func folderLink(_ folder: CuriumBookmarkFolder) -> some View {
        NavigationLink(value: folder.id) { label(.folder(folder)) }
    }

    @ViewBuilder
    private func label(_ item: CuriumBookmarkItem) -> some View {
        switch item {
        case .folder(let folder):
            Label(folder.title, systemImage: folder.symbol)
        case .bookmark(let bookmark):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.displayTitle)
                    if bookmark.host != bookmark.displayTitle {
                        Text(bookmark.host).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            } icon: {
                Image(systemName: "bookmark")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func itemActions(_ item: CuriumBookmarkItem) -> some View {
        if case .bookmark(let bookmark) = item {
            Button { open(bookmark.url, true) } label: {
                Label("Open in New Tab", systemImage: "plus.square")
            }
            Button { UIPasteboard.general.url = bookmark.url } label: {
                Label("Copy Link", systemImage: "link")
            }
        }
        Button { edit(item) } label: {
            switch item {
            case .folder: Label("Edit Folder", systemImage: "pencil")
            case .bookmark: Label("Edit Bookmark", systemImage: "pencil")
            }
        }
    }

    private func deleteButton(_ item: CuriumBookmarkItem) -> some View {
        Button(role: .destructive) {
            switch item {
            case .folder(let folder): deletingFolder = folder
            case .bookmark: library.deleteBookmarkItem(item)
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func edit(_ item: CuriumBookmarkItem) {
        switch item {
        case .folder(let folder):
            editor = Editor(subject: .folder(folder))
        case .bookmark(let bookmark):
            editor = Editor(subject: .bookmark(url: bookmark.url, title: bookmark.title))
        }
    }
}
