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

    var body: some View { CuriumScene(store: store) }
}

struct CuriumScene: View {
    let store: CuriumBrowserStore
    @AppStorage("curium.palette") private var palette = CuriumPalette.violet

    var body: some View {
        NavigationStack {
            CuriumBrowserView(store: store, palette: $palette)
        }
        .tint(palette.tint)
        .environment(\.curiumPalette, palette)
    }
}

private final class CuriumShellBootstrap: NSObject, CrIOSShellBootstrapDelegate {
    func makeRootViewController(
        for windowScene: UIWindowScene,
        browserHost: any CrIOSBrowserHostV1,
        extensionManager: (any CrIOSExtensionManagingV1)?
    ) -> UIViewController {
        let store = CuriumBrowserStore(host: browserHost, extensionManager: extensionManager)
        return UIHostingController(rootView: CuriumScene(store: store))
    }
}
