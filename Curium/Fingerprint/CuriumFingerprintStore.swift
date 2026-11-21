import Foundation
import Observation
import OSLog

/// Durable Swift store for user-defined and built-in fingerprint profiles.
/// Lives beside `curium.sqlite` in the LiveContainer-durable support directory
/// (App Group -> Host Container -> Standalone Application Support).
@Observable
final class CuriumFingerprintStore {
    struct PersistedState: Codable, Equatable {
        var version: Int = 1
        /// `nil` means unconfigured Build 39 (`0105`) default mode.
        var selectedProfileID: String?
        var profiles: [CuriumFingerprintProfile]
    }

    static let fileName = "fingerprint-profiles.json"

    private let fileURL: URL
    private(set) var selectedProfileID: String?
    private(set) var profiles: [CuriumFingerprintProfile]

    /// The profile currently selected for next launch, or `nil` when using Build 39 defaults.
    var selectedProfile: CuriumFingerprintProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            self.selectedProfileID = decoded.selectedProfileID
            self.profiles = Self.mergedWithBuiltIns(decoded.profiles)
        } else {
            self.selectedProfileID = nil
            self.profiles = CuriumFingerprintPresets.allBuiltIns
        }
    }

    static func defaultStorageURL() -> URL {
        if let resolution = try? CuriumLibraryLocation.resolve() {
            return resolution.database
                .deletingLastPathComponent()
                .appending(path: fileName, directoryHint: .notDirectory)
        }
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Curium/\(fileName)", directoryHint: .notDirectory)
    }

    static func loadShared() -> CuriumFingerprintStore {
        CuriumFingerprintStore(fileURL: defaultStorageURL())
    }

    @discardableResult
    func selectProfile(id: String?) -> Bool {
        if let id, !profiles.contains(where: { $0.id == id }) {
            return false
        }
        selectedProfileID = id
        persist()
        return true
    }

    func resetToBuild39Default() {
        selectedProfileID = nil
        persist()
    }

    @discardableResult
    func upsert(_ profile: CuriumFingerprintProfile) -> CuriumFingerprintValidationReport {
        let report = CuriumFingerprintValidator.validate(profile)
        guard report.isValid else { return report }
        var updated = profile
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            updated.revision = max(profile.revision, profiles[idx].revision + 1)
            profiles[idx] = updated
        } else {
            updated.revision = max(profile.revision, 1)
            profiles.append(updated)
        }
        persist()
        return report
    }

    @discardableResult
    func deleteProfile(id: String) -> Bool {
        guard id != "default" else { return false }
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return false }
        guard !profiles[idx].isBuiltIn else { return false }
        profiles.remove(at: idx)
        if selectedProfileID == id {
            selectedProfileID = nil
        }
        persist()
        return true
    }

    func duplicateProfile(from sourceID: String, newID: String, displayName: String) -> CuriumFingerprintProfile? {
        guard CuriumFingerprintValidator.isValidProfileID(newID),
              newID != "default",
              !profiles.contains(where: { $0.id == newID }),
              var copy = profiles.first(where: { $0.id == sourceID })
        else { return nil }
        copy.id = newID
        copy.displayName = displayName
        copy.isBuiltIn = false
        copy.revision = 1
        profiles.append(copy)
        persist()
        return copy
    }

    func exportProfileJSON(id: String) throws -> Data {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    func importProfileJSON(_ data: Data) throws -> CuriumFingerprintValidationReport {
        var profile = try JSONDecoder().decode(CuriumFingerprintProfile.self, from: data)
        profile.isBuiltIn = false
        return upsert(profile)
    }

    private func persist() {
        let state = PersistedState(
            version: 1,
            selectedProfileID: selectedProfileID,
            profiles: profiles
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("fingerprint store persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func mergedWithBuiltIns(_ stored: [CuriumFingerprintProfile]) -> [CuriumFingerprintProfile] {
        var result = stored
        for builtIn in CuriumFingerprintPresets.allBuiltIns {
            if !result.contains(where: { $0.id == builtIn.id }) {
                result.append(builtIn)
            }
        }
        return result
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "fingerprint")
}

/// Pre-`ChromeMain` bootstrap coordinator that probes engine capabilities,
/// validates & registers bounded launch configuration bytes, and fails closed
/// on any rejected or unavailable explicit profile.
enum CuriumFingerprintBootstrap {
    enum LaunchOutcome: Equatable, Sendable {
        case defaultBuild39
        case configured(profileID: String, revision: UInt64, nativeHardware: Bool)
        case rejected(profileID: String, reason: String)
    }

    @MainActor
    static private(set) var lastOutcome: LaunchOutcome = .defaultBuild39

    @MainActor
    static func engineCapabilities() -> CuriumEngineFingerprintCapabilities {
        CuriumEngineFingerprintCapabilities(dictionary: CuriumEngineFingerprintCapabilitiesDict())
    }

    @MainActor
    static func activeEngineStatus() -> CuriumEngineFingerprintStatus? {
        guard let dict = CuriumEngineActiveFingerprintStatusDict() else { return nil }
        return CuriumEngineFingerprintStatus(dictionary: dict)
    }

    /// Runs once on the main thread before `ChromeMain`.
    /// Returns `.rejected` (fail closed) whenever an explicit profile is selected
    /// but missing, invalid, unsupported by the linked engine, or locked/unavailable.
    @MainActor
    static func prepareEngineLaunch(store: CuriumFingerprintStore = .loadShared()) -> LaunchOutcome {
        guard let selectedID = store.selectedProfileID else {
            _ = CuriumConfigureLaunchFingerprint(nil, nil)
            lastOutcome = .defaultBuild39
            return .defaultBuild39
        }
        guard let profile = store.profiles.first(where: { $0.id == selectedID }) else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "Selected profile \"\(selectedID)\" was not found in the profile store."
            )
            lastOutcome = outcome
            return outcome
        }

        let validation = CuriumFingerprintValidator.validate(profile)
        guard validation.isValid else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: validation.errors.joined(separator: " ")
            )
            lastOutcome = outcome
            return outcome
        }

        let caps = engineCapabilities()
        guard caps.supportsLaunchFingerprintConfig else {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "The embedded Blink engine does not support launch fingerprint profiles (requires Build 40+)."
            )
            lastOutcome = outcome
            return outcome
        }

        let jsonData: Data
        do {
            jsonData = try profile.makeEngineLaunchJSON()
        } catch {
            let outcome = LaunchOutcome.rejected(
                profileID: selectedID,
                reason: "Failed to encode profile JSON: \(error.localizedDescription)"
            )
            lastOutcome = outcome
            return outcome
        }

        var engineError: NSError?
        guard CuriumConfigureLaunchFingerprint(jsonData, &engineError) else {
            let reason = engineError?.localizedDescription
                ?? "Blink engine rejected launch fingerprint configuration."
            let outcome = LaunchOutcome.rejected(profileID: selectedID, reason: reason)
            lastOutcome = outcome
            return outcome
        }

        let outcome = LaunchOutcome.configured(
            profileID: profile.id,
            revision: profile.revision,
            nativeHardware: profile.usesNativeHardwareAndGPU
        )
        lastOutcome = outcome
        return outcome
    }
}
