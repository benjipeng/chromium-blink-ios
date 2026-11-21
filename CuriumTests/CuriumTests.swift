import CuriumEngineContract
import Darwin
import Foundation
import Testing
import UIKit

// MARK: - Protocol Mocks

@MainActor
private final class MockTabHost: NSObject, CrIOSTabHostingV1, CrIOSTabBrowserControlsV1 {
    let tabID: String
    var extensionTabID: Int32
    let webView: UIView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let scrollView: UIScrollView? = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    var currentURL: URL?
    var title: String
    var isLoading = false
    var estimatedProgress = 0.0
    var canGoBack = false
    var canGoForward = false
    var usesDesktopUserAgent = false
    var pageCanvasColor: UIColor?
    var isWebFullscreen = false
    var topControlsHeight: CGFloat = 0
    var topControlsShownRatio: CGFloat = 1.0
    var hasPlayingVideo = false
    var isPictureInPictureActive = false

    private(set) var loadedURLs: [URL] = []
    private(set) var snapshotCallCount = 0
    var snapshotImageToReturn: UIImage?

    init(
        tabID: String = UUID().uuidString,
        extensionTabID: Int32 = 1,
        url: URL? = nil,
        title: String = ""
    ) {
        self.tabID = tabID
        self.extensionTabID = extensionTabID
        self.currentURL = url
        self.title = title
        super.init()
    }

    func load(_ url: URL) {
        loadedURLs.append(url)
        currentURL = url
    }

    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func setUsesDesktopUserAgent(_ desktop: Bool) { usesDesktopUserAgent = desktop }
    func presentFindInPage() {}
    func setPageZoomScale(_ scale: CGFloat) {}

    func takeSnapshot(completion: @escaping @MainActor (UIImage?) -> Void) {
        snapshotCallCount += 1
        completion(snapshotImageToReturn)
    }
}

@MainActor
private final class MockBrowserHost: NSObject, CrIOSBrowserHostV1 {
    weak var delegate: (any CrIOSBrowserHostDelegateV1)?
    var tabs: [any CrIOSTabHostingV1] = []
    var activeTab: (any CrIOSTabHostingV1)?
    var failCreateTab = false

    func createTab(with url: URL?, activate: Bool) -> (any CrIOSTabHostingV1)? {
        guard !failCreateTab else { return nil }
        let tab = MockTabHost(extensionTabID: Int32(tabs.count + 1), url: url)
        tabs.append(tab)
        if activate || activeTab == nil { activeTab = tab }
        return tab
    }

    func activateTab(withID tabID: String) -> Bool {
        guard let target = tabs.first(where: { $0.tabID == tabID }) else { return false }
        activeTab = target
        return true
    }

    func closeTab(withID tabID: String) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.tabID == tabID }) else { return false }
        let removed = tabs.remove(at: idx)
        if activeTab?.tabID == removed.tabID {
            activeTab = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)]
        }
        return true
    }

    func clearBrowsingData(
        of types: CrIOSBrowsingDataTypes,
        modifiedSince date: Date,
        completion: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) {
        completion(nil)
    }

    func cookieHeader(
        for url: URL,
        inTabWithID tabID: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        completion(nil)
    }
}

private final class MockExtensionManager: NSObject, CrIOSExtensionManagingV1 {
    var entries: [[String: Any]] = []
    var actionSnapshots: [String: [String: Any]] = [:]
    var blockedCounts: [String: NSNumber] = [:]
    var actionCalls: [(String, Int32)] = []
    var extensionsCalls = 0
    var actionObserver: (@MainActor (String?) -> Void)?

    func extensions() throws -> [[String: Any]] {
        extensionsCalls += 1
        return entries
    }

    func setExtensionWithID(_ extensionId: String?, enabled: Bool) throws {
        if let extensionId,
           let idx = entries.firstIndex(where: { ($0["id"] as? String) == extensionId }) {
            entries[idx]["enabled"] = enabled
        }
    }

    func actionPresentationForExtension(withID extensionID: String, tabID: Int32) throws -> [String: Any] {
        actionCalls.append((extensionID, tabID))
        return actionSnapshots[extensionID] ?? [:]
    }

