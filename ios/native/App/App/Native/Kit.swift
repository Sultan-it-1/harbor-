import UIKit

// Pieces the native screens share (Android: NativeHome's small helpers): padded labels, a flowing
// row, the rating badge, the coloured plates behind pictures, the page's button looks.

/// Colours the page's screens use besides the theme's.
enum Palette {
    static let danger = UIColor(argb: 0xFFE5484D)
    static let green = UIColor(argb: 0xFF6EE7B7)
    static let emerald = UIColor(argb: 0xFF34D399)
    static let mint = UIColor(argb: 0xFFA7F3D0)
    static let amber100 = UIColor(argb: 0xFFFEF3C7)
    static let amber200 = UIColor(argb: 0xFFFDE68A)
    static let amber300 = UIColor(argb: 0xFFFCD34D)
    static let imdb = UIColor(argb: 0xFFF5C518)
    static let star = UIColor(argb: 0xFFFBBF24)
}

/// Sizes that follow the screen (Android: NativeHome's width() helpers). Points.
struct Metrics {
    let width: CGFloat
    let height: CGFloat
    let gutter: CGFloat = 20
    let gap: CGFloat = 12

    /// About 3.3 posters across a phone, never bigger than 150.
    var poster: CGFloat { floor(min((width - gutter) / 3.3, 150)) }
    /// Top 10 posters: a little bigger than the others.
    var rank: CGFloat { floor(poster * 1.15) }
    var cw: CGFloat { floor(min((width - gutter) / 1.7, 300)) }
    var hero: CGFloat { floor(max(min(height * 0.76, 640), 320)) }
    /// Genre / language / award / collection tiles: about 2.3 across.
    var tile: CGFloat { floor(min((width - gutter) / 2.3, 220)) }
    var logo: CGFloat { floor(min((width - gutter) / 2.6, 172)) }
    /// One card the width of the screen (Critics' Pick).
    var feature: CGFloat { width - 2 * gutter }
    /// Live TV's landscape cards: most of the width, the next one peeking.
    var live: CGFloat { floor(min((width - 32) * 0.88, 360)) }

    /// How many of [row]'s cards fit across a grid line.
    func gridCols(_ row: HomeRow) -> Int {
        let tile = row.kind == .tile
        let minW: CGFloat = row.min > 0 ? CGFloat(row.min) : (tile ? 260 : 140)
        let gapX: CGFloat = 16
        let avail = width - 32
        return Swift.max(tile ? 1 : 2, Int((avail + gapX) / (minW + gapX)))
    }

    /// A grid card's width for [cols] across.
    func gridWidth(_ cols: Int) -> CGFloat {
        floor((width - 32 - CGFloat(cols - 1) * 16) / CGFloat(Swift.max(cols, 1)))
    }
}

/// A label with room around its text (pills, badges).
class PadLabel: UILabel {
    var insets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    convenience init(_ text: String? = nil, size: CGFloat, color: UIColor = .white, weight: UIFont.Weight = .regular, insets: UIEdgeInsets = .zero, lines: Int = 1) {
        self.init(frame: .zero)
        self.text = text
        font = Fonts.body(size, weight)
        textColor = color
        numberOfLines = lines
        lineBreakMode = .byTruncatingTail
        self.insets = insets
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines n: Int) -> CGRect {
        let r = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: n)
        return r.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}

extension UILabel {
    /// [text] with [spacing] em between letters and lines [lineHeight] times apart (Android's
    /// letterSpacing and setLineSpacing).
    func setStyled(_ text: String, spacing: CGFloat = 0, lineHeight: CGFloat = 0) {
        guard spacing != 0 || lineHeight > 0 else {
            attributedText = nil
            self.text = text
            return
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font as Any, .foregroundColor: textColor as Any]
        if spacing != 0 { attrs[.kern] = spacing * font.pointSize }
        if lineHeight > 0 {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = lineHeight
            p.lineBreakMode = lineBreakMode
            p.alignment = textAlignment
            attrs[.paragraphStyle] = p
        }
        attributedText = NSAttributedString(string: text, attributes: attrs)
    }

    /// The page's small capitals with their letter spacing (Arabic has neither).
    func setCaps(_ text: String, spacing: CGFloat, rtl: Bool) {
        setStyled(rtl ? text : text.uppercased(), spacing: rtl ? 0 : spacing)
    }
}

