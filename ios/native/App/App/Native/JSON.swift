import Foundation
import UIKit

/// A JSON object as JSONSerialization gives it.
typealias JObj = [String: Any]

/// The same reading rules as the Android models (org.json's optString / optBoolean / …), so a
/// model the page sends reads the same on both.
extension Dictionary where Key == String, Value == Any {
    /// A non-empty string; numbers and booleans as their text (like optString); null / missing = nil.
    func str(_ k: String) -> String? {
        guard let v = self[k], !(v is NSNull) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }
        return nil
    }

    func bool(_ k: String, _ fallback: Bool = false) -> Bool {
        guard let v = self[k], !(v is NSNull) else { return fallback }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s.lowercased() == "true" ? true : s.lowercased() == "false" ? false : fallback }
        return fallback
    }

    func int(_ k: String, _ fallback: Int = 0) -> Int {
        guard let v = self[k], !(v is NSNull) else { return fallback }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let d = Double(s) { return Int(d) }
        return fallback
    }

    func long(_ k: String, _ fallback: Int64 = 0) -> Int64 {
        guard let v = self[k], !(v is NSNull) else { return fallback }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let d = Double(s) { return Int64(d) }
        return fallback
    }

    func double(_ k: String, _ fallback: Double = 0) -> Double {
        guard let v = self[k], !(v is NSNull) else { return fallback }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        return fallback
    }

    func obj(_ k: String) -> JObj? { self[k] as? JObj }

    /// The objects of an array (anything else in it skipped).
    func objs(_ k: String) -> [JObj] { (self[k] as? [Any])?.compactMap { $0 as? JObj } ?? [] }

    /// The non-empty strings of an array.
    func strs(_ k: String) -> [String] {
        ((self[k] as? [Any]) ?? []).compactMap { v -> String? in
            if let s = v as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
    }

    /// An object of strings (a model's labels).
    func labels(_ k: String) -> [String: String] {
        guard let l = obj(k) else { return [:] }
        var out: [String: String] = [:]
        for key in l.keys { if let s = l.str(key) { out[key] = s } }
        return out
    }

    /// A colour "#rrggbb" / "#aarrggbb".
    func color(_ k: String) -> UIColor? { UIColor(hex: str(k)) }
}

/// A model's JSON text as an object (nil when it isn't one).
func parseObject(_ json: String) -> JObj? {
    guard let data = json.data(using: .utf8) else { return nil }
    do {
        return try JSONSerialization.jsonObject(with: data) as? JObj
    } catch {
        // Text cut in the middle of an emoji leaves half of it, which the page's JSON.stringify
        // writes as an escape ("\ud83c"): Android's parser takes it, iOS's refuses the whole
        // model. Such halves become "�" and the rest stays.
        let fixed = fixLoneSurrogates(json)
        if fixed != json, let d = fixed.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? JObj {
            return o
        }
        let ns = error as NSError
        NSLog("[harbor json] %@ (%ld chars)", (ns.userInfo["NSDebugDescription"] as? String) ?? ns.localizedDescription, json.count)
        return nil
    }
}

private let loneHigh = try? NSRegularExpression(pattern: #"\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})"#)
private let loneLow = try? NSRegularExpression(pattern: #"(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}"#)

/// JSON text with each escaped half of a surrogate pair that has no other half made "�".
func fixLoneSurrogates(_ json: String) -> String {
    guard json.contains("\\u"), let loneHigh, let loneLow else { return json }
    var s = json
    for re in [loneHigh, loneLow] {
        s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\\\\ufffd")
    }
    return s
}

/// An object as JSON text (for actions sent back to the page).
func jsonText(_ o: JObj) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: o) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
}

extension UIColor {
    /// "#rrggbb" or "#aarrggbb" (as the page sends them, like Android's ARGB); anything else = nil.
    convenience init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let a, r, g, b: CGFloat
        if h.count == 6 {
            a = 1
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
        } else {
            a = CGFloat((v >> 24) & 0xFF) / 255
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// 0xAARRGGBB (the Android colour literals).
    convenience init(argb: UInt32) {
        self.init(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }

    /// The same colour at [alpha] (Android's withAlpha).
    func alpha(_ a: CGFloat) -> UIColor { withAlphaComponent(a) }
}
