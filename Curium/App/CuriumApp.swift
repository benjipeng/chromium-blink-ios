import CuriumEngineContract
import SwiftUI
import UIKit

@main
@MainActor
enum CuriumApp {
    static func main() {
        #if CURIUM_LINKED_ENGINE
        let launchOutcome = CuriumFingerprintBootstrap.prepareEngineLaunch()
        switch launchOutcome {
        case .rejected:
            // Fail closed: never silently open the default cookie jar when an
            // explicitly selected profile failed validation or directory binding.
            CuriumStandbyApp.main()
            return
        case .defaultBuild39, .configured:
            if CuriumRegisterShell(CuriumShellBootstrap()) {
                exit(ChromeMain(CommandLine.argc, CommandLine.unsafeArgv))
            }
        }
        #endif
        CuriumStandbyApp.main()
    }
}

private struct CuriumStandbyApp: App {
    var body: some Scene {
        WindowGroup {
            if case .rejected(let profileID, let reason) = CuriumFingerprintBootstrap.lastOutcome {
                CuriumProfileLaunchRecoveryView(profileID: profileID, reason: reason)
            } else {
                CuriumStandbyWindow()
            }
        }
    }
}

private struct CuriumProfileLaunchRecoveryView: View {
    let profileID: String
    let reason: String
    @State private var resetCompleted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled.trianglebadge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Profile Launch Blocked")
                .font(.title2.weight(.semibold))
            Text("Profile \"\(profileID)\" could not be opened safely, so Curium stopped before loading the default profile.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(reason)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: 420)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            if resetCompleted {
                Text("Reset to Default (Build 39) saved. Close and relaunch Curium.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("Reset to Default Profile for Next Launch") {
                    let store = CuriumFingerprintStore.loadShared()
                    store.resetToBuild39Default()
                    resetCompleted = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}

private struct CuriumStandbyWindow: View {
    @State private var store = CuriumBrowserStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CuriumScene(store: store)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive:
                    store.handleSceneWillDeactivate()
                    CuriumCheckpointRunner.run(library: store.library, reason: "StandbyInactive")
                case .background:
                    store.handleSceneDidEnterBackground()
                    CuriumCheckpointRunner.run(library: store.library, reason: "StandbyBackground")
                case .active:
                    store.handleSceneWillEnterForeground()
                @unknown default:
                    break
                }
            }
    }
}

@MainActor
private final class CuriumBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.end() }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.end() }
                }
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}

@MainActor
private enum CuriumCheckpointRunner {
    static func run(library: CuriumLibrary, reason: String) {
        let taskGuard = CuriumBackgroundTask(name: "CuriumSQLiteCheckpoint-\(reason)")
        Task { @MainActor in
            await library.checkpointAsync()
            taskGuard.end()
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
            selector: #selector(onSceneWillDeactivate),
            name: UIScene.willDeactivateNotification,
            object: windowScene
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

    @objc private func onSceneWillDeactivate(_ notification: Notification) {
        store.handleSceneWillDeactivate()
        CuriumCheckpointRunner.run(library: store.library, reason: "WillDeactivate")
    }

    @objc private func onSceneDidEnterBackground(_ notification: Notification) {
        store.handleSceneDidEnterBackground()
        CuriumCheckpointRunner.run(library: store.library, reason: "DidEnterBackground")
    }

    @objc private func onSceneWillEnterForeground(_ notification: Notification) {
        store.handleSceneWillEnterForeground()
    }
}
