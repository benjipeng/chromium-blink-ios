import CuriumEngineContract
import Observation
import UIKit

@MainActor
@Observable
final class CuriumTabModel: Identifiable {
    private static let maxSnapshotPixels: CGFloat = 768

    let id: String
    private(set) var engine: (any CrIOSTabHostingV1)?
    private(set) var url: URL?
    private(set) var title = "New Tab"
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var usesDesktopSite = false
    private(set) var zoomScale: CGFloat = 1.0
    private(set) var pageCanvasColor: UIColor?
    private(set) var isFullscreen = false
    private(set) var hasPlayingVideo = false
    private(set) var isPictureInPictureActive = false
    private(set) var extensionTabID: Int32 = -1
    private(set) var snapshot: UIImage?

    @ObservationIgnored private var history: [URL?] = [nil]
    @ObservationIgnored private var historyIndex = 0
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var snapshotCapturedRevision: Int?
    @ObservationIgnored private var configuredInitialSiteMode = false

    init() { id = UUID().uuidString }

    init(engine: any CrIOSTabHostingV1) {
        id = engine.tabID
        refresh(from: engine)
    }

    func refresh(from engine: any CrIOSTabHostingV1) {
        if self.engine !== engine { self.engine = engine }

        let newURL = engine.currentURL
        if url != newURL {
            url = newURL
            if newURL != nil { configuredInitialSiteMode = true }
            clearSnapshot()
        }

        let newTitle = engine.title.isEmpty ? (newURL?.host() ?? "New Tab") : engine.title
        if title != newTitle { title = newTitle }

        let wasLoading = isLoading
        let newIsLoading = engine.isLoading
        if isLoading != newIsLoading { isLoading = newIsLoading }
        if wasLoading && !newIsLoading {
            snapshotRevision += 1
        }

        let newProgress = min(1, max(0, engine.estimatedProgress))
        if progress != newProgress { progress = newProgress }

        let newCanGoBack = engine.canGoBack
        if canGoBack != newCanGoBack { canGoBack = newCanGoBack }

        let newCanGoForward = engine.canGoForward
        if canGoForward != newCanGoForward { canGoForward = newCanGoForward }

        let newDesktop = engine.usesDesktopUserAgent
        if usesDesktopSite != newDesktop { usesDesktopSite = newDesktop }

        let newCanvas = Self.resolvedCanvasColor(from: engine, hasURL: newURL != nil)
        if pageCanvasColor != newCanvas { pageCanvasColor = newCanvas }

        let newFullscreen = engine.isWebFullscreen
        if isFullscreen != newFullscreen { isFullscreen = newFullscreen }

        let newHasVideo = engine.hasPlayingVideo ?? false
        if hasPlayingVideo != newHasVideo { hasPlayingVideo = newHasVideo }

        let newPiP = engine.isPictureInPictureActive ?? false
        if isPictureInPictureActive != newPiP { isPictureInPictureActive = newPiP }

        let newExtTabID = engine.extensionTabID
        if extensionTabID != newExtTabID { extensionTabID = newExtTabID }
    }

    private static func isPureWhite(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return r > 0.995 && g > 0.995 && b > 0.995 && a > 0.995
    }

    private static func resolvedCanvasColor(from engine: any CrIOSTabHostingV1, hasURL: Bool) -> UIColor? {
        guard hasURL else { return nil }
        // ContentWebState::GetUnderPageBackgroundColor() defaults to opaque white even on dark
        // pages without <meta name="theme-color">, whereas RenderWidgetHostViewIOS updates
        // scrollView.backgroundColor with the live SkColor from Blink's RenderFrameMetadata.
        if let theme = engine.pageCanvasColor, !isPureWhite(theme) {
            return theme
        }
        if let liveBg = engine.scrollView?.backgroundColor {
            return liveBg
        }
        return engine.pageCanvasColor
    }

    func syncScrollCanvasColor() {
        guard let engine else { return }
        let next = Self.resolvedCanvasColor(from: engine, hasURL: url != nil)
        if pageCanvasColor != next {
            pageCanvasColor = next
        }
    }

