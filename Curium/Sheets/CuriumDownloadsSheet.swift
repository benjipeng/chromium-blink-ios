import CuriumEngineContract
import PDFKit
import QuickLook
import SwiftUI

struct CuriumDownloadsSheet: View {
    let store: CuriumBrowserStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: Preview?

    private struct Preview: Identifiable {
        let url: URL
        let filename: String
        let isPDF: Bool
        var id: URL { url }
    }

    private var hasActiveDownloads: Bool {
        store.downloads.contains { $0.isActive }
    }

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Downloads")
            if store.downloads.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.to.line")
                } description: {
                    Text(store.isEngineReady ? "Downloads from Blink will appear here." : "Downloads will be available when Blink is ready.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(store.downloads) { item in
                    downloadRow(item)
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: scenePhase == .active && hasActiveDownloads) {
            guard scenePhase == .active, hasActiveDownloads else { return }
            while !Task.isCancelled {
                for item in store.downloads where item.isActive {
                    item.refresh()
                }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
            }
        }
        .sheet(item: $preview) { file in
            VStack(spacing: 0) {
                CuriumSheetHeader(title: file.filename)
                if file.isPDF {
                    CuriumPDFPreview(url: file.url)
                } else {
                    CuriumQuickLookPreview(url: file.url)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private func downloadRow(_ item: CuriumDownload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(item.filename, systemImage: item.isPDF ? "doc.richtext" : "doc")
                .font(.headline)
            if let failure = item.failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary)
            }
            if item.isActive {
                if let fraction = item.fraction {
                    ProgressView(value: fraction).accessibilityLabel("Download progress")
                } else {
                    ProgressView("Downloading…")
                }
                Button(role: .cancel) { item.cancel() } label: { Label("Cancel Download", systemImage: "xmark") }
            } else {
                switch item.state {
                case .pending:
                    Button { Task { await item.start() } } label: {
                        Label("Save Download", systemImage: "arrow.down.circle")
                    }
                case .completed:
                    if let url = item.savedURL {
                        Button {
                            preview = Preview(url: url, filename: item.filename, isPDF: item.isPDF)
                        } label: {
                            Label("Preview", systemImage: "eye")
                        }
                    } else {
                        Text("Saved").foregroundStyle(.secondary)
                    }
                case .cancelled:
                    Text("Canceled").foregroundStyle(.secondary)
                case .failed:
                    if item.failure == nil { Text("Download failed").foregroundStyle(.secondary) }
                case .inProgress:
                    EmptyView()
                @unknown default:
                    Text("Status unavailable").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct CuriumPDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

private struct CuriumQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
