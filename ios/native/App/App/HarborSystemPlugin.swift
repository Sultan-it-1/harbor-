import Capacitor
import UIKit

/**
 * The page's way to the phone's own services (Android: MainActivity.JsApi's dl*, takeLink,
 * imageCache, saveFile, openExternal, setSecure): downloads, stremio:// links, saved pictures,
 * saving a file, opening a link outside the app.
 *
 * The page calls Android's synchronously, iOS plugins answer later: so the app keeps the page's
 * copy of its state up to date (window.__harborIosState(json)) and the page answers its own calls
 * from that copy (src/lib/ios-system.ts). Contract:
 *   page -> HarborSystem.state()                       -> {json}: the state now
 *   app  -> window.__harborIosState(json)              {downloads, files, storage, wifiOnly,
 *                                                       imageCache, link}
 *   page -> HarborSystem.dlStart({json}) … dlDelete({id}) …   (as Android's, no answer needed)
 *   app  -> window.__harborDeepLinkCheck()             a stremio:// link came in
 *   app  -> window.__harborFileSaved(id, "1"|"0")      saveFile's answer
 */
@objc(HarborSystemPlugin)
public class HarborSystemPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HarborSystemPlugin"
    public let jsName = "HarborSystem"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "state", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlStart", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlDelete", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlPause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlResume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlRelink", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlAddSubs", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlSetWifiOnly", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dlKeepAlive", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "linkTaken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "imageCacheClear", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openExternal", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSecure", returnType: CAPPluginReturnPromise),
    ]

    /// The one the page talks to (pushes go through it).
    static weak var current: HarborSystemPlugin?
    /// A stremio:// link that opened (or was sent to) the app, until the page takes it.
    static var pendingLink: String?
    /// A screen showing secrets is up (PIN, sign-in): the app switcher's preview is covered.
    static var secure = false

    private var pushQueued = false
    private var ticker: Timer?

    override public func load() {
        HarborSystemPlugin.current = self
        Downloads.shared.onChange = { [weak self] in self?.push() }
        // Downloads go out as the app's web view does (some servers check).
        DispatchQueue.main.async { [weak self] in
            self?.bridge?.webView?.evaluateJavaScript("navigator.userAgent") { r, _ in
                if let ua = r as? String, !ua.isEmpty { Downloads.shared.userAgent = ua }
            }
        }
        // While something downloads, the page hears how far it got every second.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if Downloads.shared.hasPendingWork { self?.push() }
        }
    }

    // MARK: - State

    private func snapshot() -> String {
        var o: JObj = [
            "downloads": Downloads.shared.statusObject(),
            "files": Downloads.shared.allFiles(),
            "storage": Downloads.shared.storage(),
            "wifiOnly": Downloads.shared.wifiOnly,
            "imageCache": ImageLoader.shared.cacheInfo(),
        ]
        if let link = HarborSystemPlugin.pendingLink { o["link"] = link }
        return jsonText(o)
    }

    /// The page's copy of the state, refreshed (at most a few times a second).
    func push() {
        guard !pushQueued else { return }
        pushQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.pushQueued = false
            self.send("__harborIosState", self.snapshot())
        }
    }

    /// Calls window.[fn](arg) in the page.
    private func send(_ fn: String, _ arg: String? = nil, _ arg2: String? = nil) {
        let args = [arg, arg2].compactMap { $0 }
        guard let literal = try? JSONSerialization.data(withJSONObject: args),
              let array = String(data: literal, encoding: .utf8) else { return }
        let call = args.isEmpty ? "window.\(fn)()" : "window.\(fn).apply(null, \(array))"
        DispatchQueue.main.async {
            self.bridge?.webView?.evaluateJavaScript("window.\(fn) && \(call)", completionHandler: nil)
        }
    }

    @objc func state(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["json": self.snapshot()]) }
    }

    // MARK: - Downloads (Android's dl* calls)

    @objc func dlStart(_ call: CAPPluginCall) {
        let json = call.getString("json") ?? ""
        DispatchQueue.main.async {
            call.resolve(["json": Downloads.shared.startDownload(json)])
            self.push()
        }
    }

    @objc func dlDelete(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        DispatchQueue.main.async {
            call.resolve(["ok": Downloads.shared.delete(id)])
        }
    }

    @objc func dlPause(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        DispatchQueue.main.async { call.resolve(["ok": Downloads.shared.pause(id)]) }
    }

    @objc func dlResume(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        DispatchQueue.main.async { call.resolve(["ok": Downloads.shared.resume(id)]) }
    }

    @objc func dlRelink(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        let url = call.getString("url") ?? ""
        let headers = call.getString("headers")
        DispatchQueue.main.async { call.resolve(["ok": Downloads.shared.relink(id, url: url, headersJson: headers)]) }
    }

    @objc func dlAddSubs(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        let json = call.getString("json") ?? "[]"
        DispatchQueue.main.async { call.resolve(["ok": Downloads.shared.addSubtitles(id, json: json)]) }
    }

    @objc func dlSetWifiOnly(_ call: CAPPluginCall) {
        let on = call.getBool("on") ?? true
        DispatchQueue.main.async {
            Downloads.shared.wifiOnly = on
            call.resolve()
        }
    }

    @objc func dlKeepAlive(_ call: CAPPluginCall) {
        let on = call.getBool("on") ?? false
        DispatchQueue.main.async {
            Downloads.shared.setKeepAlive(on)
            call.resolve()
        }
    }

    // MARK: - Links, pictures, files

    /// A stremio:// link came in: kept until the page takes it.
    static func receiveLink(_ url: String) {
        pendingLink = url
        guard let p = current else { return }
        p.push()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { p.send("__harborDeepLinkCheck") }
    }

    @objc func linkTaken(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            HarborSystemPlugin.pendingLink = nil
            call.resolve()
        }
    }

    @objc func imageCacheClear(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async {
            ImageLoader.shared.clearAll()
            DispatchQueue.main.async {
                call.resolve(["json": jsonText(ImageLoader.shared.cacheInfo())])
                self.push()
            }
        }
    }

    @objc func openExternal(_ call: CAPPluginCall) {
        guard let s = call.getString("url"), let url = URL(string: s) else {
            call.resolve(["ok": false])
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
            call.resolve(["ok": true])
        }
    }

    /// The phone's share sheet for a file the page made (Save to Files, AirDrop…).
    @objc func saveFile(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        let name = (call.getString("name") ?? "file").replacingOccurrences(of: "/", with: "_")
        guard let data = Data(base64Encoded: call.getString("base64") ?? "", options: .ignoreUnknownCharacters) else {
            send("__harborFileSaved", id, "0")
            call.resolve(["ok": false])
            return
        }
        DispatchQueue.main.async {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name.isEmpty ? "file" : name)
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                self.send("__harborFileSaved", id, "0")
                call.resolve(["ok": false])
                return
            }
            guard let top = self.bridge?.viewController.map({ vc -> UIViewController in
                var c = vc
                while let p = c.presentedViewController { c = p }
                return c
            }) else {
                self.send("__harborFileSaved", id, "0")
                call.resolve(["ok": false])
                return
            }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.completionWithItemsHandler = { [weak self] _, done, _, _ in
                self?.send("__harborFileSaved", id, done ? "1" : "0")
            }
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            top.present(sheet, animated: true)
            call.resolve(["ok": true])
        }
    }

    @objc func setSecure(_ call: CAPPluginCall) {
        let on = call.getBool("on") ?? false
        DispatchQueue.main.async {
            HarborSystemPlugin.secure = on
            call.resolve()
        }
    }
}
