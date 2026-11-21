import SwiftUI

struct CuriumSheetHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { dismiss() } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

enum CuriumJitPreference: String, CaseIterable, Identifiable {
    case automatic
    case jitless

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic (JIT when available)"
        case .jitless: return "Jitless Only"
        }
    }
}

struct CuriumSettingsSheet: View {
    @Binding var palette: CuriumPalette
    @Binding var siteMode: CuriumSiteMode
    @Bindable var library: CuriumLibrary
    @AppStorage("curium.jitMode") private var jitPreference: CuriumJitPreference = .automatic
    let engineReady: Bool

    private var activeV8RuntimeLabel: String {
        guard engineReady else { return "Standby" }
        switch CuriumActiveV8JitMode() {
        case 1: return "JIT · BrowserEngineCore"
        case 2: return "JIT · Native MAP_JIT"
        case 3: return "JIT · TXM Split-W^X"
        default: return "Jitless · DrumBrake Wasm"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Settings")
            List {
                Section("Search Engine") {
                    ForEach(CuriumSearchEngine.allCases) { engine in
                        Button {
                            library.searchEngine = engine
                        } label: {
                            HStack {
                                Text(engine.title).foregroundStyle(.primary)
                                Spacer()
                                if library.searchEngine == engine {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(library.searchEngine == engine ? .isSelected : [])
                    }
                }

                Section {
                    ForEach(CuriumSiteMode.allCases) { mode in
                        Button {
                            siteMode = mode
                        } label: {
                            HStack {
                                Text(mode.title).foregroundStyle(.primary)
                                Spacer()
                                if siteMode == mode {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(siteMode == mode ? .isSelected : [])
                    }
                } header: {
                    Text("Default Site Layout")
                } footer: {
                    Text("Duo Adaptive loads full Desktop layouts on the 7.6-inch unfolded display and Mobile layouts on the outer cover display.")
                }

                Section("Appearance") {
                    ForEach(CuriumPalette.allCases) { option in
                        Button {
                            palette = option
                        } label: {
                            HStack {
                                Circle()
                                    .fill(option.tint)
                                    .frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                Text(option.notation)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if palette == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(palette == option ? .isSelected : [])
                    }
                }
                Section {
                    ForEach(CuriumJitPreference.allCases) { option in
                        Button {
                            jitPreference = option
                        } label: {
                            HStack {
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                if jitPreference == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(jitPreference == option ? .isSelected : [])
                    }
                } header: {
                    Text("JavaScript Engine (V8)")
                } footer: {
                    Text("Applies on next launch. Under LiveContainer on iOS 26/27, enable Launch with JIT with StikDebug's universal.js script; otherwise Curium runs safely in Jitless mode.")
                }

                Section("Browser") {
                    LabeledContent("Engine", value: engineReady ? "Blink · Single-Process" : "Blink · Standby")
                    LabeledContent("V8 Runtime", value: activeV8RuntimeLabel)
                    LabeledContent("Extensions", value: "Manifest V3")
                    LabeledContent("Element", value: "96 Cm")
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
