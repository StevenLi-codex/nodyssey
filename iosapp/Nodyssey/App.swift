import UIKit
import SwiftUI
import NodysseyShell

/// Platform lifecycle only. Kotlin remains the owner of the single repository graph,
/// persistent account data and background downloads; SwiftUI owns the visible application.
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    // Process lifetime preserves each tab's navigation when UIKit reconnects the scene.
    // UIApplicationSupportsMultipleScenes is false, so there is one live native shell.
    let nativeApp = NativeAppModel()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // BGTaskScheduler registration must finish before application launch returns.
        NodysseyApp.shared.registerBackgroundTasks()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: session.role)
    }
}

/// Keep the scene lifecycle required by modern UIKit. NativeRootView starts the shared
/// graph asynchronously through its model; never call the old Compose controller factory.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var nativeApp: NativeAppModel? {
        (UIApplication.shared.delegate as? AppDelegate)?.nativeApp
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene, let app = nativeApp else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        window.rootViewController = UIHostingController(
            rootView: NativeRootView().environmentObject(app)
        )
        window.makeKeyAndVisible()

        // The model resolves links against the active site, including during graph startup.
        for context in connectionOptions.urlContexts {
            app.openLink(context.url.absoluteString)
        }
        for activity in connectionOptions.userActivities {
            if activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL {
                app.openLink(url.absoluteString)
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            nativeApp?.openLink(context.url.absoluteString)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        nativeApp?.openLink(url.absoluteString)
    }
}
