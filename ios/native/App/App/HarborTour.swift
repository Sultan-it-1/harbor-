#if DEBUG
import UIKit
import WebKit

/**
 * Test builds: `-HarborTour en|ar` walks through the app's screens on its own (the iOS build's
 * simulator check, where nobody can tap). Onboarding is skipped and the language set before the
 * page starts; then each screen is opened the way a tap would open it. When a screen has had time
 * to fill, its name goes into Documents/tour/step.txt and the build takes a screenshot; "done" at
 * the end.
 */
enum HarborTour {
    /// The tour's language, or nil when the app wasn't started for one.
    static var lang: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-HarborTour") else { return nil }
        return i + 1 < args.count && args[i + 1] == "ar" ? "ar" : "en"
    }

    private struct Step {
        let name: String
        /// Run in the page (empty: nothing to do, the screen is already up).
        let js: String
        /// A stremio:// link handed to the page instead (a title page).
        var link: String?
        /// Seconds the screen gets to fill before its screenshot.
        let settle: Double
    }

    private static let tabs = "document.querySelectorAll('[data-phone-tabbar] button')"

    private static func tab(_ i: Int) -> String { "(function(){var b=\(tabs)[\(i)];if(b)b.click();})()" }

    /// Opens a page from the tab bar's More sheet.
    private static func more(_ view: String) -> String {
        """
        (function(){var b=\(tabs)[4];if(b)b.click();setTimeout(function(){
        var x=document.querySelector('[data-more-view="\(view)"]');if(x)x.click();else{var m=\(tabs)[4];if(m)m.click();}},500);})()
        """
    }

    private static let steps: [Step] = [
        Step(name: "home", js: "", settle: 12),
        Step(name: "discover", js: tab(1), settle: 10),
        Step(name: "library", js: tab(3), settle: 6),
        Step(name: "movies", js: more("movies"), settle: 9),
        Step(name: "shows", js: more("shows"), settle: 9),
        Step(name: "anime", js: more("anime"), settle: 9),
        Step(name: "calendar", js: more("calendar"), settle: 8),
        Step(name: "live", js: more("live"), settle: 8),
        Step(name: "downloads", js: more("downloads"), settle: 6),
        Step(name: "addons", js: more("addons"), settle: 14),
        Step(name: "title-movie", js: "", link: "stremio:///detail/movie/tt0111161", settle: 12),
        Step(name: "title-series", js: "", link: "stremio:///detail/series/tt0903747", settle: 12),
        Step(name: "search", js: tab(2), settle: 5),
    ]

    private static var marker: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("tour", isDirectory: true).appendingPathComponent("step.txt")
    }

    private static func mark(_ name: String) {
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? name.write(to: marker, atomically: true, encoding: .utf8)
        print("[harbor tour] \(name)")
    }

    /// Called as the bridge is made, before the page loads.
    static func start(_ web: WKWebView, lang: String) {
        try? FileManager.default.removeItem(at: marker)
        let prepare = """
        try {
          localStorage.setItem('harbor.onboarding', JSON.stringify({onboarded: true, nudges: {}}));
          var s = {}; try { s = JSON.parse(localStorage.getItem('harbor.settings') || '{}') || {}; } catch (e) {}
          s.uiLanguage = '\(lang)';
          localStorage.setItem('harbor.settings', JSON.stringify(s));
        } catch (e) {}
        """
        web.configuration.userContentController.addUserScript(
            WKUserScript(source: prepare, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        waitForPage(web, tries: 0)
    }

    /// Until the page's tab bar is up (at most a minute).
    private static func waitForPage(_ web: WKWebView, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak web] in
            guard let web else { return }
            web.evaluateJavaScript("!!document.querySelector('[data-phone-tabbar]')") { r, _ in
                if (r as? Bool) == true || tries >= 60 {
                    run(web, 0)
                } else {
                    waitForPage(web, tries: tries + 1)
                }
            }
        }
    }

    private static func run(_ web: WKWebView, _ i: Int) {
        guard i < steps.count else {
            mark("done")
            return
        }
        let step = steps[i]
        if let link = step.link {
            HarborSystemPlugin.receiveLink(link)
        } else if !step.js.isEmpty {
            web.evaluateJavaScript(step.js, completionHandler: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step.settle) { [weak web] in
            mark(String(format: "%02d-%@", i + 1, step.name))
            // Time for the screenshot before the next screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let web else { return }
                run(web, i + 1)
            }
        }
    }
}
#endif
