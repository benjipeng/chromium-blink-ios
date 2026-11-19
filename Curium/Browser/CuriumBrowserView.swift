import SwiftUI

struct CuriumBrowserView: View {
    @Bindable var store: CuriumBrowserStore
    @Binding var palette: CuriumPalette
    @Binding var siteMode: CuriumSiteMode
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var placement = CuriumVerticalBarPlacement.none
    @State private var sheet: Destination?
    @State private var confirmClear = false
    @State private var dismissKeyboardTrigger = 0

    private enum Destination: String, Identifiable {
        case tabs, extensions, downloads, settings
        var id: Self { self }
    }

    private var tab: CuriumTabModel? { store.activeTab }
    private var isFullscreen: Bool { tab?.isFullscreen == true }

    var body: some View {
        GeometryReader { proxy in
            let clearance = topChromeClearance(in: proxy)
            let restingTopInset: CGFloat = isFullscreen ? 0 : clearance.bandFloor

            ZStack(alignment: .top) {
                Color(uiColor: tab?.pageCanvasColor ?? .systemBackground)
                    .ignoresSafeArea(.all)

                CuriumBlinkViewportHost(
                    tab: tab,
                    restingTopInset: restingTopInset,
                    standby: CuriumStandbyPage(
                        url: tab?.url, topInset: restingTopInset, engineReady: store.isEngineReady, palette: palette
                    )
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .ignoresSafeArea(.keyboard)

                if !isFullscreen {
                    CuriumAddressBar(
                        store: store,
                        tab: tab,
                        dismissKeyboardTrigger: dismissKeyboardTrigger
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.leading, clearance.leading)
                    .padding(.trailing, clearance.trailing)
                    .padding(.top, clearance.top)
                    .padding(.bottom, 8)
                    .ignoresSafeArea(.container, edges: .top)
                }

                if !isFullscreen, let storeID = CuriumExtensionStore.storeExtensionID(from: tab?.url) {
                    VStack {
                        Spacer()
                        storeInstallPill(storeID: storeID)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, placement == .none ? 12 : 14)
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, newWidth in
                store.updateViewportWidth(newWidth)
            }
        }
        .ignoresSafeArea(.keyboard)
        .background {
            CuriumVerticalBarReader { placement = $0 }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(isFullscreen ? .hidden : .visible, for: .bottomBar)
        .toolbar { browserToolbar }
        .onChange(of: store.requestShowTabs) { _, requested in
            if requested {
                store.requestShowTabs = false
                present(.tabs)
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .tabs: CuriumTabsSheet(store: store)
            case .extensions: CuriumExtensionsSheet(browser: store)
            case .downloads: CuriumDownloadsSheet(store: store)
            case .settings: CuriumSettingsSheet(palette: $palette, siteMode: $siteMode, engineReady: store.isEngineReady)
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
        ToolbarItemGroup(placement: .bottomBar) {
            Button { tab?.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(tab?.canGoBack != true)
            Button { tab?.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(tab?.canGoForward != true)
            Spacer()
            Button {
                store.newTab()
            } label: { Label("New Tab", systemImage: "plus") }
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
            present(.tabs)
            store.scheduleSnapshotForActiveTab()
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

            if tab?.hasPlayingVideo == true || tab?.isPictureInPictureActive == true {
                Button {
                    tab?.togglePictureInPicture()
                } label: {
                    Label(
                        tab?.isPictureInPictureActive == true ? "Exit Picture in Picture" : "Picture in Picture",
                        systemImage: tab?.isPictureInPictureActive == true ? "pip.exit" : "pip.enter"
                    )
                }
            }

            Button {
                tab?.toggleDesktopSite()
            } label: {
                Label(
                    tab?.usesDesktopSite == true ? "Request Mobile Site" : "Request Desktop Site",
                    systemImage: tab?.usesDesktopSite == true ? "iphone" : "desktopcomputer"
                )
            }
            .disabled(tab?.engine == nil)

            Menu {
                ForEach([0.85, 1.0, 1.15, 1.25], id: \.self) { scale in
                    Button {
                        tab?.setZoomScale(scale)
                    } label: {
                        let pct = Int((scale * 100).rounded())
                        if abs((tab?.zoomScale ?? 1.0) - scale) < 0.01 {
                            Label("\(pct)%", systemImage: "checkmark")
                        } else {
                            Text("\(pct)%")
                        }
                    }
                }
            } label: {
                Label("Page Scale", systemImage: "textformat.size")
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
        dismissKeyboardTrigger += 1
        sheet = destination
    }

    private struct TopChromeClearance: Equatable {
        let leading: CGFloat
        let trailing: CGFloat
        let top: CGFloat
        let bandFloor: CGFloat
    }

    private func topChromeClearance(in proxy: GeometryProxy) -> TopChromeClearance {
        let width = proxy.size.width
        let safeTop = proxy.safeAreaInsets.top
        let corner = proxy.containerCornerInsets

        let baseSide: CGFloat = width < 420 ? 16 : 24
        let remLeading = max(0, corner.topLeading.width - proxy.safeAreaInsets.leading)
        let remTrailing = max(0, corner.topTrailing.width - proxy.safeAreaInsets.trailing)

        // Concentric clearance for iPhone Duo's 59 pt outer physical corners (R_screen = 59, R_cap = 22):
        // radialClearance = 37 - hypot(37 - side, 37 - top).
        // - Inner Landscape (safeTop == 0, remLeading == 59): top = 20, side = 36 -> 19.97 pt radial & 20.0 pt top.
        // - Inner Portrait (safeTop == 82): top = 26 (y-center 48 pt = status cluster), side = 24 -> 19.97 pt radial.
        // - Outer Portrait (safeTop == 0, hinge corner 8 pt): exposedHardwareCorner == false -> top = 14, side = 16.
        let exposedHardwareCorner = safeTop < 70 && max(remLeading, remTrailing) > 20
        let sideClearance: CGFloat = exposedHardwareCorner ? 36 : baseSide

        var left = sideClearance
        var right = sideClearance
        var top: CGFloat = safeTop >= 70 ? 26 : (exposedHardwareCorner ? 20 : 14)
        var bandFloor: CGFloat = safeTop >= 70 ? safeTop : (top + CuriumSpace.tapTarget + 10)

        guard #available(iOS 27.1, *) else {
            return TopChromeClearance(
                leading: layoutDirection == .leftToRight ? left : right,
                trailing: layoutDirection == .leftToRight ? right : left,
                top: top,
                bandFloor: bandFloor
            )
        }

        var asymmetricHorizontalConstraint = false

        // 1. Top-edge hardware/status .occlusion inside our width.
        let topBand = CGRect(x: 0, y: 0, width: width, height: 110)
        for region in proxy.reservedRegions(kind: .occlusion) where region.isActive {
            let frame = region.frame.offsetBy(dx: 0, dy: safeTop)
            guard frame.height < 160,
                  frame.minX < width - 2,
                  frame.maxX > 2,
                  frame.intersects(topBand) else { continue }
            let clampedMinX = max(0, frame.minX)
            let clampedMaxX = min(width, frame.maxX)
            let leftRoom = clampedMinX - left
            let rightRoom = width - right - clampedMaxX
            if max(leftRoom, rightRoom) >= 160 {
                if leftRoom >= rightRoom {
                    right = max(right, width - clampedMinX + 10)
                } else {
                    left = max(left, clampedMaxX + 10)
                }
                asymmetricHorizontalConstraint = true
                bandFloor = max(bandFloor, min(110, frame.maxY))
            } else {
                top = max(top, min(110, frame.maxY + 8))
                bandFloor = max(bandFloor, top + CuriumSpace.tapTarget + 10)
            }
        }

        // 2. Active vertical .division (half-folded Book Pose crease).
        for region in proxy.reservedRegions(kind: .division) where region.isActive {
            let frame = region.frame
            guard frame.height > frame.width,
                  frame.minX < width - 2,
                  frame.maxX > 2 else { continue }
            let leftRoom = frame.minX - left
            let rightRoom = width - right - frame.maxX
            if leftRoom >= rightRoom && leftRoom >= 160 {
                right = max(right, width - frame.minX + 20)
                asymmetricHorizontalConstraint = true
            } else if rightRoom >= 160 {
                left = max(left, frame.maxX + 20)
                asymmetricHorizontalConstraint = true
            }
        }

        // Preserve exact left-right symmetry whenever neither an active status occlusion
        // nor an active fold division claims one side of the top band.
        if !asymmetricHorizontalConstraint {
            let sym = max(left, right)
            left = sym
            right = sym
        }

        return TopChromeClearance(
            leading: layoutDirection == .leftToRight ? left : right,
            trailing: layoutDirection == .leftToRight ? right : left,
            top: top,
            bandFloor: bandFloor
        )
    }

    @ViewBuilder
    private func storeInstallPill(storeID: String) -> some View {
        let alreadyInstalled = store.extensions.isInstalled(storeID)
        Button {
            if alreadyInstalled {
                present(.extensions)
            } else {
                store.extensions.prepareStoreExtension(id: storeID)
                present(.extensions)
            }
        } label: {
            HStack(spacing: 8) {
                if store.extensions.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: alreadyInstalled ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.callout.weight(.semibold))
                }
                Text(alreadyInstalled ? "Installed in Curium" : "Add to Curium")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(alreadyInstalled ? AnyShapeStyle(.secondary) : AnyShapeStyle(palette.tint))
            .padding(.horizontal, 18)
            .frame(minHeight: CuriumSpace.tapTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityIdentifier("curium.store.install")
    }
}

private struct CuriumAddressBar: View {
    let store: CuriumBrowserStore
    let tab: CuriumTabModel?
    let dismissKeyboardTrigger: Int

    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab?.usesDesktopSite == true ? "desktopcomputer" : "magnifyingglass")
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
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay(alignment: .bottom) {
            if let tab {
                CuriumProgressOverlay(tab: tab)
            }
        }
        .onChange(of: tab?.id, initial: true) {
            addressFocused = false
            address = tab?.url?.absoluteString ?? ""
        }
        .onChange(of: tab?.url) {
            if !addressFocused { address = tab?.url?.absoluteString ?? "" }
        }
        .onChange(of: dismissKeyboardTrigger) {
            addressFocused = false
        }
    }
}

private struct CuriumProgressOverlay: View {
    let tab: CuriumTabModel

    var body: some View {
        if tab.isLoading {
            ProgressView(value: tab.progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