    func observeActionPresentationChanges(handler: @escaping @MainActor (String?) -> Void) -> (any NSObjectProtocol)? {
        actionObserver = handler
        return NSObject()
    }

    func blockedRequestCountForExtension(withID extensionID: String, tabID: Int32) throws -> NSNumber {
        blockedCounts[extensionID] ?? 0
    }

    func popupForExtension(withID extensionID: String, tabID: Int32) throws -> any CrIOSExtensionPopupHostingV1 {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }

    func commandsForExtension(withID extensionID: String) throws -> [[String: String]] { [] }
    func dispatchCommandNamed(_ commandName: String, toExtensionWithID extensionID: String) throws {}
}

// MARK: - Suites

@Suite("Chrome & PiP State")
struct CuriumStateTests {
    @Test("Chrome collapse clamps, quantizes sub-pixel noise, and respects pin/focus")
    func chromeCollapseQuantizationAndPin() {
        var chrome = CuriumChromeState()
        #expect(chrome.collapse(focused: false, hasPage: true) == 0)

        chrome.engineReported(collapse: 0.002)
        #expect(chrome.collapse(focused: false, hasPage: true) == 0)

        chrome.engineReported(collapse: 0.997)
        #expect(chrome.collapse(focused: false, hasPage: true) == 1)

        chrome.engineReported(collapse: 0.4)
        #expect(chrome.collapse(focused: true, hasPage: true) == 0)
        #expect(chrome.collapse(focused: false, hasPage: false) == 0)

        chrome.pin()
        #expect(chrome.pinnedOpen)
        #expect(chrome.collapse(focused: false, hasPage: true) == 0)

        chrome.engineReported(collapse: 0.0)
        #expect(!chrome.pinnedOpen)
    }

    @Test("PiP state transitions through available, starting, refused, active, and unsupported")
    func pipStateTransitions() {
        var unsupported = CuriumPictureInPictureState(systemSupported: false)
        unsupported.engineReported(hasVideo: true, active: false)
        #expect(unsupported.phase == .unavailable)
        #expect(unsupported.requested() == nil)

        var pip = CuriumPictureInPictureState(systemSupported: true)
        pip.engineReported(hasVideo: true, active: false)
        #expect(pip.phase == .available)
        #expect(pip.requested() == .enter)
        #expect(pip.phase == .starting)

        pip.confirmationTimedOut()
        #expect(pip.phase == .refused)

        pip.hintExpired()
        #expect(pip.phase == .available)

        _ = pip.requested()
        pip.engineReported(hasVideo: true, active: true)
        #expect(pip.phase == .active)
        #expect(pip.requested() == .exit)
    }
}

@Suite("SQLite Library & WAL Protection")
struct CuriumDatabaseTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Bookmarks, history visits, frecency search, and suspend-locked xattr")
    func databaseVisitsBookmarksAndXattr() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appending(path: "curium.sqlite", directoryHint: .notDirectory)
        let db = CuriumDatabase(databaseURL: dbURL)

        let exampleURL = URL(string: "https://example.com/docs")!
        try await db.recordVisit(url: exampleURL, title: "Example Docs", at: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await db.updateTitle("Example Reference", for: exampleURL)

        let tree = try await db.saveBookmark(
            url: URL(string: "https://webkit.org/")!,
            title: "WebKit",
            in: CuriumBookmarkFolder.favoritesID,
            at: Date(timeIntervalSince1970: 1_700_000_100)
        )
        #expect(tree.favorites.count == 1)
        #expect(tree.isBookmarked(URL(string: "https://webkit.org/")!))

        let days = try await db.historyDays(matching: "reference", limit: 10, calendar: .current)
        #expect(days.count == 1)
        #expect(days[0].entries.first?.title == "Example Reference")

        let matches = try await db.addressMatches(for: "example", limit: 6, now: Date(timeIntervalSince1970: 1_700_000_200))
        #expect(matches.contains { $0.url == exampleURL && $0.kind == .history })

        try await db.checkpoint()

        // Verify runningboard suspend-locked xattr is applied to the main SQLite file.
        var flag: UInt8 = 0
        let xattrSize = getxattr(dbURL.path, "com.apple.runningboard.can-suspend-locked", &flag, 1, 0, 0)
        #expect(xattrSize == 1)
        #expect(flag == 1)
    }

    @Test("Folder cycle guard rejects moving folder inside itself")
    func bookmarkFolderCycleGuard() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = CuriumDatabase(databaseURL: dir.appending(path: "curium.sqlite", directoryHint: .notDirectory))
        let tree1 = try await db.saveBookmarkFolder(id: nil, title: "Parent", in: nil, at: .now)
        let parentID = try #require(tree1.items(in: nil).compactMap { item -> Int64? in
            if case .folder(let folder) = item, folder.title == "Parent" { return folder.id }
            return nil
        }.first)

        let tree2 = try await db.saveBookmarkFolder(id: nil, title: "Child", in: parentID, at: .now)
        let childID = try #require(tree2.items(in: parentID).compactMap { item -> Int64? in
            if case .folder(let folder) = item, folder.title == "Child" { return folder.id }
            return nil
        }.first)

        await #expect(throws: Error.self) {
            _ = try await db.saveBookmarkFolder(id: parentID, title: "Parent", in: childID, at: .now)
        }
    }

    @Test("Legacy adoption skips corrupt source without creating empty target")
    func legacyAdoptionFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let corruptLegacy = dir.appending(path: "legacy.sqlite", directoryHint: .notDirectory)
        try Data("not-a-sqlite-db".utf8).write(to: corruptLegacy)
        let target = dir.appending(path: "target/curium.sqlite", directoryHint: .notDirectory)

        let resolution = CuriumLibraryLocation.Resolution(database: target, legacy: [corruptLegacy])
        _ = CuriumLibraryLocation.adoptLegacyIfNeeded(resolution)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

