import UIKit

/// The app's icons (the Android app's Lucide icons, IconPaths), drawn from their path data: any
/// size, tinted like any template image.
enum Icons {
    private static let cache = NSCache<NSString, UIImage>()

    /// The icon [name] (Android's drawable name without "ic_": "play", "arrow_left", "users"…) as
    /// a template image [size] points square. [filled]: the shape filled too (a solid zap, star).
    static func image(_ name: String, size: CGFloat = 22, filled: Bool = false, weight: CGFloat = 2) -> UIImage? {
        let key = "\(name)|\(size)|\(filled)|\(weight)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = IconPaths.all[name] else { return nil }
        let path = CGMutablePath()
        for d in data { SVGPath.add(d, to: path) }
        let scale = size / 24
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            c.scaleBy(x: scale, y: scale)
            c.setStrokeColor(UIColor.black.cgColor)
            c.setFillColor(UIColor.black.cgColor)
            c.setLineWidth(weight)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            if filled {
                c.addPath(path)
                c.fillPath()
            }
            c.addPath(path)
            c.strokePath()
        }.withRenderingMode(.alwaysTemplate)
        cache.setObject(image, forKey: key)
        return image
    }

    /// An image view showing the icon in [tint].
    static func view(_ name: String, size: CGFloat = 22, tint: UIColor = .white, filled: Bool = false) -> UIImageView {
        let v = UIImageView(image: image(name, size: size, filled: filled))
        v.tintColor = tint
        v.contentMode = .center
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: size),
            v.heightAnchor.constraint(equalToConstant: size),
        ])
        return v
    }
}

/// SVG path data (M L H V C S Q T A Z, absolute and relative) into a CGPath.
enum SVGPath {
    static func add(_ d: String, to path: CGMutablePath) {
        var sc = Scanner(Array(d))
        var cmd: Character = "M"
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        while true {
            if let c = sc.command() {
                cmd = c
            } else if sc.atEnd {
                break
            }
            let rel = cmd.isLowercase
            let ox = rel ? cur.x : 0
            let oy = rel ? cur.y : 0
            var cubic: CGPoint?
            var quad: CGPoint?
            switch Character(cmd.uppercased()) {
            case "M":
                guard let x = sc.number(), let y = sc.number() else { return }
                cur = CGPoint(x: ox + x, y: oy + y)
                path.move(to: cur)
                start = cur
                cmd = rel ? "l" : "L" // pairs after a moveto are lines
            case "L":
                guard let x = sc.number(), let y = sc.number() else { return }
                cur = CGPoint(x: ox + x, y: oy + y)
                path.addLine(to: cur)
            case "H":
                guard let x = sc.number() else { return }
                cur = CGPoint(x: ox + x, y: cur.y)
                path.addLine(to: cur)
            case "V":
                guard let y = sc.number() else { return }
                cur = CGPoint(x: cur.x, y: oy + y)
                path.addLine(to: cur)
            case "C":
                guard let x1 = sc.number(), let y1 = sc.number(), let x2 = sc.number(), let y2 = sc.number(),
                      let x = sc.number(), let y = sc.number() else { return }
                let c2 = CGPoint(x: ox + x2, y: oy + y2)
                cur = CGPoint(x: ox + x, y: oy + y)
                path.addCurve(to: cur, control1: CGPoint(x: ox + x1, y: oy + y1), control2: c2)
                cubic = c2
            case "S":
                guard let x2 = sc.number(), let y2 = sc.number(), let x = sc.number(), let y = sc.number() else { return }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: ox + x2, y: oy + y2)
                cur = CGPoint(x: ox + x, y: oy + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                cubic = c2
            case "Q":
                guard let x1 = sc.number(), let y1 = sc.number(), let x = sc.number(), let y = sc.number() else { return }
                let c = CGPoint(x: ox + x1, y: oy + y1)
                cur = CGPoint(x: ox + x, y: oy + y)
                path.addQuadCurve(to: cur, control: c)
                quad = c
            case "T":
                guard let x = sc.number(), let y = sc.number() else { return }
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                cur = CGPoint(x: ox + x, y: oy + y)
                path.addQuadCurve(to: cur, control: c)
                quad = c
            case "A":
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(),
                      let large = sc.flag(), let sweep = sc.flag(),
                      let x = sc.number(), let y = sc.number() else { return }
                let end = CGPoint(x: ox + x, y: oy + y)
                arc(path, from: cur, to: end, rx: rx, ry: ry, angle: rot, large: large, sweep: sweep)
                cur = end
            case "Z":
                path.closeSubpath()
                cur = start
                lastCubic = nil
                lastQuad = nil
                // Z takes no numbers: what follows must be a command (or the end).
                if !sc.nextIsCommand { return }
                continue
            default:
                return
            }
            lastCubic = cubic
            lastQuad = quad
        }
    }

    /// An elliptical arc as cubic curves (the SVG spec's endpoint-to-centre conversion).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, angle: CGFloat, large: Bool, sweep: Bool) {
        if p0 == p { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: p)
            return
        }
        let phi = angle * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2
        let dy = (p0.y - p.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }
        let rx2 = rx * rx
        let ry2 = ry * ry
        let num = max(0, rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p)
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(num / den)
        if large == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p.y) / 2

        func angleBetween(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            if len == 0 { return 0 }
            var a = acos(Swift.max(-1, Swift.min(1, (ux * vx + uy * vy) / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angleBetween(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angleBetween((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }

        let segments = Swift.max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        func onEllipse(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
        }
        var th = theta1
        for _ in 0..<segments {
            let th2 = th + step
            let c1 = onEllipse(cos(th) - t * sin(th), sin(th) + t * cos(th))
            let c2 = onEllipse(cos(th2) + t * sin(th2), sin(th2) - t * cos(th2))
            path.addCurve(to: onEllipse(cos(th2), sin(th2)), control1: c1, control2: c2)
            th = th2
        }
    }

    /// Reads path data a character at a time (numbers may touch: "m19 12-7 7-7-7", ".5.5").
    private struct Scanner {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool {
            mutating get {
                skip()
                return i >= chars.count
            }
        }

        mutating func skip() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
                i += 1
            }
        }

        /// Whether a command letter comes next (without reading it).
        var nextIsCommand: Bool {
            mutating get {
                skip()
                guard i < chars.count else { return false }
                let c = chars[i]
                return c.isLetter && c != "e" && c != "E"
            }
        }

        /// The next command letter, if the next thing is one.
        mutating func command() -> Character? {
            skip()
            guard i < chars.count else { return nil }
            let c = chars[i]
            guard c.isLetter, c != "e", c != "E" else { return nil }
            i += 1
            return c
        }

        mutating func number() -> CGFloat? {
            skip()
            var j = i
            var text = ""
            if j < chars.count, chars[j] == "-" || chars[j] == "+" {
                text.append(chars[j])
                j += 1
            }
            var dot = false
            var digits = false
            while j < chars.count {
                let c = chars[j]
                if c.isASCII, c.isNumber {
                    text.append(c)
                    digits = true
                    j += 1
                } else if c == ".", !dot {
                    dot = true
                    text.append(c)
                    j += 1
                } else if c == "e" || c == "E", digits {
                    text.append(c)
                    j += 1
                    if j < chars.count, chars[j] == "-" || chars[j] == "+" {
                        text.append(chars[j])
                        j += 1
                    }
                } else {
                    break
                }
            }
            guard digits, let v = Double(text) else { return nil }
            i = j
            return CGFloat(v)
        }

        /// An arc's flag: one character, 0 or 1 (they may touch: "a1 1 0 011 1").
        mutating func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }
    }
}
