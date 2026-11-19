import CuriumEngineContract
import SwiftUI
import UniformTypeIdentifiers

struct CuriumExtensionsSheet: View {
    let browser: CuriumBrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var enteringLink = false
    @State private var storeLink = ""
    @State private var removing: CuriumExtension?
    @State private var popup: CuriumPopup?

    private var store: CuriumExtensionStore { browser.extensions }

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Extensions")
            ScrollViewReader { scroll in
                extensionList
                    .onChange(of: store.review?.id) { _, token in
                        if let token { withAnimation { scroll.scrollTo(token, anchor: .top) } }
                    }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            while !Task.isCancelled {
                store.refresh(tabID: browser.activeTab?.extensionTabID ?? -1)
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onDisappear {
            setPopup(nil)
            store.endInstallSession()
        }
        .sheet(isPresented: $choosingFile) {
            CuriumCRXPicker { url in
                choosingFile = false
                if let url { store.prepareSignedFile(url) }
            }
            .ignoresSafeArea()
        }
        .alert("Chrome Web Store Link", isPresented: $enteringLink) {
            TextField("https://chromewebstore.google.com/…", text: $storeLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Continue") { store.prepareStoreLink(storeLink) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Extension", isPresented: Binding(
            get: { store.operationError != nil },
            set: { if !$0 { store.operationError = nil } }
        )) {
            Button("OK") { store.operationError = nil }
        } message: {
            Text(store.operationError ?? "")
        }
        .confirmationDialog("Remove Extension?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { item in
            Button("Remove \(item.name)", role: .destructive) { store.remove(item) }
        }
    }

    private var extensionList: some View {
        List {
            Section("Shield · Current Page") {
                LabeledContent {
                    if let count = store.blockedCount {
                        Text(count, format: .number).monospacedDigit()
                    } else {
                        Text("Unavailable")
                    }
                } label: {
                    Label("Requests Blocked", systemImage: "shield")
                }
            }

            Section("Installed · Manifest V3") {
                if !store.isAvailable {
                    Text(browser.isEngineReady ? "This Blink build does not expose extension management." :
                         "Extension management will be available when Blink is ready.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let error = store.listError {
                    Text(error).foregroundStyle(.secondary)
                } else if store.installed.isEmpty {
                    Text("No extensions installed.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.installed) { item in extensionRows(item) }
                }
            }

            if let review = store.review {
                Section("Review Extension Permissions") {
                    LabeledContent("Extension", value: review.name)
                    if !review.version.isEmpty { LabeledContent("Version", value: review.version) }
                    LabeledContent("Permissions", value: review.permissions.isEmpty ? "None" : review.permissions.joined(separator: ", "))
                    LabeledContent("Site Access", value: review.hosts.isEmpty ? "None" : review.hosts.joined(separator: ", "))
                    Button { store.confirmReview() } label: { Label("Add Extension", systemImage: "checkmark") }
                    Button(role: .cancel) { store.cancelReview() } label: { Label("Cancel Review", systemImage: "xmark") }
                }
                .id(review.id)
            }

            Section("Add an Extension") {
                Button { choosingFile = true } label: {
                    Label("Import Signed CRX from Files…", systemImage: "doc.badge.plus")
                }
                Button {
                    storeLink = ""
                    enteringLink = true
                } label: {
                    Label("Install from Chrome Web Store Link…", systemImage: "link")
                }
                if store.isWorking {
                    ProgressView("Working…")
                }
            }
            .disabled(!store.isAvailable || store.isWorking || store.review != nil)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func extensionRows(_ item: CuriumExtension) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(get: { item.isEnabled }, set: { store.setEnabled($0, for: item) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                    if !item.version.isEmpty { Text("Version \(item.version)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let count = item.blockedCount {
                Text("Blocked on this page: \(count, format: .number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if item.canShowPopup {
            Button {
                if let host = store.popup(for: item) {
                    let presentation = CuriumPopup(host: host, name: item.name)
                    host.onRequestClose = { setPopup(nil) }
                    setPopup(presentation)
                }
            } label: {
                Label("Open \(item.name)", systemImage: "puzzlepiece.extension")
                    .badge(item.badge.map { Text(verbatim: $0) })
            }
            .popover(item: Binding(
                get: { popup?.host.extensionID == item.id ? popup : nil },
                set: { if $0 == nil, popup?.host.extensionID == item.id { setPopup(nil) } }
            ), attachmentAnchor: .rect(.bounds)) { popup in
                CuriumPopupView(presentation: popup)
                    .presentationCompactAdaptation(.sheet)
            }
        }
        if item.isEnabled, let url = item.optionsURL {
            Button {
                if browser.newTab(url: url) { dismiss() }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("\(item.name) Options")
        }
        if item.isRemovable {
            Button(role: .destructive) { removing = item } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityLabel("Remove \(item.name)")
        }
    }

    private func setPopup(_ newValue: CuriumPopup?) {
        popup?.close()
        popup = newValue
    }
}

private struct CuriumCRXPicker: UIViewControllerRepresentable {
    let finish: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let type = UTType(filenameExtension: "crx", conformingTo: .data) ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: (URL?) -> Void

        init(finish: @escaping (URL?) -> Void) { self.finish = finish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
}

@MainActor
private final class CuriumPopup: Identifiable {
    let host: any CrIOSExtensionPopupHostingV1
    let view: UIView
    let name: String

    init(host: any CrIOSExtensionPopupHostingV1, name: String) {
        self.host = host
        view = host.view
        self.name = name
    }

    func close() {
        host.onRequestClose = nil
        view.removeFromSuperview()
        host.close()
    }
}

private struct CuriumPopupView: View {
    let presentation: CuriumPopup

    var body: some View {
        let size = presentation.host.preferredContentSize
        VStack(spacing: 0) {
            CuriumSheetHeader(title: presentation.name)
            Surface(content: presentation.view)
                .frame(idealWidth: min(480, max(240, size.width)), idealHeight: min(540, max(120, size.height)))
        }
    }

    private struct Surface: UIViewRepresentable {
        let content: UIView

        func makeUIView(context: Context) -> UIView {
            let wrapper = UIView()
            content.frame = wrapper.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.translatesAutoresizingMaskIntoConstraints = true
            wrapper.addSubview(content)
            return wrapper
        }

        func updateUIView(_ uiView: UIView, context: Context) {}

        static func dismantleUIView(_ uiView: UIView, coordinator: Void) {
            uiView.subviews.forEach { $0.removeFromSuperview() }
        }
    }
}
