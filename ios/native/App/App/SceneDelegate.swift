import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.backgroundColor = .black
        window?.rootViewController = HarborRootViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)

        #if DEBUG
        // Test builds: `-HarborPlayerTest <video URL> [<Arabic subtitle URL>]` opens the player
        // straight away (the simulator check in the iOS build, where nobody can tap).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-HarborPlayerTest"), i + 1 < args.count {
            var source: [String: Any] = ["url": args[i + 1], "title": "Player test", "prefSubLangs": ["ar"], "uiLang": "ar"]
            if i + 2 < args.count { source["subtitles"] = [["url": args[i + 2], "lang": "ar", "label": "Arabic (test)"]] }
            let json = String(data: (try? JSONSerialization.data(withJSONObject: source)) ?? Data(), encoding: .utf8) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let src = PlayerSource(json: json) else { return }
                let player = HarborPlayerViewController(source: src) { print("[player event] \($0)") }
                self?.window?.rootViewController?.present(player, animated: false)
            }
        }
        #endif
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

/// The app's one screen: Harbor's web UI below the status bar. The page has no room for the status
/// bar at the top (its buttons would sit under the clock), so the web view starts below it; at the
/// bottom it runs to the edge and the page keeps clear of the home indicator itself.
final class HarborRootViewController: UIViewController {
    private let bridgeController = HarborBridgeViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(bridgeController)
        view.addSubview(bridgeController.view)
        bridgeController.didMove(toParent: self)
        bridgeController.view.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        bridgeController.view.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, view.bounds.height - top))
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}