/// Children side by side, onto the next line when one doesn't fit (Android's FlowRow).
final class FlowView: UIView {
    var gapX: CGFloat
    var gapY: CGFloat
    /// Each line centred instead of starting at the side.
    var centerLines = false
    /// Each child centred on its line's height.
    var middle = false
    /// The width the lines are laid out in (the binder knows it before layout does).
    var maxWidth: CGFloat = 300 {
        didSet {
            guard abs(maxWidth - oldValue) > 0.5 else { return }
            remeasure()
        }
    }

    private var items: [UIView] = []
    private var sizes: [CGSize] = []

    init(gapX: CGFloat, gapY: CGFloat) {
        self.gapX = gapX
        self.gapY = gapY
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isEmpty: Bool { items.isEmpty }

    func set(_ views: [UIView]) {
        for v in items { v.removeFromSuperview() }
        items = views
        for v in views { addSubview(v) }
        remeasure()
    }

    private func remeasure() {
        sizes = items.map { FlowView.fit($0, maxWidth: maxWidth) }
        for v in items { v.translatesAutoresizingMaskIntoConstraints = true }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The size [v] wants, at most [maxWidth] wide.
    static func fit(_ v: UIView, maxWidth: CGFloat) -> CGSize {
        if let l = v as? UILabel {
            let s = l.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            return CGSize(width: Swift.min(ceil(s.width), maxWidth), height: ceil(s.height))
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        let s = v.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: 0),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: Swift.min(ceil(s.width), maxWidth), height: ceil(s.height))
    }

    /// The lines: which children (from, to), how wide and how tall.
    private func lines(_ w: CGFloat) -> [(from: Int, to: Int, width: CGFloat, height: CGFloat)] {
        var out: [(from: Int, to: Int, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0
        var lineH: CGFloat = 0
        var from = 0
        for (i, s) in sizes.enumerated() {
            if x > 0 && x + s.width > w {
                out.append((from: from, to: i, width: x - gapX, height: lineH))
                from = i
                x = 0
                lineH = 0
            }
            x += s.width + gapX
            lineH = Swift.max(lineH, s.height)
        }
        if from < sizes.count { out.append((from: from, to: sizes.count, width: Swift.max(0, x - gapX), height: lineH)) }
        return out
    }

    override var intrinsicContentSize: CGSize {
        let ls = lines(maxWidth)
        guard !ls.isEmpty else { return CGSize(width: UIView.noIntrinsicMetric, height: 0) }
        let h = ls.reduce(0) { $0 + $1.height } + gapY * CGFloat(ls.count - 1)
        return CGSize(width: UIView.noIntrinsicMetric, height: h)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 && abs(bounds.width - maxWidth) > 0.5 {
            maxWidth = bounds.width
            return
        }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 0
        for ln in lines(bounds.width > 0 ? bounds.width : maxWidth) {
            var cx: CGFloat = centerLines ? Swift.max(0, (bounds.width - ln.width) / 2) : 0
            for i in ln.from..<ln.to {
                let s = sizes[i]
                let top = middle ? y + (ln.height - s.height) / 2 : y
                let left = rtl ? bounds.width - cx - s.width : cx
                items[i].frame = CGRect(x: left, y: top, width: s.width, height: s.height)
                cx += s.width + gapX
            }
            y += ln.height + gapY
        }
    }
}

/// A logo or title picture: at most [maxW] × [maxH], as wide as its shape once it is in, so it
/// starts at the reading side (Android's FIT_START).
final class LogoView: NetImageView {
    private var wc: NSLayoutConstraint!
    private var hc: NSLayoutConstraint!
    private var maxW: CGFloat = 0
    private var maxH: CGFloat = 0

    init(maxW: CGFloat, maxH: CGFloat) {
        super.init(frame: .zero)
        contentMode = .scaleAspectFit
        translatesAutoresizingMaskIntoConstraints = false
        wc = widthAnchor.constraint(equalToConstant: maxW)
        hc = heightAnchor.constraint(equalToConstant: maxH)
        NSLayoutConstraint.activate([wc, hc])
        self.maxW = maxW
        self.maxH = maxH
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setBox(_ w: CGFloat, _ h: CGFloat) {
        maxW = w
        maxH = h
        wc.constant = w
        hc.constant = h
    }

    func load(_ urls: [String], done: ((Bool) -> Void)? = nil) {
        wc.constant = maxW
        ImageLoader.shared.load(self, urls: urls, size: CGSize(width: maxW, height: maxH)) { [weak self] ok in
            guard let self else { return }
            if ok, let img = self.image, img.size.width > 0, img.size.height > 0 {
                self.wc.constant = Swift.min(self.maxW, ceil(self.maxH * img.size.width / img.size.height))
            }
            done?(ok)
        }
    }
}

/// Small pieces drawn in the theme's colours.
enum Paint {
    /// Java's String.hashCode (the plates match Android's).
    static func javaHash(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 { h = h &* 31 &+ Int32(u) }
        return h
    }

    /// The coloured plate behind a poster that is still loading (or has none).
    static func plate(_ seed: String) -> UIColor {
        let hue = ((Int(javaHash(seed)) % 360) + 360) % 360
        return UIColor(hue: CGFloat(hue) / 360, saturation: 0.45, brightness: 0.28, alpha: 1)
    }

    /// [color] moved [f] of the way to [other].
    static func toward(_ color: UIColor, _ other: UIColor, _ f: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: 1)
    }

    /// The rating badge: "8.1" is IMDb's (yellow IMDb tag); "★7.5" is another site's (a star).
    static func ratingBadge(_ value: String, size: CGFloat, colors: HomeColors) -> UIView {
        let star = value.hasPrefix("★")
        let tag = PadLabel(star ? "★" : "IMDb", size: star ? size : size * 0.72, color: star ? Palette.star : .black, weight: .bold)
        if !star {
            tag.insets = UIEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)
            tag.backgroundColor = Palette.imdb
            tag.layer.cornerRadius = 2
            tag.clipsToBounds = true
        }
        let shown = star ? String(value.dropFirst()).trimmingCharacters(in: .whitespaces) : value
        let num = makeLabel(shown, size: size, color: colors.ink, weight: .bold)
        let row = UIStackView(axis: .horizontal, spacing: 5, alignment: .center, views: [tag, num])
        return boxed(row, insets: UIEdgeInsets(top: 3, left: 5, bottom: 3, right: 7), color: colors.canvas.alpha(0.92), radius: 7)
    }

    /// [content] in a rounded box with room around it.
    static func boxed(_ content: UIView, insets: UIEdgeInsets, color: UIColor?, radius: CGFloat, stroke: CGFloat = 0, strokeColor: UIColor? = nil) -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.rounded(color, radius: radius, stroke: stroke, strokeColor: strokeColor)
        box.addSubview(content)
        content.pinEdges(to: box, insets: insets)
        return box
    }

    /// A choice pill (a row of choices): filled when chosen.
    static func chip(_ c: HomeChip, colors: HomeColors, onTap: @escaping () -> Void) -> TapButton {
        let b = TapButton(onTap: onTap)
        if c.on {
            b.rounded(colors.ink, radius: 18)
        } else {
            b.rounded(colors.surface.alpha(0.9), radius: 18, stroke: 1, strokeColor: colors.ink.alpha(0.1))
        }
        let l = makeLabel(c.label, size: 13, color: c.on ? colors.canvas : colors.muted, weight: c.on ? .bold : .regular)
        l.isUserInteractionEnabled = false
        b.addSubview(l)
        NSLayoutConstraint.activate([
            b.heightAnchor.constraint(equalToConstant: 36),
            l.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            l.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 14),
            l.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -14),
        ])
        b.accessibilityLabel = c.label
        return b
    }

    /// A round button holding an icon.
    static func iconButton(_ icon: String, size: CGFloat = 40, iconSize: CGFloat = 18, tint: UIColor, label: String?, onTap: @escaping () -> Void) -> TapButton {
        let b = TapButton(onTap: onTap)
        let ic = Icons.view(icon, size: iconSize, tint: tint)
        ic.isUserInteractionEnabled = false
        b.addSubview(ic)
        ic.centerIn(b)
        b.sized(w: size, h: size)
        b.accessibilityLabel = label
        return b
    }

    static func spinner(_ color: UIColor) -> UIActivityIndicatorView {
        let s = UIActivityIndicatorView(style: .medium)
        s.color = color
        s.hidesWhenStopped = false
        s.startAnimating()
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// A round face: the picture, or the initial until it comes.
    static func face(name: String, image: String?, size: CGFloat, initialSize: CGFloat, colors: HomeColors) -> UIView {
        let face = UIView()
        face.translatesAutoresizingMaskIntoConstraints = false
        face.backgroundColor = colors.surface.alpha(0.9)
        face.layer.cornerRadius = size / 2
        face.layer.borderWidth = 1
        face.layer.borderColor = colors.ink.alpha(0.12).cgColor
        face.clipsToBounds = true
        face.sized(w: size, h: size)
        let initial = makeLabel(String(name.prefix(1)), size: initialSize, color: colors.subtle)
        initial.textAlignment = .center
        face.addSubview(initial)
        initial.centerIn(face)
        if let image {
            let img = NetImageView()
            face.addSubview(img)
            img.pinEdges(to: face)
            ImageLoader.shared.load(img, urls: [image], size: CGSize(width: size, height: size)) { ok in initial.isHidden = ok }
        }
        return face
    }

    /// The Android drawable name (without "ic_") for the play picker's icon names.
    static func pkIcon(_ name: String?) -> String? {
        switch name {
        case "zap", "zap-line": return "zap"
        case "check": return "check"
        case "download": return "download"
        case "external": return "external_link"
        case "play": return "play"
        case "radio": return "radio"
        case "x": return "x"
        case "arrow": return "arrow_right"
        case "lang": return "languages"
        case "users": return "users"
        case "crown": return "crown"
        case "copy": return "copy"
        case "info": return "info"
        case "settings": return "settings_2"
        case "plus": return "plus"
        case "trash": return "trash_2"
        case "star": return "star"
        case "eye": return "eye"
        case "eye-off": return "eye_off"
        case "link": return "link_2"
        default: return nil
        }
    }

    /// A round-ended button in one of the page's looks (Android's pkButtonView).
    static func pkButton(_ b: PkButton, height: CGFloat, radius: CGFloat, colors: HomeColors, rtl: Bool, onTap: @escaping () -> Void) -> TapButton {
        let white = UIColor.white
        var bg: UIColor?
        var stroke: UIColor?
        let fg: UIColor
        switch b.style {
        case "accent": bg = colors.accent; fg = colors.canvas
        case "outline": bg = colors.ink.alpha(0.04); stroke = colors.ink.alpha(0.3); fg = colors.ink
        case "green": bg = Palette.green.alpha(0.15); stroke = Palette.green.alpha(0.4); fg = Palette.green
        case "cache": bg = colors.accent.alpha(0.12); stroke = colors.accent.alpha(0.55); fg = colors.accent
        case "off": bg = colors.canvas.alpha(0.6); stroke = colors.ink.alpha(0.08); fg = colors.subtle
        case "white": bg = white; fg = .black
        case "glass": bg = white.alpha(0.05); stroke = white.alpha(0.15); fg = white.alpha(0.75)
        case "secondary": bg = colors.surface; stroke = colors.ink.alpha(0.08); fg = colors.ink
        case "amber": bg = Palette.amber300.alpha(0.1); stroke = Palette.amber300.alpha(0.4); fg = Palette.amber100
        case "installed": bg = colors.surface.alpha(0.7); stroke = colors.ink.alpha(0.08); fg = colors.ink
        case "danger": bg = Palette.danger.alpha(0.15); stroke = Palette.danger.alpha(0.3); fg = Palette.danger
        case "soft": bg = .clear; stroke = colors.ink.alpha(0.1); fg = colors.muted
        case "rate": bg = colors.accent.alpha(0.12); stroke = colors.accent.alpha(0.4); fg = colors.accent
        case "accentpill": bg = colors.accent.alpha(0.15); fg = colors.accent
        case "raised": bg = toward(colors.surface, colors.ink, 0.05); stroke = colors.ink.alpha(0.08); fg = colors.muted
        case "busy": bg = colors.ink.alpha(0.8); fg = colors.canvas
        case "link": bg = nil; fg = colors.subtle
        default: bg = colors.ink; fg = colors.canvas
        }
        let enabled = !["off", "green", "busy", "accentpill"].contains(b.style) && !b.busy
        var action: (() -> Void)?
        if enabled {
            action = {
                if let copy = b.copy { UIPasteboard.general.string = copy }
                onTap()
            }
        }
        let button = TapButton(onTap: action)
        button.rounded(bg, radius: radius, stroke: stroke == nil ? 0 : 1, strokeColor: stroke)
        let small = height < 40
        let row = UIStackView(axis: .horizontal, spacing: small ? 6 : 10, alignment: .center)
        row.isUserInteractionEnabled = false
        let icon = pkIcon(b.icon)
        if b.busy {
            row.addArrangedSubview(spinner(fg))
        } else if let icon, b.icon != "arrow" {
            // An installed addon's check is in the accent colour, its text not.
            let tint = b.style == "installed" && b.icon == "check" ? colors.accent : fg
            row.addArrangedSubview(Icons.view(icon, size: small ? 14 : 18, tint: tint))
        }
        let size: CGFloat = b.style == "link" ? 13 : height < 34 ? 12 : height < 46 ? 13.5 : 14.5
        row.addArrangedSubview(makeLabel(b.label, size: size, color: fg, weight: b.style == "link" ? .regular : .bold))
        if let icon, b.icon == "arrow" {
            let arrow = Icons.view(icon, size: 14, tint: fg)
            if rtl { arrow.transform = CGAffineTransform(scaleX: -1, y: 1) }
            row.setCustomSpacing(6, after: row.arrangedSubviews.last!)
            row.addArrangedSubview(arrow)
        }
        button.addSubview(row)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: height),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            row.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: button.leadingAnchor, constant: 24),
            row.topAnchor.constraint(greaterThanOrEqualTo: button.topAnchor, constant: 4),
        ])
        let lead = button.widthAnchor.constraint(equalTo: row.widthAnchor, constant: 50)
        lead.priority = .defaultHigh
        lead.isActive = true
        button.isEnabled = enabled
        button.alpha = b.busy ? 0.6 : 1
        button.accessibilityLabel = b.label
        return button
    }

    /// Fills [v] like aspect-fill, lined up at [fy] of the picture's height (0 = top): a face
    /// framed from its upper part.
    static func crop(_ v: UIImageView, size: CGSize, fy: CGFloat) {
        guard let img = v.image, img.size.width > 0, img.size.height > 0, size.width > 0, size.height > 0 else { return }
        let scale = Swift.max(size.width / img.size.width, size.height / img.size.height)
        let fw = Swift.min(1, size.width / (img.size.width * scale))
        let fh = Swift.min(1, size.height / (img.size.height * scale))
        v.contentMode = .scaleToFill
        v.layer.contentsRect = CGRect(x: (1 - fw) / 2, y: (1 - fh) * fy, width: fw, height: fh)
    }

    static func uncrop(_ v: UIImageView) {
        v.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        v.contentMode = .scaleAspectFill
    }
}

