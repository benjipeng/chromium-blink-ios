import CuriumEngineContract
import SwiftUI
import UIKit

@main
@MainActor
enum CuriumApp {
    static func main() {
        #if CURIUM_LINKED_ENGINE
        if CuriumRegisterShell(CuriumShellBootstrap()) {
            exit(ChromeMain(CommandLine.argc, CommandLine.unsafeArgv))
        }
        #endif
        CuriumStandbyApp.main()
    }
}

private struct CuriumStandbyApp: App {
    var body: some Scene {
        WindowGroup { CuriumStandbyWindow() }
    }
}

private struct CuriumStandbyWindow: View {
    @State private var store = CuriumBrowserStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CuriumScene(store: store)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.library.checkpoint() }
            }
    }
}

struct CuriumScene: View {
    let store: CuriumBrowserStore
    @AppStorage("curium.palette") private var palette = CuriumPalette.violet
    @AppStorage("curium.siteMode") private var siteMode = CuriumSiteMode.adaptive

    var body: some View {
        NavigationStack {
            CuriumBrowserView(store: store, palette: $palette, siteMode: $siteMode)
        }
        .tint(palette.tint)
        .environment(\.curiumPalette, palette)
        .onChange(of: siteMode, initial: true) { _, _ in
            store.syncDefaultSiteModeForBlankTabs()
        }
    }
}

private final class CuriumShellBootstrap: NSObject, CrIOSShellBootstrapDelegate {
    func makeRootViewController(
        for windowScene: UIWindowScene,
        browserHost: any CrIOSBrowserHostV1,
        extensionManager: (any CrIOSExtensionManagingV1)?
    ) -> UIViewController {
        let store = CuriumBrowserStore(host: browserHost, extensionManager: extensionManager)
        return CuriumSceneHostingController(windowScene: windowScene, store: store)
    }
}

@MainActor
private final class CuriumSceneHostingController: UIHostingController<CuriumScene> {
    private let store: CuriumBrowserStore
    private weak var observedScene: UIWindowScene?

    init(windowScene: UIWindowScene, store: CuriumBrowserStore) {
        self.store = store
        self.observedScene = windowScene
        super.init(rootView: CuriumScene(store: store))
        installLifecycleObservers(for: windowScene)
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("Use init(windowScene:store:).")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func installLifecycleObservers(for windowScene: UIWindowScene) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onSceneDidEnterBackground),
            name: UIScene.didEnterBackgroundNotification,
            object: windowScene
        )
        center.addObserver(
            self,
            selector: #selector(onSceneWillEnterForeground),
            name: UIScene.willEnterForegroundNotification,
            object: windowScene
        )
    }

    @objc private func onMemoryWarning(_ notification: Notification) {
        store.handleMemoryWarning()
    }

    @objc private func onSceneDidEnterBackground(_ notification: Notification) {
        store.library.checkpoint()
        store.handleSceneDidEnterBackground()
    }

    @objc private func onSceneWillEnterForeground(_ notification: Notification) {
        store.handleSceneWillEnterForeground()
    }
}
