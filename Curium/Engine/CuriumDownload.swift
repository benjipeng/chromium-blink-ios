import CuriumEngineContract
import Observation
import UIKit

@MainActor
@Observable
final class CuriumDownload: Identifiable {
    let id: String
    let filename: String
    let mimeType: String?
    private let task: any CrIOSDownloadTaskV1
    private(set) var state: CrIOSDownloadState
    private(set) var savedURL: URL?
    private(set) var failure: String?
    private(set) var fraction: Double?
    private(set) var isStarting = false

    init(task: any CrIOSDownloadTaskV1) {
        self.task = task
        id = task.downloadID
        let name = (task.suggestedFilename as NSString).lastPathComponent
        filename = ["", "/", ".", ".."].contains(name) ? "Download" : name
        mimeType = task.mimeType
        state = task.state
        refresh()
    }

    var isPDF: Bool {
        mimeType?.caseInsensitiveCompare("application/pdf") == .orderedSame
            || (filename as NSString).pathExtension.lowercased() == "pdf"
    }

    func refresh() {
        state = task.state
        fraction = task.totalBytes > 0 ? min(1, max(0, Double(task.receivedBytes) / Double(task.totalBytes))) : nil
    }

    func start() async {
        guard state == .pending, !isStarting else { return }
        isStarting = true
        failure = nil
        defer { isStarting = false; refresh() }
        do {
            let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let directory = root.appending(path: "Downloads", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            savedURL = try await task.start(withDestinationURL: directory.appending(path: filename))
        } catch {
            if task.state != .cancelled { failure = error.localizedDescription }
        }
    }

    func cancel() {
        task.cancel()
        refresh()
    }
}