@Suite("Browser & Extension Stores")
@MainActor
struct CuriumStoreTests {
    @Test("Browser store invalidates closed tabs and recovers from last-tab close")
    func browserStoreTabLifecycle() {
        let host = MockBrowserHost()
        let first = MockTabHost(tabID: "t1", extensionTabID: 10, url: URL(string: "https://example.com"))
        let second = MockTabHost(tabID: "t2", extensionTabID: 11, url: URL(string: "https://curium.test"))
        host.tabs = [first, second]
        host.activeTab = first

        let store = CuriumBrowserStore(host: host, extensionManager: MockExtensionManager())
        #expect(store.tabs.count == 2)
        #expect(store.activeTab?.id == "t1")

        let firstModel = store.tabs[0]
        let secondModel = store.tabs[1]
        store.close(firstModel)
        #expect(firstModel.engine == nil)
        #expect(firstModel.webView == nil)
        #expect(store.tabs.count == 1)
        #expect(store.activeTab?.id == "t2")

        // Simulating last tab closed by webpage `window.close()`
        _ = host.closeTab(withID: "t2")
        store.browserHostDidUpdateTabs(host)
        #expect(secondModel.engine == nil)
        #expect(store.tabs.count == 1)
        #expect(store.activeTab != nil)
        #expect(store.activeTab?.id != "t2")
    }

    @Test("Extension store parses Chrome Web Store URLs and refreshes targeted actions")
    func extensionStoreTargetedRefresh() async throws {
        let extID = String(repeating: "a", count: 32)
        let storeURL = URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(extID)")!
        #expect(CuriumExtensionStore.storeExtensionID(from: storeURL) == extID)
        #expect(CuriumExtensionStore.storeExtensionID(from: URL(string: "https://example.com/\(extID)")) == nil)

        let manager = MockExtensionManager()
        manager.entries = [
            ["id": extID, "name": "uBOL", "version": "1.0", "enabled": true, "removable": true]
        ]
        manager.actionSnapshots[extID] = ["badgeText": "3", "isEnabled": true, "hasPopup": true]

        let store = CuriumExtensionStore(manager: manager)
        store.refresh(tabID: 1, includeBlockedCounts: false)
        #expect(store.installed.count == 1)
        #expect(store.badge == "3")
        let initialListCalls = manager.extensionsCalls

        manager.actionSnapshots[extID] = ["badgeText": "7", "isEnabled": true, "hasPopup": true]
        manager.actionObserver?(extID)
        try await Task.sleep(for: .milliseconds(200))

        #expect(manager.extensionsCalls == initialListCalls)
        #expect(store.badge == "7")
    }
}

