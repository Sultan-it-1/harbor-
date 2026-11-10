import UIKit

// Small drawing helpers for the native screens (Android: Ui.kt and NativeHome's own helpers).
// Sizes are points (Android's dp / sp map one to one).

enum Fonts {
    /// The page's body face (the system's).
    static func body(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func bold(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .bold) }

    /// The display face for big titles (Android: the system serif; iOS: New York).
    static func display(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: serif, size: size)
    }

    /// Numbers that don't jump as they change (times, counts).
    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .medium) -> UIFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

/// A label like Android's label(): text, size, colour, weight, at most [lines] lines (0 = any).
func makeLabel(_ text: String? = nil, size: CGFloat = 14, color: UIColor = .white, weight: UIFont.Weight = .regular, lines: Int = 1, display: Bool = false) -> UILabel {
    let l = UILabel()
    l.text = text
    l.font = display ? Fonts.display(size, weight) : Fonts.body(size, weight)
    l.textColor = color
    l.numberOfLines = lines
    l.lineBreakMode = .byTruncatingTail
    l.textAlignment = .natural
    l.adjustsFontForContentSizeCategory = false
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

extension UIView {
    /// Rounded corners, a fill and an optional outline (Android's rounded()).
    func rounded(_ color: UIColor?, radius: CGFloat, stroke: CGFloat = 0, strokeColor: UIColor? = nil) {
        backgroundColor = color
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.borderWidth = stroke
        layer.borderColor = strokeColor?.cgColor
        if radius > 0 { layer.masksToBounds = false }
    }

    /// Right to left (Arabic) or left to right, for this view and everything in it: iOS doesn't
    /// pass the direction down by itself, and the app's language isn't the phone's.
    func setDirection(rtl: Bool) {
        // A scoreboard keeps home on the left whatever the language.
        if self is LTRStack {
            semanticContentAttribute = .forceLeftToRight
            return
        }
        let attr: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        if semanticContentAttribute != attr { semanticContentAttribute = attr }
        // Text starts at the reading side too (centred text stays centred, end text at the end).
        if let l = self as? EndLabel {
            l.textAlignment = rtl ? .left : .right
        } else if let l = self as? UILabel, l.textAlignment != .center {
            l.textAlignment = rtl ? .right : .left
        } else if let f = self as? UITextField, f.textAlignment != .center {
            f.textAlignment = rtl ? .right : .left
        }
        for sub in subviews { sub.setDirection(rtl: rtl) }
    }

    func pinEdges(to other: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
        ])
    }

    /// Like pinEdges, the bottom a little weaker: a table cell's content sets the cell's height
    /// without fighting the height the table gives it first.
    func pinInCell(_ cell: UIView, top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        let b = bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -bottom)
        b.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: cell.topAnchor, constant: top),
            b,
            leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailing),
        ])
    }

    /// Fixed width and / or height constraints (returned so they can change later).
    @discardableResult
    func sized(w: CGFloat? = nil, h: CGFloat? = nil) -> (w: NSLayoutConstraint?, h: NSLayoutConstraint?) {
        translatesAutoresizingMaskIntoConstraints = false
        let wc = w.map { widthAnchor.constraint(equalToConstant: $0) }
        let hc = h.map { heightAnchor.constraint(equalToConstant: $0) }
        NSLayoutConstraint.activate([wc, hc].compactMap { $0 })
        return (wc, hc)
    }

    /// Centred in [other].
    func centerIn(_ other: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: other.centerXAnchor),
            centerYAnchor.constraint(equalTo: other.centerYAnchor),
        ])
    }

    func removeAllSubviews() {
        for v in subviews { v.removeFromSuperview() }
    }
}

extension UIStackView {
    convenience init(axis: NSLayoutConstraint.Axis, spacing: CGFloat = 0, alignment: UIStackView.Alignment = .fill, views: [UIView] = []) {
        self.init(arrangedSubviews: views)
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
        translatesAutoresizingMaskIntoConstraints = false
    }

    func removeAllArranged() {
        for v in arrangedSubviews {
            removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    /// Adds [v] with [before] points of room above / before it (none for the first).
    func add(_ v: UIView, gap before: CGFloat = 0) {
        if let last = arrangedSubviews.last, before > 0 { setCustomSpacing(before, after: last) }
        addArrangedSubview(v)
    }
}

/// A label that sits at the end of its line (the left in Arabic).
final class EndLabel: UILabel {
    convenience init(_ text: String?, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular) {
        self.init(frame: .zero)
        self.text = text
        font = Fonts.body(size, weight)
        textColor = color
        numberOfLines = 1
        lineBreakMode = .byTruncatingTail
        textAlignment = .right
        translatesAutoresizingMaskIntoConstraints = false
    }
}

/// A stack that stays left to right in Arabic too (a match's home and away sides).
final class LTRStack: UIStackView {}

/// A view that lets touches through where it has nothing of its own (the screens' layer over the
/// page: with no screen up, every tap goes to the page).
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A vertical shade (a picture's top or bottom fading into the page).
final class ShadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var colors: [UIColor] = [] {
        didSet { (layer as? CAGradientLayer)?.colors = colors.map(\.cgColor) }
    }

    /// Where each colour sits (0 top … 1 bottom); nil = evenly.
    var stops: [CGFloat]? {
        didSet { (layer as? CAGradientLayer)?.locations = stops?.map { NSNumber(value: Double($0)) } }
    }

    /// Left to right instead of top to bottom.
    var horizontal = false {
        didSet {
            let g = layer as? CAGradientLayer
            g?.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
            g?.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        }
    }

    init(_ colors: [UIColor] = [], stops: [CGFloat]? = nil) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        self.colors = colors
        self.stops = stops
        (layer as? CAGradientLayer)?.colors = colors.map(\.cgColor)
        (layer as? CAGradientLayer)?.locations = stops?.map { NSNumber(value: Double($0)) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A button that runs a closure (no target / selector boilerplate), shrinking a little when held.
class TapButton: UIControl {
    var onTap: (() -> Void)?
    /// How much it shrinks while pressed (1 = not at all).
    var pressScale: CGFloat = 0.97

    init(onTap: (() -> Void)? = nil) {
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped() { onTap?() }

    override var isHighlighted: Bool {
        didSet {
            guard pressScale != 1 else { return }
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: self.pressScale, y: self.pressScale) : .identity
                self.alpha = self.isHighlighted ? 0.85 : 1
            }
        }
    }
}

/// A rounded pill: an optional icon and a label, in [fg] on [bg].
func makePill(_ text: String, icon: String? = nil, fg: UIColor, bg: UIColor?, size: CGFloat = 13, weight: UIFont.Weight = .semibold, height: CGFloat = 36, padding: CGFloat = 14, stroke: UIColor? = nil, onTap: (() -> Void)? = nil) -> TapButton {
    let b = TapButton(onTap: onTap)
    b.rounded(bg, radius: height / 2, stroke: stroke == nil ? 0 : 1, strokeColor: stroke)
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 6
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    if let icon { stack.addArrangedSubview(Icons.view(icon, size: size + 3, tint: fg)) }
    let label = makeLabel(text, size: size, color: fg, weight: weight)
    stack.addArrangedSubview(label)
    b.addSubview(stack)
    NSLayoutConstraint.activate([
        b.heightAnchor.constraint(equalToConstant: height),
        stack.centerYAnchor.constraint(equalTo: b.centerYAnchor),
        stack.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: padding),
        stack.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -padding),
    ])
    b.accessibilityLabel = text
    return b
}
