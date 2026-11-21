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
            // Fail closed: launch a dedicated UIKit recovery delegate that
            // overrides Info.plist's Chromium SceneDelegate manifest so the
            // recovery UI renders cleanly without ever starting ChromeMain.
            UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(CuriumRecoveryApplicationDelegate.self)
            )
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

@MainActor
private final class CuriumRecoveryApplicationDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = CuriumRecoverySceneDelegate.self
        return config
    }
}

@MainActor
private final class CuriumRecoverySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard case .rejected(let profileID, let reason) = CuriumFingerprintBootstrap.lastOutcome else {
            // A previous blocked launch left a persisted recovery UISceneSession.
            // Replace it with a fresh default session so ChromeMain's SceneDelegate attaches.
            let app = UIApplication.shared
            app.requestSceneSessionDestruction(session, options: nil)
            app.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: CuriumProfileLaunchRecoveryView(profileID: profileID, reason: reason)
        )
        window.makeKeyAndVisible()
        self.window = window
    }
}

private struct CuriumProfileLaunchRecoveryView: View {
    let profileID: String
    let reason: String
    @State private var store = CuriumFingerprintStore.loadShared()
    @State private var statusMessage: String?
    @State private var persistFailed = false
    @State private var copiedDetails = false

    private var alternativeProfiles: [CuriumFingerprintProfile] {
        store.profiles.filter {
            $0.id != profileID && CuriumFingerprintValidator.validate($0).isValid
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "shield.lefthalf.filled.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Profile Launch Blocked")
                    .font(.title2.weight(.semibold))
                Text("Profile \"\(profileID)\" could not be opened safely, so Curium stopped before loading the default profile.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(reason)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: 440, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(persistFailed ? .red : .green)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button("Reset to Default Profile for Next Launch") {
                        if store.resetToBuild39Default() {
                            persistFailed = false
                            statusMessage = "Reset to Default (Build 39) saved. Close and relaunch Curium."
                        } else {
                            persistFailed = true
                            statusMessage = store.lastPersistError ?? "Could not write profile store to disk."
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if !alternativeProfiles.isEmpty {
                        Menu {
                            ForEach(alternativeProfiles) { profile in
                                Button("\(profile.displayName) (\(profile.id))") {
                                    if store.selectProfile(id: profile.id) {
                                        persistFailed = false
                                        statusMessage = "Switched next launch to \"\(profile.displayName)\". Close and relaunch Curium."
                                    } else {
                                        persistFailed = true
                                        statusMessage = store.lastPersistError ?? "Could not write profile store to disk."
                                    }
                                }
                            }
                        } label: {
                            Label("Switch to Another Profile for Next Launch", systemImage: "person.2.crop.square.stack")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        UIPasteboard.general.string = "Curium Profile Launch Blocked\nProfile: \(profileID)\nReason: \(reason)"
                        copiedDetails = true
                    } label: {
                        Label(
                            copiedDetails ? "Error Details Copied" : "Copy Error Details",
                            systemImage: copiedDetails ? "checkmark.circle" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(uiColor: .systemGroupedBackground))
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
