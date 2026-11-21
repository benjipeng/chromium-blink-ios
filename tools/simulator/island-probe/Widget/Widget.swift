import ActivityKit
import SwiftUI
import WidgetKit
@main struct ProbeBundle: WidgetBundle {
    var body: some Widget { ProbeLive() }
}
struct ProbeLive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProbeAttributes.self) { ctx in
            Text(ctx.state.label).padding()
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text(ctx.state.label) }
            } compactLeading: {
                Image(systemName: "music.note").foregroundStyle(.pink)
            } compactTrailing: {
                Image(systemName: "waveform").foregroundStyle(.pink)
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}
