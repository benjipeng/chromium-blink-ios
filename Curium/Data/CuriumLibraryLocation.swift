import Darwin
import Foundation
import OSLog
import SQLite3

/// Where the library database lives, and the one-time move into that place.
///
/// The store must outlive every way a guest app is replaced: an update, a container
/// reset, a re-import, or a second LiveContainer install. Candidates, most durable first:
///
/// 1. LiveContainer's App Group, shared by every LiveContainer install on the device.
/// 2. LiveContainer's host container, when the App Group is not available.
/// 3. The app's own Application Support, when Curium runs standalone.
///
/// The chosen file is never replaced. When it does not exist yet, the newest library
/// found at an older location is copied in; the original stays where it was.
enum CuriumLibraryLocation {
    static let fileName = "curium.sqlite"

    struct Resolution {
        let database: URL
        /// Older locations to adopt from, newest layout first.
        let legacy: [URL]
    }

    static func resolve() throws -> Resolution {
        let files = FileManager.default
        let standalone = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let ownLibrary = Self.library(in: standalone)

        guard let hostPath = ProcessInfo.processInfo.environment["LC_HOME_PATH"] else {
            return Resolution(database: ownLibrary, legacy: [])
        }
        let host = URL(fileURLWithPath: hostPath, isDirectory: true).standardizedFileURL
        let hostLibrary = Self.library(in: host.appending(path: "Library/Application Support", directoryHint: .isDirectory))

        if let group = sharedGroupContainer() {
            let groupLibrary = Self.library(in: group.appending(path: "Library/Application Support", directoryHint: .isDirectory))
            return Resolution(database: groupLibrary, legacy: [hostLibrary, ownLibrary])
        }
        log.notice("library: LiveContainer App Group unavailable; using the host container")
        return Resolution(database: hostLibrary, legacy: [ownLibrary])
    }

    /// Copies the newest legacy library into `resolution.database` if it does not exist.
    /// Safe when two LiveContainer instances launch at once: the copy is staged
    /// privately and installed with an exclusive rename, so the first one wins.
    static func adoptLegacyIfNeeded(_ resolution: Resolution) {
        let files = FileManager.default
        let target = resolution.database
        guard !files.fileExists(atPath: target.path) else { return }

        let source = resolution.legacy
            .filter { $0 != target && nonEmpty($0) }
            .max { modified($0) < modified($1) }
        guard let source else { return }

        do {
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let scratch = target.deletingLastPathComponent()
                .appending(path: ".\(fileName).\(UUID().uuidString).adopt")
            defer { try? files.removeItem(at: scratch) }
            try snapshot(source, into: scratch)
            if renamex_np(scratch.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { return } // Another instance adopted first.
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            log.notice("library: adopted \(source.path, privacy: .public) into \(target.path, privacy: .public)")
        } catch {
            // The source is untouched; the library opens empty and the next launch retries.
            log.error("library: could not adopt \(source.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Private

    private static func library(in support: URL) -> URL {
        support.appending(path: "Curium/\(fileName)", directoryHint: .notDirectory)
    }

    /// The real App Group container. LiveContainer redirects every other group ID into
    /// the guest's own container, so only its own `appGroupID` reaches shared storage.
    private static func sharedGroupContainer() -> URL? {
        guard let cls = NSClassFromString("LCSharedUtils") as AnyObject?,
              cls.responds(to: NSSelectorFromString("appGroupID")),
              let id = cls.perform(NSSelectorFromString("appGroupID"))?.takeUnretainedValue() as? String,
              !id.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    private static func nonEmpty(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    private static func modified(_ url: URL) -> Date {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let dates = [url, wal].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return dates.max() ?? .distantPast
    }

    /// A consistent copy that includes committed WAL frames.
    private static func snapshot(_ source: URL, into destination: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "VACUUM INTO ?", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, destination.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "library")
}
