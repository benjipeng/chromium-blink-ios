import CuriumEngineContract
import SwiftUI
import UniformTypeIdentifiers

struct CuriumExtensionsSheet: View {
    let browser: CuriumBrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFile = false
    @State private var enteringLink = false
    @State private var storeLink = ""
    @State private var removing: CuriumExtension?
    @State private var popup: CuriumPopup?

    private var store: CuriumExtensionStore { browser.extensions }

    private struct BlockedPollKey: Equatable {
        let active: Bool
        let tabID: Int32
        let isLoading: Bool
        let url: URL?
    }

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
        .onAppear {
            store.refresh(tabID: browser.activeTab?.extensionTabID ?? -1, includeBlockedCounts: true)
        }
        .task(id: BlockedPollKey(
            active: scenePhase == .active && popup == nil && store.hasEnabledExtensions
                && (browser.activeTab?.extensionTabID ?? -1) >= 0,
            tabID: browser.activeTab?.extensionTabID ?? -1,
            isLoading: browser.activeTab?.isLoading == true,
            url: browser.activeTab?.url
        )) {
            let initialTabID = browser.activeTab?.extensionTabID ?? -1
            guard scenePhase == .active,
                  popup == nil,
                  store.hasEnabledExtensions,
                  initialTabID >= 0 else { return }
            var intervalSeconds = 2
            var unchangedPolls = 0
            var lastTotal = store.blockedCount
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(intervalSeconds)) } catch { break }
                guard scenePhase == .active, popup == nil else { break }
                let currentTabID = browser.activeTab?.extensionTabID ?? -1
                guard currentTabID >= 0 else { break }
                store.refreshBlockedCounts(tabID: currentTabID)
                let nextTotal = store.blockedCount
                if nextTotal == lastTotal {
                    unchangedPolls += 1
                    if browser.activeTab?.isLoading != true {
                        if unchangedPolls >= 3 { break }
                        intervalSeconds = min(8, intervalSeconds * 2)
                    }
                } else {
                    lastTotal = nextTotal
                    unchangedPolls = 0
                    intervalSeconds = 2
                }
            }
        }
        .onChange(of: browser.backgroundEpoch) { _, _ in
            setPopup(nil)
        }
        .onChange(of: store.installed) { _, installed in
            guard let activePopup = popup else { return }
            let stillValid = installed.contains { $0.id == activePopup.host.extensionID && $0.canShowPopup }
            if !stillValid { setPopup(nil) }
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
        .sheet(item: Binding(
            get: { popup },
            set: { if $0 == nil { setPopup(nil) } }
        )) { activePopup in
            CuriumPopupView(presentation: activePopup)
                .presentationSizing(.fitted)
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
            if store.isWorking {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Downloading and verifying extension…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
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

            Section("Add an Extension") {
                Button {
                    if let url = URL(string: "https://chromewebstore.google.com/"),
                       browser.newTab(url: url) {
                        dismiss()
                    }
                } label: {
                    Label("Browse Chrome Web Store", systemImage: "safari")
                }
                Button { choosingFile = true } label: {
                    Label("Import Signed CRX from Files…", systemImage: "doc.badge.plus")
                }
                Button {
                    storeLink = ""
                    enteringLink = true
                } label: {
                    Label("Install from Chrome Web Store Link…", systemImage: "link")
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
            if let count = item.blockedCount, count > 0 {
                Text("Blocked on this page: \(count, format: .number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if item.canShowPopup {
            Button {
                if let host = store.popup(for: item) {
                    let presentation = CuriumPopup(host: host, name: item.name)
                    let closeIfCurrent: @MainActor () -> Void = { [weak presentation] in
                        guard let presentation, popup === presentation else { return }
                        setPopup(nil)
                    }
                    host.onRequestClose = {
                        // Defer out of WebContentsImpl::Close / CloseWebState so host.close()
                        // does not synchronously destroy WebState and its delegate mid-callback.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                closeIfCurrent()
                            }
                        }
                    }
                    setPopup(presentation)
                }
            } label: {
                Label("Open \(item.name)", systemImage: "puzzlepiece.extension")
                    .badge(item.badge.map { Text(verbatim: $0) })
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
    private var isClosed = false

    init(host: any CrIOSExtensionPopupHostingV1, name: String) {
        self.host = host
        view = host.view
        self.name = name
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        host.onRequestClose = nil
        view.removeFromSuperview()
        host.close()
    }
}

private struct CuriumPopupView: View {
    let presentation: CuriumPopup

    var body: some View {
        let size = presentation.host.preferredContentSize
        let width = min(480, max(320, size.width))
        let height = min(560, max(440, size.height))
        VStack(spacing: 0) {
            CuriumSheetHeader(title: presentation.name)
            Surface(content: presentation.view)
                .frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
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
