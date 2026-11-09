import Capacitor
import UIKit

/**
 * The native screens (Home, Discover, Movies, Shows, Library, a title's page…): one NativeScreen
 * per page, each keeping its own scroll position, and at most one on show, the page the app shows
 * on top. Contract (src/views/native/native-screens.ts), the same as Android's NativeScreens.kt:
 *   page -> HarborNative.homeSet({json})                    a page's model ("page" says which)
 *   page -> HarborNative.screenShow({page, bottom, width})  which page is on screen ("" = none)
 *   screen -> window.__harborNativeHome(json)               taps: {p: page, a: …}
 */
final class NativeScreens {
    static let shared = NativeScreens()

    /// Over the page (under the player). Takes no touches where no screen is shown.
    let root = PassthroughView()
    /// A tap for the page (JSON text).
    var onAction: ((String) -> Void)?

    private var screens: [String: NativeScreen] = [:]
    private var current: String?
    /// Room left at the bottom for the page's tab bar.
    private var bottom: CGFloat = 0

    private init() {
        root.backgroundColor = .clear
    }

    /// Puts the layer in [parent] (over the page's view). Its frame follows the page's (layout()).
    func install(in parent: UIView) {
        guard root.superview !== parent else { return }
        parent.addSubview(root)
    }

    func layout(frame: CGRect) {
        guard root.frame != frame else { return }
        root.frame = frame
        for s in screens.values { s.frame = screenFrame }
    }

    var isShowing: Bool { current.flatMap { screens[$0] }?.isShowing == true }

    private var screenFrame: CGRect {
        CGRect(x: 0, y: 0, width: root.bounds.width, height: max(0, root.bounds.height - bottom))
    }

    private func screen(_ page: String) -> NativeScreen {
        if let s = screens[page] { return s }
        let s = NativeScreen(page: page) { [weak self] action in self?.onAction?(jsonText(action)) }
        s.frame = screenFrame
        s.autoresizingMask = []
        // Fully in: the screens it replaced (waiting under it) go.
        s.onRevealed = { [weak self] in
            guard let self else { return }
            for (p, other) in self.screens where p != self.current { other.dropLinger() }
        }
        screens[page] = s
        root.addSubview(s)
        return s
    }

    func setModel(_ json: String) {
        guard let model = HomeModel.parse(json) else {
            NSLog("[harbor screens] model rejected")
            return
        }
        screen(model.page).setModel(model, json: json)
    }

    /// [page] on screen ("" = none), leaving [bottomCss] (the page's tab bar, CSS pixels on a
    /// [cssWidth] wide page) at the bottom.
    func show(_ page: String, bottomCss: Double, cssWidth: Double) {
        let scale = cssWidth > 0 && root.bounds.width > 0 ? root.bounds.width / CGFloat(cssWidth) : 1
        bottom = max(0, CGFloat(bottomCss) * scale)
        let want = page.isEmpty ? nil : page
        // The new one first (it comes in on top), then the others leave: while it fades in, the one
        // it replaces stays under it instead of the page's dark background flashing between.
        if let want {
            let s = screen(want)
            s.frame = screenFrame
            root.bringSubviewToFront(s)
            s.show(true)
        }
        for (p, s) in screens where p != want {
            s.frame = screenFrame
            s.show(false, linger: want != nil)
        }
        current = want
    }
}

/// The page's way to the native screens: homeSet(json), screenShow(page, bottom, width). Taps go
/// back through window.__harborNativeHome(json), like on Android.
@objc(HarborNativePlugin)
public class HarborNativePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HarborNativePlugin"
    public let jsName = "HarborNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "homeSet", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "screenShow", returnType: CAPPluginReturnPromise),
    ]

    override public func load() {
        NativeScreens.shared.onAction = { [weak self] json in self?.send("__harborNativeHome", json) }
    }

    @objc func homeSet(_ call: CAPPluginCall) {
        let json = call.getString("json") ?? ""
        DispatchQueue.main.async {
            NativeScreens.shared.setModel(json)
            call.resolve()
        }
    }

    @objc func screenShow(_ call: CAPPluginCall) {
        let page = call.getString("page") ?? ""
        let bottom = call.getDouble("bottom") ?? 0
        let width = call.getDouble("width") ?? 0
        DispatchQueue.main.async {
            NativeScreens.shared.show(page, bottomCss: bottom, cssWidth: width)
            call.resolve()
        }
    }

    /// Calls window.[fn](json) in the page.
    func send(_ fn: String, _ json: String) {
        guard let literal = try? JSONSerialization.data(withJSONObject: [json]),
              let array = String(data: literal, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.bridge?.webView?.evaluateJavaScript("window.\(fn) && window.\(fn)(\(array)[0])", completionHandler: nil)
        }
    }
}
