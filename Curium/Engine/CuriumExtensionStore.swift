import CuriumEngineContract
import Observation
import UIKit

struct CuriumExtension: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let isEnabled: Bool
    let isRemovable: Bool
    let optionsURL: URL?
    let badge: String?
    let canShowPopup: Bool
    let blockedCount: Int?

    init?(entry: [String: Any], action: [String: Any]?, blockedCount: Int?) {
        guard let id = entry["id"] as? String else { return nil }
        self.id = id
        name = entry["name"] as? String ?? id
        version = entry["version"] as? String ?? ""
        isEnabled = entry["enabled"] as? Bool ?? false
        isRemovable = entry["removable"] as? Bool ?? false
        if let string = entry["optionsPageURL"] as? String,
           let url = URL(string: string), url.scheme == "chrome-extension", url.host() == id {
            optionsURL = url
        } else {
            optionsURL = nil
        }
        badge = (action?["badgeText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        canShowPopup = isEnabled && action?["isEnabled"] as? Bool == true && action?["hasPopup"] as? Bool == true
        self.blockedCount = blockedCount
    }

    private init(
        id: String, name: String, version: String, isEnabled: Bool, isRemovable: Bool,
        optionsURL: URL?, badge: String?, canShowPopup: Bool, blockedCount: Int?
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isRemovable = isRemovable
        self.optionsURL = optionsURL
        self.badge = badge
        self.canShowPopup = canShowPopup
        self.blockedCount = blockedCount
    }

    func updating(action: [String: Any]?, blockedCount: Int?) -> CuriumExtension {
        let nextBadge = (action?["badgeText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let nextCanShowPopup = isEnabled && action?["isEnabled"] as? Bool == true && action?["hasPopup"] as? Bool == true
        return CuriumExtension(
            id: id, name: name, version: version, isEnabled: isEnabled, isRemovable: isRemovable,
            optionsURL: optionsURL, badge: nextBadge, canShowPopup: nextCanShowPopup, blockedCount: blockedCount
        )
    }

    func updating(blockedCount: Int?) -> CuriumExtension {
        CuriumExtension(
            id: id, name: name, version: version, isEnabled: isEnabled, isRemovable: isRemovable,
            optionsURL: optionsURL, badge: badge, canShowPopup: canShowPopup, blockedCount: blockedCount
        )
    }
}

struct CuriumExtensionReview: Identifiable {
    let id: String
    let name: String
    let version: String
    let permissions: [String]
    let hosts: [String]

    init?(_ result: [String: Any]) {
        guard let token = result["token"] as? String, !token.isEmpty else { return nil }
        id = token
        name = result["name"] as? String ?? "Extension"
        version = result["version"] as? String ?? ""
        permissions = result["permissions"] as? [String] ?? []
        hosts = result["hostPermissions"] as? [String] ?? []
    }
}

@MainActor
@Observable
final class CuriumExtensionStore {
    private static let windows = NSHashTable<CuriumExtensionStore>.weakObjects()

    private let manager: (any CrIOSExtensionManagingV1)?
    @ObservationIgnored private var observation: (any NSObjectProtocol)?
    @ObservationIgnored private var installGeneration = 0
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var installedRefreshScheduled = false
    @ObservationIgnored private var hasLoadedInstalled = false
    private var tabID: Int32 = -1
    private(set) var installed: [CuriumExtension] = []
    private(set) var badge: String?
    private(set) var isWorking = false
    private(set) var review: CuriumExtensionReview?
    private(set) var listError: String?
    var operationError: String?

    var isAvailable: Bool { manager != nil }
    var hasEnabledExtensions: Bool { installed.contains { $0.isEnabled } }

    var blockedCount: Int? {
        let counts = installed.compactMap(\.blockedCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    init(manager: (any CrIOSExtensionManagingV1)?) {
        self.manager = manager
        if let manager {
            Self.windows.add(self)
            observation = manager.observeActionPresentationChanges?(handler: { [weak self] _ in
                // V1 uses the same notification for registry and action changes.
                self?.invalidateInstalled()
            })
        }
    }

    func scheduleContextRefresh(tabID: Int32) {
        self.tabID = tabID
        contextGeneration += 1
        // An empty list stays valid until an explicit refresh or manager notification.
        guard manager != nil, !hasLoadedInstalled || !installed.isEmpty else { return }
        let gen = contextGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.contextGeneration == gen else { return }
            if !self.hasLoadedInstalled {
                self.refresh(tabID: tabID, includeBlockedCounts: false)
            } else {
                self.refreshActionsOnly(tabID: tabID)
            }
        }
    }

    private func invalidateInstalled() {
        hasLoadedInstalled = false
        guard !installedRefreshScheduled else { return }
        installedRefreshScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.installedRefreshScheduled = false
            if !self.hasLoadedInstalled {
                self.refresh(tabID: self.tabID, includeBlockedCounts: false)
            }
        }
    }

    private func didMutateInstalled() {
        // The registry is shared, and V1 may not notify peers after install or removal.
        for window in Self.windows.allObjects where window !== self {
            window.invalidateInstalled()
        }
        hasLoadedInstalled = false
        refresh(tabID: tabID)
    }

    private func publishInstalled(_ next: [CuriumExtension]) {
        guard installed != next else { return }
        installed = next
        let badges = next.filter(\.isEnabled).compactMap(\.badge)
        let nextBadge = badges.count > 1 ? String(badges.count) : badges.first
        if badge != nextBadge { badge = nextBadge }
    }

    private func refreshActionsOnly(tabID: Int32) {
        guard let manager, !installed.isEmpty else { return }
        self.tabID = tabID
        var updated = installed
        for index in updated.indices {
            let item = updated[index]
            let action = (tabID >= 0 && item.isEnabled) ? CuriumExtensionAction(manager, item.id, tabID) : nil
            updated[index] = item.updating(action: action, blockedCount: nil)
        }
        publishInstalled(updated)
    }

    func refresh(tabID: Int32, includeBlockedCounts: Bool = true) {
        guard let manager else { return }
        self.tabID = tabID
        let existingCounts = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0.blockedCount) })
        do {
            let next: [CuriumExtension] = try manager.extensions().compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                let enabled = entry["enabled"] as? Bool ?? false
                let action = (tabID >= 0 && enabled) ? CuriumExtensionAction(manager, id, tabID) : nil
                let count: Int?
                if tabID >= 0 && enabled {
                    count = includeBlockedCounts
                        ? CuriumExtensionBlockedCount(manager, id, tabID)?.intValue
                        : (existingCounts[id] ?? nil)
                } else {
                    count = nil
                }
                return CuriumExtension(entry: entry, action: action, blockedCount: count)
            }
            hasLoadedInstalled = true
            publishInstalled(next)
            if listError != nil { listError = nil }
        } catch {
            let message = error.localizedDescription
            if listError != message { listError = message }
        }
    }

    func refreshBlockedCounts(tabID: Int32) {
        guard let manager else { return }
        if self.tabID != tabID || !hasLoadedInstalled {
            refresh(tabID: tabID, includeBlockedCounts: true)
            return
        }
        guard tabID >= 0, !installed.isEmpty else { return }
        var updated = installed
        for index in updated.indices where updated[index].isEnabled {
            let item = updated[index]
            let count = CuriumExtensionBlockedCount(manager, item.id, tabID)?.intValue
            updated[index] = item.updating(blockedCount: count)
        }
        publishInstalled(updated)
    }

    func setEnabled(_ enabled: Bool, for item: CuriumExtension) {
        guard let manager else { return }
        do {
            try manager.setExtensionWithID(item.id, enabled: enabled)
            didMutateInstalled()
        } catch { operationError = error.localizedDescription }
    }

    func remove(_ item: CuriumExtension) {
        guard let manager, item.isRemovable else { return }
        CuriumRemoveExtension(manager, item.id) { [weak self] removed, error in
            guard let self else { return }
            if removed {
                self.didMutateInstalled()
            } else {
                self.operationError = error?.localizedDescription ?? "Blink could not remove this extension."
            }
        }
    }

    static func storeExtensionID(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(),
              ["chromewebstore.google.com", "chrome.google.com"].contains(host) else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.contains("detail"),
              let candidate = parts.last,
              candidate.wholeMatch(of: /[a-p]{32}/) != nil else {
            return nil
        }
        return candidate
    }

    func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    func prepareStoreExtension(id: String) {
        guard id.wholeMatch(of: /[a-p]{32}/) != nil else {
            operationError = "Invalid Chrome Web Store extension identifier."
            return
        }
        prepare(source: id, isStore: true)
    }

    func prepareStoreLink(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = Self.storeExtensionID(from: URL(string: input)) else {
            operationError = "Enter the HTTPS link to a Chrome Web Store extension listing."
            return
        }
        prepare(source: id, isStore: true)
    }

    func prepareSignedFile(_ url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "crx" else {
            operationError = "Choose a signed CRX file."
            return
        }
        prepare(source: url.path(), isStore: false, scopedURL: url)
    }

    private func prepare(source: String, isStore: Bool, scopedURL: URL? = nil) {
        guard let manager, !isWorking, review == nil else { return }
        isWorking = true
        let generation = installGeneration
        let hasAccess = scopedURL?.startAccessingSecurityScopedResource() ?? false
        CuriumPrepareExtension(manager, source, isStore) { [weak self] result, error in
            if hasAccess { scopedURL?.stopAccessingSecurityScopedResource() }
            let review = result.flatMap(CuriumExtensionReview.init)
            guard let self else {
                if let review { CuriumCancelExtension(manager, review.id) }
                return
            }
            self.isWorking = false
            guard self.installGeneration == generation else {
                if let review { CuriumCancelExtension(manager, review.id) }
                return
            }
            if let review, error == nil {
                self.review = review
            } else {
                if let review { CuriumCancelExtension(manager, review.id) }
                self.operationError = error?.localizedDescription ?? "Blink could not verify the extension package."
            }
        }
    }

    func endInstallSession() {
        installGeneration += 1
        cancelReview()
    }

    func cancelReview() {
        if let manager, let review { CuriumCancelExtension(manager, review.id) }
        review = nil
    }

    func confirmReview() {
        guard let manager, let review else { return }
        isWorking = true
        self.review = nil
        CuriumConfirmExtension(manager, review.id) { [weak self] result, error in
            guard let self else { return }
            self.isWorking = false
            if result != nil, error == nil {
                self.didMutateInstalled()
            } else {
                self.operationError = error?.localizedDescription ?? "Blink could not install the extension."
            }
        }
    }

    func popup(for item: CuriumExtension) -> (any CrIOSExtensionPopupHostingV1)? {
        guard let manager, tabID >= 0, item.canShowPopup else { return nil }
        var error: NSError?
        let host = CuriumExtensionPopup(manager, item.id, tabID, &error)
        if host == nil { operationError = error?.localizedDescription ?? "Blink could not open the extension." }
        return host
    }
}
