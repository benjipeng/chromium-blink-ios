import CuriumEngineContract
import Observation
import UIKit

@MainActor
@Observable
final class CuriumTabModel: Identifiable {
    let id: String
    private(set) var engine: (any CrIOSTabHostingV1)?
    private(set) var url: URL?
    private(set) var title = "New Tab"
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var usesDesktopSite = false
    private(set) var pageCanvasColor: UIColor?
    private(set) var isFullscreen = false
    private(set) var extensionTabID: Int32 = -1
    private(set) var snapshot: UIImage?

    @ObservationIgnored private var history: [URL?] = [nil]
    @ObservationIgnored private var historyIndex = 0
    @ObservationIgnored private var snapshotRevision = 0

    init() { id = UUID().uuidString }

    init(engine: any CrIOSTabHostingV1) {
        id = engine.tabID
        refresh(from: engine)
    }

    func refresh(from engine: any CrIOSTabHostingV1) {
        self.engine = engine
        if url != engine.currentURL {
            snapshot = nil
            snapshotRevision += 1
        }
        url = engine.currentURL
        title = engine.title.isEmpty ? (url?.host() ?? "New Tab") : engine.title
        isLoading = engine.isLoading
        progress = min(1, max(0, engine.estimatedProgress))
        canGoBack = engine.canGoBack
        canGoForward = engine.canGoForward
        usesDesktopSite = engine.usesDesktopUserAgent
        pageCanvasColor = engine.pageCanvasColor
        isFullscreen = engine.isWebFullscreen
        extensionTabID = engine.extensionTabID
    }

    func load(_ url: URL) {
        if let engine { engine.load(url); return }
        guard self.url != url else { return }
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(url)
        historyIndex += 1
        updateStandbyHistory()
    }

    func goBack() {
        guard canGoBack else { return }
        if let engine { engine.goBack(); return }
        historyIndex -= 1
        updateStandbyHistory()
    }

    func goForward() {
        guard canGoForward else { return }
        if let engine { engine.goForward(); return }
        historyIndex += 1
        updateStandbyHistory()
    }

    func toggleDesktopSite() {
        if let engine { CuriumSetDesktopSite(engine, !usesDesktopSite) }
    }

    func reloadOrStop() {
        guard let engine else { return }
        if isLoading { engine.stopLoading() } else { engine.reload() }
    }

    func requestSnapshot() {
        guard let engine, !isFullscreen else { return }
        snapshotRevision += 1
        let revision = snapshotRevision
        engine.takeSnapshot { [weak self] image in
            guard let self, let image, self.snapshotRevision == revision else { return }
            self.snapshot = image
        }
    }

    private func updateStandbyHistory() {
        url = history[historyIndex]
        title = url?.host() ?? "New Tab"
        canGoBack = historyIndex > 0
        canGoForward = historyIndex < history.count - 1
    }
}

@MainActor
@Observable
final class CuriumBrowserStore: NSObject, CrIOSBrowserHostDelegateV1 {
    private let host: (any CrIOSBrowserHostV1)?
    let extensions: CuriumExtensionStore
    private(set) var tabs: [CuriumTabModel] = []
    private(set) var activeTab: CuriumTabModel?
    private(set) var downloads: [CuriumDownload] = []
    var errorMessage: String?

    var isEngineReady: Bool { host != nil }

    init(host: (any CrIOSBrowserHostV1)? = nil, extensionManager: (any CrIOSExtensionManagingV1)? = nil) {
        self.host = host
        extensions = CuriumExtensionStore(manager: host == nil ? nil : (extensionManager ?? CuriumSharedExtensionManager()))
        super.init()
        if let host {
            host.delegate = self
            updateTabs(from: host)
            if tabs.isEmpty { newTab() }
        } else {
            newTab()
        }
    }

    func submitAddress(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if let candidate = URL(string: text),
           let scheme = candidate.scheme?.lowercased(), ["https", "http"].contains(scheme),
           candidate.host() != nil {
            url = candidate
        } else if !text.contains(where: \.isWhitespace), !text.contains("://"),
                  let candidate = URL(string: "https://" + text),
                  let host = candidate.host(), host.contains(".") || host == "localhost" {
            url = candidate
        } else {
            var search = URLComponents()
            search.scheme = "https"
            search.host = "www.google.com"
            search.path = "/search"
            search.queryItems = [URLQueryItem(name: "q", value: text)]
            url = search.url
        }
        guard let url else { return }
        if let activeTab { activeTab.load(url) } else { newTab(url: url) }
    }

    @discardableResult
    func newTab(url: URL? = nil) -> Bool {
        activeTab?.requestSnapshot()
        if let host {
            guard host.createTab(with: url, activate: true) != nil else {
                errorMessage = "Blink could not open a new tab."
                return false
            }
            updateTabs(from: host)
        } else {
            let tab = CuriumTabModel()
            if let url { tab.load(url) }
            tabs.append(tab)
            activeTab = tab
        }
        return true
    }

    func select(_ tab: CuriumTabModel) {
        guard activeTab?.id != tab.id else { return }
        activeTab?.requestSnapshot()
        if let host {
            if host.activateTab(withID: tab.id) { updateTabs(from: host) }
        } else {
            activeTab = tab
        }
    }

    func close(_ tab: CuriumTabModel) {
        if let host {
            if host.closeTab(withID: tab.id) { updateTabs(from: host) }
        } else if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)
            if activeTab?.id == tab.id { activeTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
        }
        if tabs.isEmpty { newTab() }
    }

    func clearBrowsingData() async {
        guard let host else { return }
        do {
            try await host.clearBrowsingData(of: [.cookies, .cache, .siteStorage], modifiedSince: .distantPast)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func browserHostDidUpdateTabs(_ host: any CrIOSBrowserHostV1) {
        updateTabs(from: host)
    }

    func browserHost(_ host: any CrIOSBrowserHostV1, didUpdateTab tab: any CrIOSTabHostingV1) {
        guard let model = tabs.first(where: { $0.id == tab.tabID }) else { return }
        let contextChanged = model.url != tab.currentURL || model.extensionTabID != tab.extensionTabID
        model.refresh(from: tab)
        if activeTab === model && contextChanged { updateExtensionContext() }
    }

    func browserHost(_ host: any CrIOSBrowserHostV1, didCreateDownload download: any CrIOSDownloadTaskV1) {
        let item = CuriumDownload(task: download)
        guard !downloads.contains(where: { $0.id == item.id }) else { return }
        downloads.insert(item, at: 0)
    }

    private func updateTabs(from host: any CrIOSBrowserHostV1) {
        let previous = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabs = host.tabs.map { engine in
            guard let model = previous[engine.tabID] else { return CuriumTabModel(engine: engine) }
            model.refresh(from: engine)
            return model
        }
        let activeID = host.activeTab?.tabID
        activeTab = tabs.first { $0.id == activeID }
        updateExtensionContext()
    }

    private func updateExtensionContext() {
        extensions.refresh(tabID: activeTab?.extensionTabID ?? -1)
    }
}
