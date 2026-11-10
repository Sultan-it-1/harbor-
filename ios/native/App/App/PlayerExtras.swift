import UIKit

/**
 * The subtitle look, saved on the phone (Android: SubStyle). The first time, it comes from Harbor's
 * subtitle settings (the play request's "subStyle"). VLC takes it as its text options when the
 * player is made (a change restarts the player at the same point); the delay changes at once.
 */
struct SubStyle: Codable, Equatable {
    var scale: Double = 1
    /// shadow | outline | box | none
    var background = "shadow"
    var color = "#FFFFFF"
    /// How high the text sits (share of the picture's height from the bottom).
    var bottom: Double = 0.08
    var bold = false
    var boxOpacity: Double = 0.6

    private static let key = "harbor.ios.subStyle"
    /// Before the full look: the size alone (VLC's relative size).
    private static let oldSizeKey = "harbor.ios.subSize"

    static func load() -> SubStyle? {
        if let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(SubStyle.self, from: data) { return s }
        if let old = UserDefaults.standard.object(forKey: oldSizeKey) as? Int, old > 0 {
            var s = SubStyle()
            s.scale = Swift.min(Swift.max(16 / Double(old), 0.5), 2.5)
            return s
        }
        return nil
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Harbor's settings: fontSize (32 = 100%), color, style, bold, marginY, boxOpacity.
    static func fromHarbor(_ o: [String: Any]?) -> SubStyle {
        var s = SubStyle()
        guard let o else { return s }
        if let size = (o["fontSize"] as? NSNumber)?.doubleValue, size > 0 { s.scale = Swift.min(Swift.max(size / 32, 0.5), 2.5) }
        if let c = o["color"] as? String, c.hasPrefix("#"), UIColor(hex: c) != nil { s.color = c }
        switch o["style"] as? String {
        case "outline": s.background = "outline"
        case "box": s.background = "box"
        default: s.background = "shadow"
        }
        s.bold = (o["bold"] as? Bool) ?? false
        let margin = (o["marginY"] as? NSNumber)?.doubleValue ?? 12
        s.bottom = Swift.min(Swift.max(0.04 + margin / 400, 0.02), 0.4)
        s.boxOpacity = Swift.min(Swift.max((o["boxOpacity"] as? NSNumber)?.doubleValue ?? 0.6, 0.1), 1)
        return s
    }

    private var rgb: Int {
        let hex = color.dropFirst()
        return Int(hex.prefix(6), radix: 16) ?? 0xFFFFFF
    }

    /// VLC's text options for this look.
    var vlcOptions: [String] {
        // VLC's relative size: a smaller number is bigger text (16 is its normal).
        let rel = Swift.max(6, Swift.min(30, Int((16 / scale).rounded())))
        var o = ["--freetype-rel-fontsize=\(rel)", "--freetype-color=\(rgb)"]
        switch background {
        case "outline":
            o += ["--freetype-outline-thickness=4", "--freetype-shadow-opacity=0", "--freetype-background-opacity=0"]
        case "box":
            o += ["--freetype-outline-thickness=0", "--freetype-shadow-opacity=0", "--freetype-background-color=0",
                  "--freetype-background-opacity=\(Int(boxOpacity * 255))"]
        case "none":
            o += ["--freetype-outline-thickness=0", "--freetype-shadow-opacity=0", "--freetype-background-opacity=0"]
        default:
            o += ["--freetype-outline-thickness=2", "--freetype-shadow-opacity=200", "--freetype-shadow-distance=0.06",
                  "--freetype-background-opacity=0"]
        }
        if bold { o.append("--freetype-bold") }
        // Higher than VLC's own spot: that many pixels up.
        let margin = Int(Swift.max(0, bottom - 0.08) * 600)
        if margin > 0 { o.append("--sub-margin=\(margin)") }
        return o
    }
}

/// The player's added words (the sources list, the subtitle look, gestures, saved subtitles).
extension PlayerText {
    var sources: String { ar ? "المصادر" : "Sources" }
    var loadingSources: String { ar ? "جارٍ جلب المصادر…" : "Getting sources…" }
    var noSources: String { ar ? "ما فيه مصادر ثانية لهذا العنوان." : "No other sources for this title." }
    var allQualities: String { ar ? "الكل" : "All" }
    var switching: String { ar ? "جارٍ التبديل للمصدر…" : "Switching source…" }
    var subStyle: String { ar ? "مظهر الترجمة" : "Subtitle look" }
    var colour: String { ar ? "اللون" : "Colour" }
    var colourNames: [(String, String)] {
        ar ? [("#FFFFFF", "أبيض"), ("#FDE047", "أصفر"), ("#67E8F9", "سماوي"), ("#86EFAC", "أخضر")]
            : [("#FFFFFF", "White"), ("#FDE047", "Yellow"), ("#67E8F9", "Cyan"), ("#86EFAC", "Green")]
    }
    var backgroundTitle: String { ar ? "الخلفية" : "Background" }
    var backgroundNames: [(String, String)] {
        ar ? [("shadow", "ظل"), ("outline", "إطار"), ("box", "صندوق"), ("none", "بدون")]
            : [("shadow", "Shadow"), ("outline", "Outline"), ("box", "Box"), ("none", "None")]
    }
    var bold: String { ar ? "خط عريض" : "Bold" }
    var position: String { ar ? "الموضع" : "Position" }
    var positionNames: [(Double, String)] {
        ar ? [(0.08, "أسفل"), (0.16, "أعلى قليلاً"), (0.26, "أعلى")] : [(0.08, "Bottom"), (0.16, "A little higher"), (0.26, "Higher")]
    }
    var delay: String { ar ? "تأخير الترجمة" : "Subtitle delay" }
    var resetDelay: String { ar ? "بدون تأخير" : "No delay" }
    func seconds(_ ms: Int) -> String {
        let s = String(format: "%+.1f", Double(ms) / 1000)
        return ar ? "\(s) ث" : "\(s) s"
    }
    var savedOnDevice: String { ar ? "محفوظة على الجهاز" : "Saved on the device" }
    var saveWithDownload: String { ar ? "حفظ ترجمة مع التنزيل" : "Save a subtitle with the download" }
    var subSaved: String { ar ? "انحفظت الترجمة مع الفيديو" : "Subtitle saved with the video" }
    var subSaveFailed: String { ar ? "تعذّر حفظ الترجمة" : "Couldn't save the subtitle" }
    var brightness: String { ar ? "السطوع" : "Brightness" }
    var volume: String { ar ? "الصوت" : "Volume" }
}
