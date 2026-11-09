import Capacitor
import UIKit

/// Capacitor's web view controller, with Harbor's own plugins registered.
final class HarborBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(HarborPlayerPlugin())
    }
}

/// The page's way to the native player, the same as the Android shell's: play(json), command(json),
/// stop(). The player answers through window.__harborNativeEvent(json), like on Android, so the
/// page's player code (src/lib/player/android/bridge.ts) works unchanged.
@objc(HarborPlayerPlugin)
public class HarborPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HarborPlayerPlugin"
    public let jsName = "HarborPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "command", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
    ]

    private weak var playerController: HarborPlayerViewController?

    @objc func play(_ call: CAPPluginCall) {
        guard let source = PlayerSource(json: call.getString("json") ?? "") else {
            call.reject("bad source")
            return
        }
        DispatchQueue.main.async {
            // Already on screen (next episode, another source): the same player loads it.
            if let current = self.playerController, current.presentingViewController != nil {
                current.load(source)
            } else {
                let controller = HarborPlayerViewController(source: source) { [weak self] json in
                    self?.send(json)
                }
                self.playerController = controller
                self.bridge?.viewController?.present(controller, animated: true)
            }
            call.resolve()
        }
    }

    @objc func command(_ call: CAPPluginCall) {
        let json = call.getString("json") ?? ""
        DispatchQueue.main.async {
            if let data = json.data(using: .utf8),
               let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                self.playerController?.handle(cmd)
            }
            call.resolve()
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            // The page left the player: close without reporting back (it already knows).
            self.playerController?.closeQuietly()
            self.playerController = nil
            call.resolve()
        }
    }

    /// An event for the page, as a JSON string (see NativePlayerEvent in src/lib/android.ts).
    private func send(_ json: String) {
        guard let literal = try? JSONSerialization.data(withJSONObject: [json]),
              let array = String(data: literal, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.bridge?.webView?.evaluateJavaScript(
                "window.__harborNativeEvent && window.__harborNativeEvent(\(array)[0])",
                completionHandler: nil
            )
        }
    }
}

/// What the page asks to play (the Android shell's play() JSON).
struct PlayerSource {
    struct Subtitle {
        let url: String
        let lang: String?
        let label: String?
    }

    let url: URL
    let headers: [String: String]
    let startMs: Int
    var subtitles: [Subtitle]
    let prefSubLangs: [String]
    let prefAudioLangs: [String]
    let title: String
    let isLive: Bool
    let uiLang: String

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = o["url"] as? String,
              let url = URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        else { return nil }
        self.url = url
        headers = (o["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        startMs = (o["startMs"] as? NSNumber)?.intValue ?? 0
        subtitles = PlayerSource.subs(o["subtitles"])
        prefSubLangs = (o["prefSubLangs"] as? [String]) ?? []
        prefAudioLangs = (o["prefAudioLangs"] as? [String]) ?? []
        title = (o["title"] as? String) ?? ""
        isLive = (o["isLive"] as? Bool) ?? false
        uiLang = (o["uiLang"] as? String) ?? Locale.preferredLanguages.first ?? "en"
    }

    static func subs(_ value: Any?) -> [Subtitle] {
        ((value as? [[String: Any]]) ?? []).compactMap { s in
            guard let url = s["url"] as? String, !url.isEmpty else { return nil }
            return Subtitle(url: url, lang: s["lang"] as? String, label: s["label"] as? String)
        }
    }
}