@Suite("Diagnostics & Compact Pill Layout")
struct CuriumDiagnosticsAndLayoutTests {
    @Test("Diagnostics ring buffer caps lines and rotates log file at maxFileBytes")
    func diagnosticsRingBufferAndRotation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "curium-diag-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let diag = CuriumDiagnostics(
            directory: dir,
            maxFileBytes: 1200,
            maxRingLines: 5,
            observeSystemNotifications: false
        )
        for idx in 0..<25 {
            diag.record("test", "event-\(idx) payload=0123456789abcdef0123456789abcdef")
        }
        diag.flushSync()
        for idx in 25..<40 {
            diag.record("test", "event-\(idx) payload=0123456789abcdef0123456789abcdef")
        }
        diag.flushSync()

        let lines = diag.currentLines()
        #expect(lines.count == 5)
        #expect(lines.last?.contains("event-39") == true)

        let logURL = try #require(diag.logFileURL)
        let prevURL = dir.appending(path: CuriumDiagnostics.rotatedFileName, directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: logURL.path))
        #expect(FileManager.default.fileExists(atPath: prevURL.path))
    }

    @Test("Compact pill shifts below centered cutout and narrows beside side occlusion")
    @MainActor
    func compactPillGeometry() {
        let normal = CuriumBrowserView.compactPill(centerX: 200, maxWidth: 360, obstacles: [])
        #expect(normal.top == CuriumSpace.compactPillTop)
        #expect(normal.maxWidth == 360)

        let sideCluster = CuriumBrowserView.compactPill(
            centerX: 300,
            maxWidth: 500,
            obstacles: [CGRect(x: 420, y: 0, width: 160, height: 60)]
        )
        #expect(sideCluster.top == CuriumSpace.compactPillTop)
        #expect(sideCluster.maxWidth == 240)

        let centeredCutout = CuriumBrowserView.compactPill(
            centerX: 200,
            maxWidth: 360,
            obstacles: [CGRect(x: 150, y: 0, width: 100, height: 48)]
        )
        #expect(centeredCutout.top == 54)
    }

    @Test("Diagnostics hook summary distinguishes all-active, skipped, and failed hooks")
    func diagnosticsHookSummary() {
        let allActive = [
            CuriumDiagnostics.HookStatus(name: "A", status: "active", detail: ""),
            CuriumDiagnostics.HookStatus(name: "B", status: "active", detail: ""),
        ]
        #expect(CuriumDiagnostics.summarizeHooks(allActive) == ("2/2 active", false))

        let withSkipped = [
            CuriumDiagnostics.HookStatus(name: "A", status: "active", detail: ""),
            CuriumDiagnostics.HookStatus(name: "V8 JIT Probe", status: "skipped", detail: "no debugger"),
        ]
        #expect(CuriumDiagnostics.summarizeHooks(withSkipped) == ("1 active · 1 skipped", false))

        let withFailed = [
            CuriumDiagnostics.HookStatus(name: "A", status: "active", detail: ""),
            CuriumDiagnostics.HookStatus(name: "V8 JIT Probe", status: "failed", detail: "TXM probe returned 0"),
        ]
        #expect(CuriumDiagnostics.summarizeHooks(withFailed) == ("1 failed · 1/2 active", true))
    }

    @Test("Accept-Language normalization preserves BCP-47 scripts, deduplicates, validates, and caps at 4")
    func acceptLanguageNormalization() {
        #expect(
            CuriumNormalizedAcceptLanguages(["zh-Hant-HK", "zh_hans_cn", "en-US", "es-419", "fr-FR"])
                == "zh-Hant-HK,zh-Hans-CN,en-US,es-419"
        )
        #expect(
            CuriumNormalizedAcceptLanguages(["en-us", "EN_US", " zh-Hant-TW ", "zh-hant-tw"])
                == "en-US,zh-Hant-TW"
        )
        #expect(
            CuriumNormalizedAcceptLanguages(["", "en--US", "en;q=0.9", "123-US", "en-u", "sr-Latn-RS"])
                == "sr-Latn-RS"
        )
        #expect(CuriumNormalizedAcceptLanguages(nil) == "en-US,en")
        #expect(CuriumNormalizedAcceptLanguages(["bad;header"]) == "en-US,en")
    }
}
