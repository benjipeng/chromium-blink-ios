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

struct CuriumSettingsSheet: View {
    @Binding var palette: CuriumPalette
    let engineReady: Bool

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Settings")
            List {
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
                Section("Browser") {
                    LabeledContent("Engine", value: engineReady ? "Blink" : "Blink · Standby")
                    LabeledContent("Extensions", value: "Manifest V3")
                    LabeledContent("Element", value: "96 Cm")
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
