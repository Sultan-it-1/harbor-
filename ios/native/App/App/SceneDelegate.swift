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
            HarborPlayerViewController.verbose = true
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
/// A swipe in from the screen's edge (the right edge in Arabic) is the app's Back, like Android's.
final class HarborRootViewController: UIViewController, UIGestureRecognizerDelegate {
    private let bridgeController = HarborBridgeViewController()
    /// The round arrow that follows a Back swipe.
    private let backHint = UIView()
    private let backHintIcon = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(bridgeController)
        view.addSubview(bridgeController.view)
        bridgeController.didMove(toParent: self)
        bridgeController.view.backgroundColor = .black
        // The native screens (Home, Discover…) over the page, under the player.
        NativeScreens.shared.install(in: view)

        for edge in [UIRectEdge.left, UIRectEdge.right] {
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePan(_:)))
            g.edges = edge
            g.delegate = self
            view.addGestureRecognizer(g)
        }
        backHint.frame = CGRect(x: -48, y: 0, width: 44, height: 44)
        backHint.layer.cornerRadius = 22
        backHint.backgroundColor = UIColor(white: 0.12, alpha: 0.85)
        backHint.layer.borderWidth = 1
        backHint.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        backHint.isUserInteractionEnabled = false
        backHint.alpha = 0
        backHintIcon.image = Icons.image("arrow_left", size: 20)
        backHintIcon.tintColor = .white
        backHintIcon.contentMode = .center
        backHintIcon.frame = backHint.bounds
        backHint.addSubview(backHintIcon)
        view.addSubview(backHint)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        bridgeController.view.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, view.bounds.height - top))
        NativeScreens.shared.layout(frame: bridgeController.view.frame)
        view.bringSubviewToFront(backHint)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Back from the edge

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let e = g as? UIScreenEdgePanGestureRecognizer else { return true }
        // The player has its own controls; only the reading side's edge is Back.
        guard presentedViewController == nil else { return false }
        return e.edges == (NativeScreens.shared.rtl ? .right : .left)
    }

    /// A swipe that starts at the edge is Back, not the sideways rows under it.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g is UIScreenEdgePanGestureRecognizer && other is UIPanGestureRecognizer && !(other is UIScreenEdgePanGestureRecognizer)
    }

    @objc private func edgePan(_ g: UIScreenEdgePanGestureRecognizer) {
        let fromRight = g.edges == .right
        let sign: CGFloat = fromRight ? -1 : 1
        let dx = max(0, g.translation(in: view).x * sign)
        let pull = min(dx, 110) / 110
        let w = view.bounds.width
        let y = min(max(g.location(in: view).y, 80), view.bounds.height - 80)
        let x = -44 + pull * 64
        backHint.center = CGPoint(x: fromRight ? w - x - 22 : x + 22, y: y)
        backHintIcon.transform = fromRight ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        switch g.state {
        case .began, .changed:
            backHint.alpha = pull
            backHint.transform = CGAffineTransform(scaleX: 0.8 + 0.2 * pull, y: 0.8 + 0.2 * pull)
        case .ended:
            let vx = g.velocity(in: view).x * sign
            if dx > 80 || vx > 700 { goBack() }
            hideHint()
        default:
            hideHint()
        }
    }

    private func hideHint() {
        UIView.animate(withDuration: 0.18) {
            self.backHint.alpha = 0
            self.backHint.transform = .identity
        }
    }

    /// The page's own Back: closes a pop-up first, then the page it's on.
    private func goBack() {
        bridgeController.bridge?.webView?.evaluateJavaScript(
            "(function(){try{return !!(window.__harborAndroidBack&&window.__harborAndroidBack())}catch(e){return false}})()",
            completionHandler: nil
        )
    }
}
