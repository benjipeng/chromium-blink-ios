import ActivityKit
import SwiftUI
@main struct ProbeApp: App {
    @State private var status = "idle"
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text(status)
                Button("Start") { start() }
                Button("End") { Task { for a in Activity<ProbeAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }; status = "ended" } }
            }
            .onAppear { start() }
        }
    }
    func start() {
        guard Activity<ProbeAttributes>.activities.isEmpty else { status = "running"; return }
        do {
            _ = try Activity.request(attributes: ProbeAttributes(), content: .init(state: .init(label: "Now Playing"), staleDate: nil))
            status = "started"
        } catch { status = "error \(error)" }
    }
}