    func applyDefaultSiteModeIfBlank(_ preferDesktop: Bool) {
        guard !configuredInitialSiteMode, url == nil, let engine else { return }
        if usesDesktopSite != preferDesktop {
            CuriumSetDesktopSite(engine, preferDesktop)
            usesDesktopSite = preferDesktop
        }
    }

    func load(_ url: URL, preferDesktop: Bool? = nil) {
        if let engine {
            if let preferDesktop, !configuredInitialSiteMode || self.url == nil {
                if usesDesktopSite != preferDesktop {
                    CuriumSetDesktopSite(engine, preferDesktop)
                    usesDesktopSite = preferDesktop
                }
            }
            configuredInitialSiteMode = true
            engine.load(url)
            return
        }
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

    func togglePictureInPicture() {
        guard let engine else { return }
        if isPictureInPictureActive {
            engine.exitPictureInPicture?()
        } else {
            engine.enterPictureInPicture?()
        }
    }

    func toggleDesktopSite() {
        guard let engine else { return }
        configuredInitialSiteMode = true
        let next = !usesDesktopSite
        usesDesktopSite = next
        CuriumSetDesktopSite(engine, next)
    }

    func setZoomScale(_ scale: CGFloat) {
        let clamped = min(2.0, max(0.5, scale))
        guard abs(zoomScale - clamped) > 0.001 else { return }
        zoomScale = clamped
        if let engine {
            CuriumSetPageZoom(engine, clamped)
        }
    }

    func reloadOrStop() {
        guard let engine else { return }
        if isLoading { engine.stopLoading() } else { engine.reload() }
    }

    func clearSnapshot() {
        if snapshot != nil { snapshot = nil }
        snapshotCapturedRevision = nil
        snapshotRevision += 1
    }

    var hasFreshSnapshot: Bool {
        snapshot != nil && snapshotCapturedRevision == snapshotRevision
    }

    /// Directly rasterizes the mounted webView into a compact 768 px SDR buffer (~1.5 MiB)
    /// instead of allocating a 22–45 MiB full-resolution screen bitmap first.
    @discardableResult
    func captureThumbnailDirectly() -> Bool {
        guard let engine, url != nil, !isFullscreen else { return false }
        if hasFreshSnapshot { return true }
        let webView = engine.webView
        let bounds = webView.bounds
        guard webView.window != nil, bounds.width > 1, bounds.height > 1 else { return false }

        let longest = max(bounds.width, bounds.height)
        let scaleFactor = min(1.0, Self.maxSnapshotPixels / longest)
        let targetSize = CGSize(
            width: max(1, (bounds.width * scaleFactor).rounded()),
            height: max(1, (bounds.height * scaleFactor).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let revision = snapshotRevision
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let image = renderer.image { _ in
            webView.drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: false)
        }
        snapshot = image
        snapshotCapturedRevision = revision
        return true
    }

    private func updateStandbyHistory() {
        let newURL = history[historyIndex]
        if url != newURL { url = newURL }
        let newTitle = newURL?.host() ?? "New Tab"
        if title != newTitle { title = newTitle }
        let newCanGoBack = historyIndex > 0
        if canGoBack != newCanGoBack { canGoBack = newCanGoBack }
        let newCanGoForward = historyIndex < history.count - 1
        if canGoForward != newCanGoForward { canGoForward = newCanGoForward }
    }
}

@MainActor
@Observable
final class CuriumBrowserStore: NSObject, CrIOSBrowserHostDelegateV1 {
    private static let maxRetainedSnapshots = 12
    private static let maxLiveTabs = 24
    private static let minTabAdmissionHeadroomBytes: UInt64 = 192 * 1024 * 1024

    private let host: (any CrIOSBrowserHostV1)?
    let extensions: CuriumExtensionStore
    private(set) var tabs: [CuriumTabModel] = []
    private(set) var activeTab: CuriumTabModel?
    private(set) var downloads: [CuriumDownload] = []
    private(set) var backgroundEpoch = 0
    var errorMessage: String?
    var requestShowTabs = false

    @ObservationIgnored private var tabsByID: [String: CuriumTabModel] = [:]
    @ObservationIgnored private var snapshotLRU: [String] = []
    @ObservationIgnored private var lastExtensionTabID: Int32 = -1
    @ObservationIgnored private var isUnderMemoryPressure = false
    @ObservationIgnored private var snapshotScheduled = false
    @ObservationIgnored private(set) var viewportWidth: CGFloat = 669

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

    func updateViewportWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        if abs(viewportWidth - width) >= 0.5 {
            viewportWidth = width
            syncDefaultSiteModeForBlankTabs()
        } else {
            syncDefaultSiteModeForBlankTabs()
        }
    }

    func syncDefaultSiteModeForBlankTabs() {
        let preferDesktop = prefersDesktopByDefault()
        for tab in tabs {
            tab.applyDefaultSiteModeIfBlank(preferDesktop)
        }
    }

    private func prefersDesktopByDefault() -> Bool {
        let raw = UserDefaults.standard.string(forKey: "curium.siteMode") ?? CuriumSiteMode.adaptive.rawValue
        let mode = CuriumSiteMode(rawValue: raw) ?? .adaptive
        return mode.prefersDesktop(forViewportWidth: viewportWidth)
    }

    func handleMemoryWarning() {
        isUnderMemoryPressure = true
        snapshotLRU.removeAll()
        for tab in tabs {
            tab.clearSnapshot()
        }
    }

    func handleSceneDidEnterBackground() {
        backgroundEpoch += 1
        // Retain at most the active tab's thumbnail in background to minimize idle footprint.
        let keepID = activeTab?.id
        snapshotLRU.removeAll { $0 != keepID }
        for tab in tabs where tab.id != keepID {
            tab.clearSnapshot()
        }
    }

    func handleSceneWillEnterForeground() {
        isUnderMemoryPressure = false
    }

    /// Schedules a deferred 768 px thumbnail capture on the next runloop turn so sheet
    /// presentation starts immediately without blocking frame 0.
    func scheduleSnapshotForActiveTab() {
        guard !isUnderMemoryPressure, !snapshotScheduled, let tab = activeTab, !tab.hasFreshSnapshot else { return }
        snapshotScheduled = true
        let targetID = tab.id
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.snapshotScheduled = false
            guard !self.isUnderMemoryPressure,
                  let current = self.activeTab,
                  current.id == targetID else { return }
            if current.captureThumbnailDirectly() {
                self.recordSnapshot(for: current.id)
            }
        }
    }

