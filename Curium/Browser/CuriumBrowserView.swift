import SwiftUI

struct CuriumBrowserView: View {
    @Bindable var store: CuriumBrowserStore
    @Binding var palette: CuriumPalette
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var placement = CuriumVerticalBarPlacement.none
    @State private var overlayHeight: CGFloat = 0
    @State private var address = ""
    @State private var viewportWidth: CGFloat = CuriumSpace.omniboxWidth
    @State private var sheet: Destination?
    @State private var confirmClear = false
    @FocusState private var addressFocused: Bool

    private enum Destination: String, Identifiable {
        case tabs, extensions, downloads, settings
        var id: Self { self }
    }

    private var tab: CuriumTabModel? { store.activeTab }
    private var hasVerticalBar: Bool { placement != .none }
    private var isFullscreen: Bool { tab?.isFullscreen == true }
    private var floatingInset: CGFloat { hasVerticalBar && !isFullscreen ? overlayHeight : 0 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color(uiColor: tab?.pageCanvasColor ?? .systemBackground)
                    .ignoresSafeArea(.all)

                CuriumBlinkViewportHost(
                    tab: tab, topOverlayHeight: floatingInset,
                    standby: CuriumStandbyPage(
                        url: tab?.url, topInset: floatingInset, engineReady: store.isEngineReady, palette: palette
                    )
                )
                .ignoresSafeArea(.keyboard)

                if hasVerticalBar && !isFullscreen {
                    floatingChrome(in: proxy)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        }
        .ignoresSafeArea(.keyboard)
        .background {
            CuriumVerticalBarReader { placement = $0 }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(isFullscreen ? .hidden : .visible, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar { browserToolbar }
        .onChange(of: tab?.id, initial: true) {
            addressFocused = false
            address = tab?.url?.absoluteString ?? ""
        }
        .onChange(of: tab?.url) {
            if !addressFocused { address = tab?.url?.absoluteString ?? "" }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .tabs: CuriumTabsSheet(store: store)
            case .extensions: CuriumExtensionsSheet(browser: store)
            case .downloads: CuriumDownloadsSheet(store: store)
            case .settings: CuriumSettingsSheet(palette: $palette, engineReady: store.isEngineReady)
            }
        }
        .confirmationDialog("Clear Blink Data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Browsing Data", role: .destructive) { Task { await store.clearBrowsingData() } }
        } message: {
            Text("This removes cookies, cached pages, and site storage. It may sign you out of websites.")
        }
        .alert("Curium", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        if !hasVerticalBar {
            ToolbarItem(placement: .principal) {
                addressCapsule(floating: false)
                    .frame(width: min(CuriumSpace.omniboxWidth, max(0, viewportWidth - 48)))
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { tab?.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(tab?.canGoBack != true)
            Button { tab?.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(tab?.canGoForward != true)
            Spacer()
            extensionsButton
            tabsButton
            overflowMenu
        }
    }

    private var extensionsButton: some View {
        let badge = store.extensions.badge
        return Button { present(.extensions) } label: {
            Label("Extensions", systemImage: "puzzlepiece.extension")
        }
        .badge(badge.map { Text(verbatim: $0) })
        .accessibilityValue(Text(verbatim: badge ?? ""))
    }

    private var tabsButton: some View {
        Button {
            tab?.requestSnapshot()
            present(.tabs)
        } label: {
            Label("Tabs", systemImage: "square.on.square")
        }
        .accessibilityValue(Text(store.tabs.count, format: .number))
    }

    private var overflowMenu: some View {
        Menu {
            Button { tab?.engine?.presentFindInPage() } label: {
                Label("Find in Page", systemImage: "magnifyingglass")
            }
            .disabled(tab?.url == nil || tab?.engine == nil)
            Button {
                tab?.toggleDesktopSite()
            } label: {
                Label(tab?.usesDesktopSite == true ? "Mobile Site" : "Desktop Site", systemImage: "desktopcomputer")
            }
            .disabled(tab?.url == nil || tab?.engine == nil)
            Button { present(.downloads) } label: { Label("Downloads", systemImage: "arrow.down.circle") }
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear Blink Data", systemImage: "trash")
            }
            .disabled(!store.isEngineReady)
            Button { present(.settings) } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private func present(_ destination: Destination) {
        addressFocused = false
        sheet = destination
    }

    private func floatingChrome(in proxy: GeometryProxy) -> some View {
        let corner = proxy.containerCornerInsets
        let leading = max(14, corner.topLeading.width + 6)
        let trailing = max(14, corner.topTrailing.width + 6)
        let clearance = chromeClearance(in: proxy, leading: leading, trailing: trailing)

        return addressCapsule(floating: true)
            .frame(maxWidth: CuriumSpace.omniboxWidth)
            .frame(maxWidth: .infinity)
            .padding(.leading, clearance.leading)
            .padding(.trailing, clearance.trailing)
            .padding(.top, max(8, clearance.top))
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overlayHeight = $0 }
    }

    private func chromeClearance(in proxy: GeometryProxy, leading: CGFloat, trailing: CGFloat)
        -> (leading: CGFloat, trailing: CGFloat, top: CGFloat) {
        guard #available(iOS 27.1, *) else { return (leading, trailing, 8) }
        let width = proxy.size.width
        let band = CGRect(x: 0, y: 0, width: width, height: 64)
        var left = layoutDirection == .leftToRight ? leading : trailing
        var right = layoutDirection == .leftToRight ? trailing : leading
        var top: CGFloat = 8
        let regions = proxy.reservedRegions(kind: .occlusion) + proxy.reservedRegions(kind: .division)
        for region in regions where region.isActive && region.frame.intersects(band) {
            let frame = region.frame
            let leftRoom = frame.minX - left
            let rightRoom = width - right - frame.maxX
            if max(leftRoom, rightRoom) >= 150 {
                if leftRoom > rightRoom { right = max(right, width - frame.minX + 8) }
                else { left = max(left, frame.maxX + 8) }
            } else {
                top = max(top, frame.maxY + 8)
            }
        }
        return layoutDirection == .leftToRight ? (left, right, top) : (right, left, top)
    }

    private func addressCapsule(floating: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search or enter address", text: $address,
                      prompt: Text("Search or enter address").foregroundStyle(CuriumSpace.secondaryInk))
                .textFieldStyle(.plain)
                .font(.body)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($addressFocused)
                .onSubmit {
                    addressFocused = false
                    store.submitAddress(address)
                }
                .accessibilityIdentifier("curium.address")

            if addressFocused && !address.isEmpty {
                Button { address = "" } label: {
                    Label("Clear Address", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                        .frame(width: CuriumSpace.tapTarget, height: CuriumSpace.tapTarget)
                }
                .buttonStyle(.plain)
            } else if let tab, tab.engine != nil && (tab.url != nil || tab.isLoading) {
                Button { tab.reloadOrStop() } label: {
                    Label(tab.isLoading ? "Stop Loading" : "Reload",
                          systemImage: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: CuriumSpace.tapTarget, height: CuriumSpace.tapTarget)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, addressFocused && !address.isEmpty || tab?.url != nil && tab?.engine != nil ? 2 : 14)
        .frame(minHeight: CuriumSpace.tapTarget)
        .background {
            if !floating {
                Capsule().fill(Color(uiColor: .secondarySystemBackground))
            }
        }
        .modifier(CuriumFloatingAddressGlass(enabled: floating))
        .overlay(alignment: .bottom) {
            if let tab, tab.isLoading {
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct CuriumFloatingAddressGlass: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
        }
    }
}

struct CuriumStandbyPage: View {
    let url: URL?
    let topInset: CGFloat
    let engineReady: Bool
    let palette: CuriumPalette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("96").font(.system(.caption, design: .monospaced).weight(.semibold))
                    Text("Cm").font(.system(size: 40, weight: .medium, design: .serif))
                        .tracking(-2.5)
                }
                .foregroundStyle(palette.tint)
                .frame(width: 96, height: 96)
                .background(palette.tile, in: .rect(cornerRadius: 22))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Curium, element 96")

                VStack(alignment: .leading, spacing: 9) {
                    Text(url?.host() ?? "Curium")
                        .font(.system(.largeTitle, design: .serif).weight(.medium))
                    Text(engineReady ? "Waiting for Blink to open a tab." :
                         "Tabs and address history are available for this session. Loading websites requires Blink.")
                        .font(.callout)
                        .foregroundStyle(CuriumSpace.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label("ENGINE STANDBY", systemImage: "circle.dotted")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(palette.tint)
            }
            .frame(maxWidth: 380, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, topInset + 46)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