extension ShadeView {
    /// Android's BOTTOM_TOP gradient: [colors] from the bottom up.
    func fromBottom(_ colors: [UIColor]) {
        horizontal = false
        self.colors = Array(colors.reversed())
    }

    /// Android's LEFT_RIGHT (RIGHT_LEFT in Arabic): [colors] from the reading side across.
    func fromStart(_ colors: [UIColor], rtl: Bool) {
        horizontal = true
        self.colors = rtl ? Array(colors.reversed()) : colors
    }
}

/// A soft round glow of one colour from near the top (a streaming service's heading).
final class GlowView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    /// Where its centre sits across (0 start … 1 end).
    var centerX: CGFloat = 0.3 { didSet { setNeedsLayout() } }

    var color: UIColor? {
        didSet {
            let g = layer as? CAGradientLayer
            if let c = color {
                g?.colors = [c.alpha(0.22).cgColor, c.alpha(0).cgColor]
            } else {
                g?.colors = nil
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        (layer as? CAGradientLayer)?.type = .radial
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let g = layer as? CAGradientLayer, bounds.width > 0, bounds.height > 0 else { return }
        g.startPoint = CGPoint(x: centerX, y: 0)
        g.endPoint = CGPoint(x: centerX + 0.9, y: 0.9 * bounds.width / bounds.height)
    }
}

/// The view controller to show a dialog from: the one on top in [view]'s window.
func topController(from view: UIView) -> UIViewController? {
    var c = view.window?.rootViewController
    while let p = c?.presentedViewController, !p.isBeingDismissed { c = p }
    return c
}