    private func captureOutgoingTabThumbnailIfEligible() {
        guard !isUnderMemoryPressure, let outgoing = activeTab else { return }
        if outgoing.captureThumbnailDirectly() {
            recordSnapshot(for: outgoing.id)
        }
    }

    func submitAddress(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if let candidate = URL(string: text),
           let scheme = candidate.scheme?.lowercased(), ["https", "http", "chrome"].contains(scheme),
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
        let preferDesktop = prefersDesktopByDefault()
        if let activeTab {
            activeTab.load(url, preferDesktop: preferDesktop)
        } else {
            newTab(url: url)
        }
    }

    private func canAdmitNewTab() -> Bool {
        if tabs.count >= Self.maxLiveTabs {
            errorMessage = "Single-process memory guard: close an unused tab before opening more than \(Self.maxLiveTabs) live tabs."
            requestShowTabs = true
            return false
        }
        let avail = CuriumAvailableMemoryBytes()
        if avail > 0 && avail < Self.minTabAdmissionHeadroomBytes {
            handleMemoryWarning()
            let recheck = CuriumAvailableMemoryBytes()
            if recheck > 0 && recheck < Self.minTabAdmissionHeadroomBytes {
                errorMessage = "Low device memory headroom. Close an existing tab to keep Blink responsive."
                requestShowTabs = true
                return false
            }
        }
        return true
    }

    @discardableResult
    func newTab(url: URL? = nil) -> Bool {
        if !tabs.isEmpty && !canAdmitNewTab() {
            return false
        }
        captureOutgoingTabThumbnailIfEligible()
        let preferDesktop = prefersDesktopByDefault()
        if let host {
            // Create the tab without immediately loading a mobile-UA URL so Desktop Site
            // preference can be applied before the initial navigation commits.
            guard let createdEngine = host.createTab(with: nil, activate: true) else {
                errorMessage = "Blink could not open a new tab."
                return false
            }
            updateTabs(from: host)
            if let model = tabsByID[createdEngine.tabID] {
                if preferDesktop {
                    CuriumSetDesktopSite(createdEngine, true)
                    model.refresh(from: createdEngine)
                }
                if let url {
                    model.load(url, preferDesktop: preferDesktop)
                }
            }
        } else {
            let tab = CuriumTabModel()
            if let url { tab.load(url, preferDesktop: preferDesktop) }
            tabs.append(tab)
            tabsByID[tab.id] = tab
            activeTab = tab
        }
        return true
    }

