import SwiftUI

struct CuriumBookmarkEditor: View {
    enum Subject {
        case bookmark(url: URL, title: String)
        case newFolder(parentID: Int64?)
        case folder(CuriumBookmarkFolder)
    }

    let library: CuriumLibrary
    let subject: Subject

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var folderID: Int64?
    @State private var isReady = false
    @State private var isEditingBookmark = false
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var destinations: [CuriumBookmarkTree.Destination]

    init(library: CuriumLibrary, subject: Subject) {
        self.library = library
        self.subject = subject
        let excludedID: Int64?
        switch subject {
        case .bookmark(_, let title):
            _title = State(initialValue: title)
            _folderID = State(initialValue: CuriumBookmarkFolder.favoritesID)
            excludedID = nil
        case .newFolder(let parentID):
            _title = State(initialValue: "")
            _folderID = State(initialValue: parentID)
            excludedID = nil
        case .folder(let folder):
            _title = State(initialValue: folder.title)
            _folderID = State(initialValue: folder.parentID)
            excludedID = folder.id
        }
        _destinations = State(initialValue: library.bookmarks.destinations(excluding: excludedID))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(fieldTitle, text: $title)
                    .accessibilityLabel(Text(fieldTitle))
                    .submitLabel(.done)
                    .onSubmit(save)
                Picker(selection: $folderID) {
                    ForEach(destinations) { destination in
                        Label(destination.title, systemImage: destination.symbol)
                            .tag(destination.id)
                    }
                } label: {
                    Label("Folder", systemImage: "folder")
                }
                .pickerStyle(.navigationLink)
            }
            .disabled(!isReady || isSaving)
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) { Label("Save", systemImage: "checkmark") }
                        .disabled(!canSave)
                }
            }
            .alert("Couldn’t Save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check that the destination folder still exists and try again.")
            }
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.medium, .large])
        .onChange(of: library.bookmarkRevision) {
            destinations = library.bookmarks.destinations(excluding: editedFolderID)
        }
        .task {
            guard !isReady else { return }
            if case .bookmark(let url, _) = subject,
               let bookmark = await library.bookmark(for: url) {
                title = bookmark.title
                folderID = bookmark.parentID
                isEditingBookmark = true
            }
            destinations = library.bookmarks.destinations(excluding: editedFolderID)
            isReady = true
        }
    }

    private var heading: String {
        switch subject {
        case .bookmark: isEditingBookmark ? "Edit Bookmark" : "Add Bookmark"
        case .newFolder: "New Folder"
        case .folder: "Edit Folder"
        }
    }

    private var fieldTitle: String { isBookmark ? "Title" : "Name" }

    private var isBookmark: Bool {
        if case .bookmark = subject { return true }
        return false
    }

    private var editedFolderID: Int64? {
        if case .folder(let folder) = subject { return folder.id }
        return nil
    }

    private var canSave: Bool {
        isReady && !isSaving && (isBookmark || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            let saved: Bool
            switch subject {
            case .bookmark(let url, _):
                saved = await library.saveBookmark(url: url, title: title, in: folderID)
            case .newFolder, .folder:
                saved = await library.saveBookmarkFolder(id: editedFolderID, title: title, in: folderID)
            }
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }
}
