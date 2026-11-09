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
        let attr: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        if semanticContentAttribute != attr { semanticContentAttribute = attr }
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
}

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
final class TapButton: UIControl {
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