    func select(_ tab: CuriumTabModel) {
        guard activeTab?.id != tab.id else { return }
        captureOutgoingTabThumbnailIfEligible()
        if let host {
            guard host.activateTab(withID: tab.id) else { return }
            if let model = tabsByID[tab.id] {
                if let engine = model.engine {
                    model.refresh(from: engine)
                }
                activeTab = model
                updateExtensionContext(force: true)
            } else {
                updateTabs(from: host)
            }
        } else {
            activeTab = tab
        }
    }

    func close(_ tab: CuriumTabModel) {
        if let host {
            if host.closeTab(withID: tab.id) { updateTabs(from: host) }
        } else if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)
            tabsByID.removeValue(forKey: tab.id)
            snapshotLRU.removeAll { $0 == tab.id }
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
        guard let model = tabsByID[tab.tabID] else { return }
        let oldURL = model.url
        let oldExtID = model.extensionTabID
        model.refresh(from: tab)
        let contextChanged = model.url != oldURL || model.extensionTabID != oldExtID
        if activeTab === model && contextChanged { updateExtensionContext(force: true) }
    }

    func browserHost(_ host: any CrIOSBrowserHostV1, didCreateDownload download: any CrIOSDownloadTaskV1) {
        let item = CuriumDownload(task: download)
        guard !downloads.contains(where: { $0.id == item.id }) else { return }
        downloads.insert(item, at: 0)
    }

    private func recordSnapshot(for tabID: String) {
        snapshotLRU.removeAll { $0 == tabID }
        snapshotLRU.append(tabID)
        while snapshotLRU.count > Self.maxRetainedSnapshots {
            guard let evictIndex = snapshotLRU.firstIndex(where: { $0 != activeTab?.id }) else { break }
            let evictID = snapshotLRU.remove(at: evictIndex)
            tabsByID[evictID]?.clearSnapshot()
        }
    }

    private func updateTabs(from host: any CrIOSBrowserHostV1) {
        let hostTabs = host.tabs
        let activeID = host.activeTab?.tabID

        let orderMatches = hostTabs.count == tabs.count
            && zip(hostTabs, tabs).allSatisfy { $0.tabID == $1.id }
        let activeMatches = activeTab?.id == activeID

        if orderMatches && activeMatches {
            updateExtensionContext(force: false)
            return
        }

        if orderMatches, let activeID, let nextActive = tabsByID[activeID] {
            if let engine = host.activeTab {
                nextActive.refresh(from: engine)
            }
            if activeTab !== nextActive {
                activeTab = nextActive
            }
            updateExtensionContext(force: true)
            return
        }

        var nextTabs: [CuriumTabModel] = []
        nextTabs.reserveCapacity(hostTabs.count)
        var nextIndex: [String: CuriumTabModel] = [:]
        nextIndex.reserveCapacity(hostTabs.count)

        for engine in hostTabs {
            let tabID = engine.tabID
            if let existing = tabsByID[tabID] {
                if tabID == activeID { existing.refresh(from: engine) }
                nextTabs.append(existing)
                nextIndex[tabID] = existing
            } else {
                let created = CuriumTabModel(engine: engine)
                nextTabs.append(created)
                nextIndex[tabID] = created
            }
        }

        tabs = nextTabs
        tabsByID = nextIndex
        snapshotLRU.removeAll { nextIndex[$0] == nil }

        let nextActive = activeID.flatMap { nextIndex[$0] }
        if activeTab !== nextActive {
            activeTab = nextActive
        }
        updateExtensionContext(force: !activeMatches)
    }

    private func updateExtensionContext(force: Bool) {
        let currentExtTabID = activeTab?.extensionTabID ?? -1
        guard force || currentExtTabID != lastExtensionTabID else { return }
        lastExtensionTabID = currentExtTabID
        extensions.scheduleContextRefresh(tabID: currentExtTabID)
    }
}
