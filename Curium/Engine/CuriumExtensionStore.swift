import CuriumEngineContract
import Observation
import UIKit

struct CuriumExtension: Identifiable {
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
    private let manager: (any CrIOSExtensionManagingV1)?
    @ObservationIgnored private var observation: (any NSObjectProtocol)?
    @ObservationIgnored private var installGeneration = 0
    private var tabID: Int32 = -1
    private(set) var installed: [CuriumExtension] = []
    private(set) var isWorking = false
    private(set) var review: CuriumExtensionReview?
    private(set) var listError: String?
    var operationError: String?

    var isAvailable: Bool { manager != nil }
    var badge: String? {
        let badges = installed.filter(\.isEnabled).compactMap(\.badge)
        if badges.count == 1 { return badges[0] }
        return badges.isEmpty ? nil : String(badges.count)
    }

    var blockedCount: Int? {
        let counts = installed.compactMap(\.blockedCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    init(manager: (any CrIOSExtensionManagingV1)?) {
        self.manager = manager
        observation = manager?.observeActionPresentationChanges?(handler: { [weak self] _ in
            guard let self else { return }
            self.refresh(tabID: self.tabID)
        })
    }

    func refresh(tabID: Int32) {
        guard let manager else { return }
        self.tabID = tabID
        do {
            installed = try manager.extensions().compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                let action = tabID >= 0 ? CuriumExtensionAction(manager, id, tabID) : nil
                let count = tabID >= 0 ? CuriumExtensionBlockedCount(manager, id, tabID) : nil
                return CuriumExtension(entry: entry, action: action, blockedCount: count?.intValue)
            }
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, for item: CuriumExtension) {
        do {
            try manager?.setExtensionWithID(item.id, enabled: enabled)
            refresh(tabID: tabID)
        } catch { operationError = error.localizedDescription }
    }

    func remove(_ item: CuriumExtension) {
        guard let manager, item.isRemovable else { return }
        CuriumRemoveExtension(manager, item.id) { [weak self] removed, error in
            guard let self else { return }
            if !removed { self.operationError = error?.localizedDescription ?? "Blink could not remove this extension." }
            self.refresh(tabID: self.tabID)
        }
    }

    func prepareStoreLink(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input), url.scheme == "https",
              ["chromewebstore.google.com", "chrome.google.com"].contains(url.host()),
              let id = url.pathComponents.last,
              id.wholeMatch(of: /[a-p]{32}/) != nil else {
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
            self.refresh(tabID: self.tabID)
            if result == nil || error != nil {
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
