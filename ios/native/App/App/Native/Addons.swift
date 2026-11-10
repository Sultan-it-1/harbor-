import UIKit

// The Addons page and an addon's page (Android: the Ad*Holder classes): addon cards, tiles, the
// featured addon, "Top on stremio-addons.net", categories, installed addons, an addon's top, its
// project information and documentation. Taps send {a:"ad", row, what, i}.

enum AdPaint {
    static let rose300 = UIColor(argb: 0xFFFDA4AF)
    static let rose500 = UIColor(argb: 0xFFF43F5E)
    static let emerald500 = UIColor(argb: 0xFF10B981)

    /// An addon's logo: a rounded square (its picture, else its initial on its gradient).
    static func logo(_ l: AdLogo, size: CGFloat, colors: HomeColors) -> UIView {
        let r = Swift.max(4, floor(size * 0.22))
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer.cornerRadius = r
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        box.isUserInteractionEnabled = false
        box.sized(w: size, h: size)
        if let from = l.from, let to = l.to {
            let g = ShadeView([from, to])
            (g.layer as? CAGradientLayer)?.startPoint = CGPoint(x: 0, y: 0)
            (g.layer as? CAGradientLayer)?.endPoint = CGPoint(x: 1, y: 1)
            box.addSubview(g)
            g.pinEdges(to: box)
        } else {
            box.backgroundColor = colors.surface
        }
        let initial = makeLabel(String(l.initial.prefix(1)).uppercased(), size: floor(size * 0.5), color: UIColor.white.alpha(0.95), weight: .bold)
        box.addSubview(initial)
        initial.centerIn(box)
        if !l.images.isEmpty {
            let img = NetImageView()
            img.backgroundColor = UIColor.white.alpha(0.06)
            box.addSubview(img)
            img.pinEdges(to: box)
            ImageLoader.shared.load(img, urls: l.images, size: CGSize(width: size, height: size)) { ok in img.isHidden = !ok }
        }
        box.layer.borderWidth = 0.5
        box.layer.borderColor = UIColor.white.alpha(0.08).cgColor
        return box
    }

    /// A small pill: community stars, rising, new, a curated tag.
    static func pill(_ p: AdPill, small: Bool = true, colors: HomeColors, rtl: Bool) -> UIView {
        let fg: UIColor
        let bg: UIColor
        var ring: UIColor?
        switch p.tone {
        case "star": fg = colors.accent; bg = colors.canvas.alpha(0.7); ring = colors.accent.alpha(0.3)
        case "rise": fg = rose300; bg = rose500.alpha(0.15); ring = rose500.alpha(0.4)
        case "new": fg = Palette.green; bg = emerald500.alpha(0.15); ring = emerald500.alpha(0.3)
        case "good": fg = colors.accent; bg = colors.accent.alpha(0.15)
        case "warn": fg = colors.muted; bg = colors.ink.alpha(0.1)
        default: fg = colors.subtle; bg = colors.ink.alpha(0.1)
        }
        let upper = ["new", "good", "warn", "neutral"].contains(p.tone)
        let line = UIStackView(axis: .horizontal, spacing: 4, alignment: .center)
        let icon: String?
        switch p.icon {
        case "star": icon = "star"
        case "trend": icon = "trending_up"
        case "sparkles": icon = "sparkles"
        default: icon = nil
        }
        if let icon { line.addArrangedSubview(Icons.view(icon, size: 9, tint: fg, filled: icon == "star")) }
        let l = makeLabel(size: small ? 10.5 : 11, color: fg, weight: .bold)
        if upper { l.setCaps(p.text, spacing: p.tone == "new" ? 0.14 : 0.1, rtl: rtl) } else { l.text = p.text }
        line.addArrangedSubview(l)
        return Paint.boxed(line, insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 7), color: bg, radius: 10, stroke: ring == nil ? 0 : 1, strokeColor: ring)
    }

    /// The faint logo behind a card and the canvas fading over it (the page's CardArtBackdrop).
    static func art(_ frame: UIView, art: String?, logo: AdLogo, size: CGFloat, colors: HomeColors, rtl: Bool) {
        guard art != nil, !logo.images.isEmpty else { return }
        let img = NetImageView()
        img.alpha = 0
        img.isUserInteractionEnabled = false
        frame.insertSubview(img, at: 0)
        img.pinEdges(to: frame)
        ImageLoader.shared.load(img, urls: logo.images, size: CGSize(width: size, height: size)) { ok in if ok { img.alpha = 0.1 } }
        let c = colors.canvas
        let fade = ShadeView()
        fade.fromStart([c, c, c.alpha(0.78), c.alpha(0.42)], rtl: rtl)
        frame.insertSubview(fade, at: 1)
        fade.pinEdges(to: frame)
    }

    /// A section's heading: the title (and its line), "See all (n)" / "Show less", a rule under it.
    static func heading(_ title: String, blurb: String?, action: String?, open: Bool, size: CGFloat, colors: HomeColors, rtl: Bool, onAction: (() -> Void)?) -> UIView {
        let t = makeLabel(title, size: size, color: colors.ink, lines: 2, display: true)
        let texts = UIStackView(axis: .vertical, spacing: 6, views: [t])
        if let b = blurb {
            let l = makeLabel(size: 14, color: colors.muted, lines: 0)
            l.setStyled(b, lineHeight: 1.3)
            texts.addArrangedSubview(l)
        }
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = UIStackView(axis: .horizontal, spacing: 8, alignment: .bottom, views: [texts])
        if let action, let onAction {
            let a = TapButton(onTap: onAction)
            let chev = Icons.view("chevron_right", size: 12, tint: colors.accent)
            chev.transform = open ? CGAffineTransform(rotationAngle: .pi / 2) : (rtl ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            let row = UIStackView(axis: .horizontal, spacing: 2, alignment: .center, views: [makeLabel(action, size: 12.5, color: colors.accent, weight: .bold), chev])
            row.isUserInteractionEnabled = false
            a.addSubview(row)
            row.pinEdges(to: a, insets: UIEdgeInsets(top: 6, left: 10, bottom: 4, right: 0))
            a.accessibilityLabel = action
            line.addArrangedSubview(a)
        }
        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = colors.ink.alpha(0.07)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let box = UIStackView(axis: .vertical, spacing: 12, views: [line, rule])
        return padded(box, bottom: 12)
    }
}

/// An Addons block's cell: the screen's margins, taps as {a:"ad"}.
class AddonCell: SectionCell {
    var rowKey = ""

    func ad(_ what: String, i: Int? = nil) { act("ad", row: rowKey, i: i, what: what) }

    /// Holds the block's views, rebuilt on each bind (like Android's dropAll).
    let holder = UIView()
    var holderInsets: [NSLayoutConstraint] = []

    /// Places [holder] [side] in from the sides with [bottom] under it.
    func place(side: CGFloat, bottom: CGFloat) {
        holderInsets[1].constant = side
        holderInsets[2].constant = side
        holderInsets[3].constant = bottom
    }

    override func setUp() {
        holder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(holder)
        let b = contentView.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: 0)
        b.priority = UILayoutPriority(999)
        holderInsets = [
            holder.topAnchor.constraint(equalTo: contentView.topAnchor),
            holder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contentView.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: 16),
            b,
        ]
        NSLayoutConstraint.activate(holderInsets)
    }

    /// Puts [v] in the holder, filling it.
    func fill(_ v: UIView) {
        holder.removeAllSubviews()
        holder.addSubview(v)
        v.pinEdges(to: holder)
    }

    func button(_ b: PkButton, height: CGFloat, padding: CGFloat, onTap: @escaping () -> Void) -> TapButton {
        Paint.pkButton(b, height: height, radius: height / 2, padding: padding, colors: colors, rtl: rtl, onTap: onTap)
    }

    func pills(_ list: [AdPill], small: Bool = true, gap: CGFloat = 6, width: CGFloat) -> FlowView {
        let f = FlowView(gapX: gap, gapY: gap)
        f.middle = true
        f.maxWidth = width
        f.set(list.map { AdPaint.pill($0, small: small, colors: colors, rtl: rtl) })
        return f
    }
}

/// An addon as a card down the page (see AdCard).
final class AdCardCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .card(let c)? = r.ad else { return }
        rowKey = r.key
        place(side: 16, bottom: 10)
        if c.more { ad("more") }
        let card = TapButton { [weak self] in self?.ad("open") }
        card.pressScale = 0.98
        card.rounded(colors.surface, radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        card.clipsToBounds = true
        card.alpha = c.dim ? 0.6 : 1
        card.accessibilityLabel = c.name
        AdPaint.art(card, art: c.art, logo: c.logo, size: 56, colors: colors, rtl: m.rtl)
        let innerW = metrics.width - 32 - 34 - 56 - 16 - 10 - (c.button != nil && c.variant != "feature" ? 110 : 0) - (c.chevron ? 22 : 0)
        let nameLine = FlowView(gapX: 8, gapY: 4)
        nameLine.middle = true
        nameLine.maxWidth = c.variant == "feature" && c.button != nil ? innerW - 120 : innerW
        nameLine.set([makeLabel(c.name, size: 16, color: colors.ink, weight: .bold, lines: 2) as UIView] + c.pills.map { AdPaint.pill($0, colors: colors, rtl: m.rtl) })
        nameLine.isUserInteractionEnabled = false
        let texts = PassthroughStack(axis: .vertical, spacing: 0)
        if c.variant == "feature", let b = c.button {
            nameLine.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let top = PassthroughStack(axis: .horizontal, spacing: 10, alignment: .center, views: [nameLine, button(b, height: 36, padding: 15) { [weak self] in self?.ad("btn") }])
            texts.addArrangedSubview(top)
        } else {
            texts.addArrangedSubview(nameLine)
        }
        if let d = c.desc {
            let l = makeLabel(size: c.variant == "feature" ? 13 : 13.5, color: colors.muted, lines: 3)
            l.setStyled(d, lineHeight: 1.3)
            texts.add(l, gap: 6)
        }
        if !c.tags.isEmpty {
            let tags = pills(c.tags, width: innerW)
            tags.isUserInteractionEnabled = false
            texts.add(tags, gap: 8)
        }
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = PassthroughStack(axis: .horizontal, spacing: 16, alignment: .top, views: [AdPaint.logo(c.logo, size: 56, colors: colors), texts])
        row.setCustomSpacing(10, after: texts)
        if c.variant != "feature", let b = c.button {
            let wrap = PassthroughView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            let v = button(b, height: 36, padding: 15) { [weak self] in self?.ad("btn") }
            wrap.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                v.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                v.topAnchor.constraint(greaterThanOrEqualTo: wrap.topAnchor),
            ])
            row.addArrangedSubview(wrap)
            row.alignment = .fill
        }
        if c.chevron {
            let chev = Icons.view("chevron_right", size: 16, tint: colors.subtle)
            if m.rtl { chev.transform = CGAffineTransform(scaleX: -1, y: 1) }
            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.isUserInteractionEnabled = false
            wrap.addSubview(chev)
            NSLayoutConstraint.activate([
                chev.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                chev.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                chev.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            ])
            row.setCustomSpacing(6, after: row.arrangedSubviews.last!)
            row.addArrangedSubview(wrap)
            row.alignment = .fill
        }
        card.addSubview(row)
        row.pinEdges(to: card, insets: UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 16))
        fill(card)
    }
}

/// Addons as tiles, two across or a sideways strip (see AdTiles).
final class AdTilesCell: AddonCell {
    private var strip: SideScroll?

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .tiles(let t)? = r.ad else { return }
        // Redrawn (an addon installed, its stars in): where it was scrolled to.
        let keepX = rowKey == r.key ? (strip?.scroll.contentOffset.x ?? 0) : 0
        rowKey = r.key
        strip = nil
        if t.strip {
            place(side: 0, bottom: 12)
            let s = SideScroll(spacing: 12, inset: 16, alignment: .fill)
            s.set(t.items.enumerated().map { i, it in
                let v = tile(it, i, 236)
                v.widthAnchor.constraint(equalToConstant: 236).isActive = true
                return v
            })
            fill(padded(s, bottom: 8))
            strip = s
            if keepX > 0 { DispatchQueue.main.async { s.scroll.contentOffset = CGPoint(x: keepX, y: 0) } } else { s.toStart(rtl: m.rtl) }
            return
        }
        place(side: 16, bottom: 12)
        let w = floor((metrics.width - 32 - 12) / 2)
        let col = UIStackView(axis: .vertical, spacing: 12)
        var i = 0
        while i < t.items.count {
            let line = UIStackView(axis: .horizontal, spacing: 12, alignment: .fill)
            line.distribution = .fillEqually
            for k in 0..<2 {
                let idx = i + k
                if idx < t.items.count {
                    line.addArrangedSubview(tile(t.items[idx], idx, w))
                } else {
                    let v = UIView()
                    v.translatesAutoresizingMaskIntoConstraints = false
                    line.addArrangedSubview(v)
                }
            }
            col.addArrangedSubview(line)
            i += 2
        }
        fill(col)
    }

    private func tile(_ t: AdTile, _ i: Int, _ w: CGFloat) -> UIView {
        let card = TapButton { [weak self] in self?.ad("open", i: i) }
        card.pressScale = 0.98
        card.rounded(colors.surface, radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        card.clipsToBounds = true
        card.accessibilityLabel = t.name
        AdPaint.art(card, art: t.art, logo: t.logo, size: 48, colors: colors, rtl: rtl)
        let names = UIStackView(axis: .vertical, spacing: 4, views: [makeLabel(t.name, size: 15, color: colors.ink, weight: .bold, lines: 2)])
        if !t.pills.isEmpty { names.addArrangedSubview(pills(t.pills, gap: 4, width: w - 32 - 60)) }
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [AdPaint.logo(t.logo, size: 48, colors: colors), names])
        top.isUserInteractionEnabled = false
        let col = PassthroughStack(axis: .vertical, spacing: 0, alignment: .fill, views: [top])
        if let d = t.desc {
            let l = makeLabel(size: 13, color: colors.muted, lines: 3)
            l.setStyled(d, lineHeight: 1.3)
            col.add(l, gap: 14)
        }
        col.addArrangedSubview(flexSpace())
        let b = button(t.button, height: 44, padding: 12) { [weak self] in self?.ad("btn", i: i) }
        col.add(b, gap: 16)
        card.addSubview(col)
        col.pinEdges(to: card, insets: UIEdgeInsets(top: 18, left: 16, bottom: 16, right: 16))
        return card
    }
}

/// The featured addon (see AdHero).
final class AdHeroCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .hero(let h)? = r.ad else { return }
        rowKey = r.key
        place(side: 16, bottom: 40)
        let rtl = m.rtl
        let w = metrics.width - 32
        let card = TapButton { [weak self] in self?.ad("open") }
        card.pressScale = 0.99
        card.rounded(colors.surface, radius: 24, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        card.clipsToBounds = true
        card.accessibilityLabel = h.title
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        if let from = h.from, let to = h.to {
            // The accent's glow on the end half, fading into the card toward the text.
            let glow = ShadeView()
            glow.horizontal = true
            glow.colors = rtl ? [from, to] : [to, from]
            glow.alpha = 0.6
            let fade = ShadeView()
            fade.horizontal = true
            fade.colors = rtl ? [.clear, colors.surface] : [colors.surface, .clear]
            for (v, f) in [(glow, w / 2), (fade, w * 2 / 3)] {
                v.isUserInteractionEnabled = false
                card.addSubview(v)
                v.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    v.topAnchor.constraint(equalTo: card.topAnchor),
                    v.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                    v.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                    v.widthAnchor.constraint(equalToConstant: floor(f)),
                ])
            }
        }
        let eyebrowText = makeLabel(size: 10.5, color: colors.subtle, weight: .bold)
        eyebrowText.setCaps(h.eyebrow, spacing: 0.32, rtl: rtl)
        let eyebrow = FlowView(gapX: 8, gapY: 4)
        eyebrow.middle = true
        eyebrow.maxWidth = w - 56
        eyebrow.set([eyebrowText as UIView] + h.pills.map { AdPaint.pill($0, small: false, colors: colors, rtl: rtl) })
        let title = makeLabel(size: 42, color: colors.ink, lines: 2, display: true)
        title.setStyled(h.title, lineHeight: 1.05)
        let col = PassthroughStack(axis: .vertical, spacing: 12, views: [eyebrow, title])
        if let s = h.subtitle {
            let l = makeLabel(size: 14.5, color: colors.muted, lines: 0)
            l.setStyled(s, lineHeight: 1.35)
            col.addArrangedSubview(l)
        }
        let chev = Icons.view("chevron_right", size: 13, tint: colors.muted)
        if rtl { chev.transform = CGAffineTransform(scaleX: -1, y: 1) }
        let link = UIStackView(axis: .horizontal, spacing: 4, alignment: .center, views: [makeLabel(h.link, size: 12.5, color: colors.muted), chev])
        link.isUserInteractionEnabled = false
        let actions = PassthroughStack(axis: .horizontal, spacing: 16, alignment: .center, views: [button(h.button, height: 36, padding: 20) { [weak self] in self?.ad("btn") }, link])
        col.add(startAlignedPassthrough(actions), gap: 28)
        for v in [eyebrow, title] as [UIView] { v.isUserInteractionEnabled = false }
        card.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            col.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            col.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: 32),
        ])
        fill(card)
    }
}

/// [v] at the start of a line that lets touches through around it.
func startAlignedPassthrough(_ v: UIView) -> UIView {
    let w = PassthroughView()
    w.translatesAutoresizingMaskIntoConstraints = false
    v.translatesAutoresizingMaskIntoConstraints = false
    w.addSubview(v)
    NSLayoutConstraint.activate([
        v.topAnchor.constraint(equalTo: w.topAnchor),
        v.bottomAnchor.constraint(equalTo: w.bottomAnchor),
        v.leadingAnchor.constraint(equalTo: w.leadingAnchor),
        v.trailingAnchor.constraint(lessThanOrEqualTo: w.trailingAnchor),
    ])
    return w
}

/// "Top on stremio-addons.net" and its cards (see AdCommunity).
final class AdCommunityCell: AddonCell {
    private var strip: SideScroll?

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .community(let c)? = r.ad else { return }
        let keepX = rowKey == r.key ? (strip?.scroll.contentOffset.x ?? 0) : 0
        strip = nil
        rowKey = r.key
        place(side: 0, bottom: 44)
        let rtl = m.rtl
        // The site's logo and heading (a tap opens the site).
        let logoBox = TapButton { [weak self] in self?.ad("site") }
        logoBox.rounded(colors.surface, radius: 28, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        logoBox.clipsToBounds = true
        logoBox.accessibilityLabel = c.site
        logoBox.sized(w: 56, h: 56)
        if let u = c.logo {
            let img = NetImageView()
            img.isUserInteractionEnabled = false
            logoBox.addSubview(img)
            img.pinEdges(to: logoBox)
            ImageLoader.shared.load(img, urls: [u], size: CGSize(width: 56, height: 56))
        }
        let kicker = makeLabel(size: 10.5, color: colors.accent, weight: .bold)
        kicker.setCaps(c.kicker, spacing: 0.22, rtl: rtl)
        let title = makeLabel(size: 22, color: colors.ink, lines: 2)
        let at = NSMutableAttributedString(string: c.title + " ", attributes: [.font: Fonts.body(22), .foregroundColor: colors.ink])
        at.append(NSAttributedString(string: c.site, attributes: [.font: Fonts.bold(22), .foregroundColor: colors.ink, .underlineStyle: NSUnderlineStyle.single.rawValue]))
        title.attributedText = at
        title.isUserInteractionEnabled = true
        title.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(siteTapped)))
        let texts = UIStackView(axis: .vertical, spacing: 4, views: [kicker, title, makeLabel(c.sub, size: 12.5, color: colors.muted, lines: 2)])
        let head = UIStackView(axis: .horizontal, spacing: 16, alignment: .center, views: [logoBox, texts])
        // The tabs and "Browse".
        let tabs = UIStackView(axis: .horizontal, spacing: 0, alignment: .center)
        for tb in c.tabs {
            let id = tb.id
            let b = TapButton { [weak self] in self?.ad("tab:" + id) }
            b.rounded(tb.on ? colors.ink : .clear, radius: 16)
            let l = makeLabel(tb.label, size: 12, color: tb.on ? colors.canvas : colors.muted, weight: .bold)
            l.isUserInteractionEnabled = false
            b.addSubview(l)
            NSLayoutConstraint.activate([
                b.heightAnchor.constraint(equalToConstant: 32),
                l.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                l.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 12),
                l.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -12),
            ])
            b.accessibilityLabel = tb.label
            tabs.addArrangedSubview(b)
        }
        let tabsBox = Paint.boxed(tabs, insets: UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4), color: colors.canvas.alpha(0.4), radius: 20, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        let browse = button(PkButton(id: "site", label: c.browse, style: "soft", icon: "external"), height: 36, padding: 13) { [weak self] in self?.ad("site") }
        let bar = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [tabsBox, browse])
        let col = UIStackView(axis: .vertical, spacing: 16, views: [padded(head, leading: 16, trailing: 16), startAligned(bar, leading: 16)])
        switch c.state {
        case "ok":
            let s = SideScroll(spacing: 12, inset: 16, alignment: .fill)
            s.set(c.cards.enumerated().map { i, cc in
                let v = card(cc, i, rtl)
                v.widthAnchor.constraint(equalToConstant: 280).isActive = true
                return v
            })
            col.addArrangedSubview(s)
            strip = s
            if keepX > 0 { DispatchQueue.main.async { s.scroll.contentOffset = CGPoint(x: keepX, y: 0) } } else { s.toStart(rtl: rtl) }
        case "loading":
            let line = UIStackView(axis: .horizontal, spacing: 12, alignment: .center)
            for _ in 0..<3 {
                let v = UIView()
                v.translatesAutoresizingMaskIntoConstraints = false
                v.rounded(colors.surface.alpha(0.4), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
                v.sized(w: 280, h: 216)
                line.addArrangedSubview(v)
            }
            let clip = UIView()
            clip.translatesAutoresizingMaskIntoConstraints = false
            clip.clipsToBounds = true
            clip.addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: clip.topAnchor),
                line.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
                line.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 16),
            ])
            col.addArrangedSubview(clip)
        default:
            let l = PadLabel(c.message ?? "", size: 13, color: colors.muted, insets: UIEdgeInsets(top: 28, left: 20, bottom: 28, right: 20), lines: 0)
            l.textAlignment = .center
            l.rounded(colors.canvas.alpha(0.3), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            l.clipsToBounds = true
            col.addArrangedSubview(padded(l, leading: 16, trailing: 16))
        }
        fill(col)
    }

    @objc private func siteTapped() { ad("site") }

    private func card(_ c: AdCommunityCard, _ i: Int, _ rtl: Bool) -> UIView {
        let card = TapButton { [weak self] in self?.ad("card", i: i) }
        card.pressScale = 0.98
        card.rounded(colors.surface, radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        card.clipsToBounds = true
        card.accessibilityLabel = c.name
        let s = colors.surface
        let top = ShadeView([s, Paint.toward(s, colors.ink, 0.06)])
        (top.layer as? CAGradientLayer)?.startPoint = CGPoint(x: 0, y: 0)
        (top.layer as? CAGradientLayer)?.endPoint = CGPoint(x: 1, y: 1)
        top.translatesAutoresizingMaskIntoConstraints = false
        top.clipsToBounds = true
        top.heightAnchor.constraint(equalToConstant: 96).isActive = true
        if let u = c.background {
            let img = NetImageView()
            top.addSubview(img)
            img.pinEdges(to: top)
            ImageLoader.shared.load(img, urls: [u], size: CGSize(width: 280, height: 96))
        }
        let shade = ShadeView()
        shade.fromBottom([s, s.alpha(0.3), .clear])
        top.addSubview(shade)
        shade.pinEdges(to: top)
        if let st = c.stars {
            let p = AdPaint.pill(AdPill(text: st, tone: "star", icon: "star"), small: false, colors: colors, rtl: rtl)
            top.addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: top.topAnchor, constant: 10),
                p.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -10),
            ])
        }
        if let u = c.logo {
            let img = NetImageView()
            img.contentMode = .scaleAspectFit
            let box = Paint.boxed(img, insets: UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4), color: colors.canvas.alpha(0.8), radius: 8, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            box.clipsToBounds = true
            box.sized(w: 40, h: 40)
            top.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 10),
                box.bottomAnchor.constraint(equalTo: top.bottomAnchor, constant: -10),
            ])
            ImageLoader.shared.load(img, urls: [u], size: CGSize(width: 32, height: 32)) { ok in if !ok { box.isHidden = true } }
        }
        top.isUserInteractionEnabled = false
        let body = PassthroughStack(axis: .vertical, spacing: 2, views: [makeLabel(c.name, size: 14, color: colors.ink, weight: .bold, lines: 2)])
        if let d = c.desc { body.addArrangedSubview(makeLabel(d, size: 11.5, color: colors.subtle, lines: 2)) }
        body.addArrangedSubview(flexSpace())
        let types = FlowView(gapX: 4, gapY: 4)
        types.maxWidth = 280 - 28 - 100
        types.set(c.types.map { t in
            let l = PadLabel(size: 9.5, color: colors.subtle, weight: .bold, insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
            l.setCaps(t, spacing: 0.14, rtl: rtl)
            l.rounded(colors.surface.alpha(0.6), radius: 8)
            l.clipsToBounds = true
            return l
        })
        types.isUserInteractionEnabled = false
        types.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let b: PkButton = c.installed != nil
            ? PkButton(id: "installed", label: c.installed ?? "", style: "accentpill", icon: "check")
            : PkButton(id: "install", label: c.install ?? "", style: "ink", icon: "plus", busy: c.busy)
        let foot = PassthroughStack(axis: .horizontal, spacing: 8, alignment: .center, views: [types, button(b, height: 32, padding: 11) { [weak self] in self?.ad("install", i: i) }])
        body.add(foot, gap: 8)
        body.isLayoutMarginsRelativeArrangement = true
        body.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let col = PassthroughStack(axis: .vertical, spacing: 0, views: [top, body])
        card.addSubview(col)
        col.pinEdges(to: card)
        return card
    }
}

/// A section's heading (see AdHead).
final class AdHeadCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .head(let h)? = r.ad else { return }
        rowKey = r.key
        place(side: 16, bottom: 20)
        fill(AdPaint.heading(h.title, blurb: h.blurb, action: h.action, open: h.open, size: h.size, colors: colors, rtl: m.rtl) { [weak self] in self?.ad("more") })
    }
}

/// "Browse by category": coloured tiles (see AdCategories).
final class AdCatsCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .categories(let c)? = r.ad else { return }
        rowKey = r.key
        place(side: 16, bottom: 44)
        let col = UIStackView(axis: .vertical, spacing: 12)
        let head = AdPaint.heading(c.title, blurb: c.blurb, action: nil, open: false, size: 26, colors: colors, rtl: m.rtl, onAction: nil)
        col.addArrangedSubview(head)
        col.setCustomSpacing(20, after: head)
        var i = 0
        while i < c.tiles.count {
            let line = UIStackView(axis: .horizontal, spacing: 12, alignment: .fill)
            line.distribution = .fillEqually
            for k in 0..<2 {
                let idx = i + k
                if idx < c.tiles.count {
                    line.addArrangedSubview(tile(c.tiles[idx], idx))
                } else {
                    let v = UIView()
                    v.translatesAutoresizingMaskIntoConstraints = false
                    line.addArrangedSubview(v)
                }
            }
            line.heightAnchor.constraint(equalToConstant: 120).isActive = true
            col.addArrangedSubview(line)
            i += 2
        }
        fill(col)
    }

    private func tile(_ t: AdCategory, _ i: Int) -> UIView {
        let f = TapButton { [weak self] in self?.ad("cat", i: i) }
        f.pressScale = 0.98
        f.layer.cornerRadius = 16
        f.clipsToBounds = true
        f.layer.borderWidth = 1
        f.layer.borderColor = colors.ink.alpha(0.08).cgColor
        f.accessibilityLabel = t.title
        let g = ShadeView([t.from ?? colors.surface, t.to ?? colors.surface])
        (g.layer as? CAGradientLayer)?.startPoint = CGPoint(x: 0, y: 0)
        (g.layer as? CAGradientLayer)?.endPoint = CGPoint(x: 1, y: 1)
        let shade = ShadeView()
        shade.fromBottom([colors.canvas.alpha(0.85), colors.canvas.alpha(0.3), .clear])
        for v in [g, shade] {
            f.addSubview(v)
            v.pinEdges(to: f)
        }
        if let u = t.icon {
            let img = NetImageView()
            img.contentMode = .scaleAspectFit
            img.alpha = 0.55
            img.sized(w: 56, h: 56)
            f.addSubview(img)
            NSLayoutConstraint.activate([
                img.topAnchor.constraint(equalTo: f.topAnchor, constant: 14),
                img.trailingAnchor.constraint(equalTo: f.trailingAnchor, constant: -14),
            ])
            ImageLoader.shared.load(img, urls: [u], size: CGSize(width: 56, height: 56))
        }
        let texts = UIStackView(axis: .vertical, spacing: 0, views: [
            makeLabel(t.title, size: 19, color: colors.ink, display: true),
            makeLabel(t.blurb, size: 12, color: colors.muted, lines: 2),
        ])
        texts.isUserInteractionEnabled = false
        f.addSubview(texts)
        NSLayoutConstraint.activate([
            texts.leadingAnchor.constraint(equalTo: f.leadingAnchor, constant: 16),
            texts.trailingAnchor.constraint(equalTo: f.trailingAnchor, constant: -16),
            texts.bottomAnchor.constraint(equalTo: f.bottomAnchor, constant: -14),
        ])
        return f
    }
}

/// An installed addon, as the page's phone row: its logo and name, then its controls.
final class AdInstalledCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .installed(let a)? = r.ad else { return }
        rowKey = r.key
        place(side: 16, bottom: 8)
        let card = TapButton { [weak self] in self?.ad("open") }
        card.pressScale = 0.99
        card.rounded(colors.surface, radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        card.alpha = a.dim ? 0.6 : 1
        card.accessibilityLabel = a.name
        let logo = AdPaint.logo(a.logo, size: 36, colors: colors)
        logo.alpha = a.enabled ? 1 : 0.45
        let texts = UIStackView(axis: .vertical, spacing: 2, views: [
            makeLabel(a.name, size: 14, color: colors.ink, lines: 2),
            makeLabel(a.sub, size: 11.5, color: colors.subtle),
        ])
        texts.alpha = a.enabled ? 1 : 0.55
        let top = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [logo, texts])
        top.isUserInteractionEnabled = false
        let controls = PassthroughStack(axis: .horizontal, spacing: 8, alignment: .center)
        if !a.dim {
            // The switch: on (accent) or off.
            let sw = TapButton { [weak self] in self?.ad("toggle") }
            sw.rounded(a.enabled ? colors.accent : colors.ink.alpha(0.18), radius: 11)
            sw.sized(w: 40, h: 22)
            sw.accessibilityTraits = [.button]
            sw.accessibilityValue = a.enabled ? "1" : "0"
            let knob = UIView()
            knob.translatesAutoresizingMaskIntoConstraints = false
            knob.isUserInteractionEnabled = false
            knob.backgroundColor = colors.ink
            knob.layer.cornerRadius = 8
            knob.sized(w: 16, h: 16)
            sw.addSubview(knob)
            knob.centerYAnchor.constraint(equalTo: sw.centerYAnchor).isActive = true
            if a.enabled {
                knob.trailingAnchor.constraint(equalTo: sw.trailingAnchor, constant: -3).isActive = true
            } else {
                knob.leadingAnchor.constraint(equalTo: sw.leadingAnchor, constant: 3).isActive = true
            }
            controls.addArrangedSubview(sw)
            if let mg = a.manage {
                controls.addArrangedSubview(button(PkButton(id: "manage", label: mg, style: "raised", icon: "settings"), height: 30, padding: 13) { [weak self] in self?.ad("manage") })
            }
        }
        controls.addArrangedSubview(flexSpace())
        controls.addArrangedSubview(button(a.pill, height: 30, padding: 13) { [weak self] in self?.ad("remove") })
        let col = PassthroughStack(axis: .vertical, spacing: 12, views: [top, controls])
        card.addSubview(col)
        col.pinEdges(to: card, insets: UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        fill(card)
    }
}

/// An addon's page, its top (see AdDetail).
final class AdDetailCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .detail(let d)? = r.ad else { return }
        rowKey = r.key
        place(side: 0, bottom: 0)
        let rtl = m.rtl
        let c = colors.canvas
        let frame = UIView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.clipsToBounds = true
        let base = ShadeView([colors.surface, c, c])
        (base.layer as? CAGradientLayer)?.startPoint = CGPoint(x: 0, y: 0)
        (base.layer as? CAGradientLayer)?.endPoint = CGPoint(x: 1, y: 1)
        frame.addSubview(base)
        base.pinEdges(to: frame)
        if let bg = d.background {
            let img = NetImageView()
            img.alpha = 0.55
            frame.addSubview(img)
            img.pinEdges(to: frame)
            ImageLoader.shared.load(img, urls: [bg], size: CGSize(width: metrics.width, height: 420))
            let s = ShadeView()
            s.horizontal = true
            s.colors = [c, c.alpha(0.88), c.alpha(0.6), c.alpha(0.3)]
            frame.addSubview(s)
            s.pinEdges(to: frame)
        } else if let g = d.glow {
            // The logo, stretched huge and faint: the page's blurred glow.
            let img = NetImageView()
            img.alpha = 0.28
            frame.addSubview(img)
            img.pinEdges(to: frame)
            ImageLoader.shared.load(img, urls: [g], size: CGSize(width: 12, height: 12))
            let s = ShadeView([.clear, c.alpha(0.24)])
            frame.addSubview(s)
            s.pinEdges(to: frame)
        }
        let low = ShadeView([.clear, .clear, c.alpha(0.28)])
        frame.addSubview(low)
        low.pinEdges(to: frame)
        for v in frame.subviews { v.isUserInteractionEnabled = false }

        let col = PassthroughStack(axis: .vertical, spacing: 0, alignment: .fill)
        col.addArrangedSubview(startAligned(AdPaint.logo(d.logo, size: 96, colors: colors)))
        let eyebrow = makeLabel(size: 11, color: colors.subtle, weight: .bold, lines: 3)
        eyebrow.setCaps(d.eyebrow, spacing: 0.2, rtl: rtl)
        col.add(eyebrow, gap: 20)
        let name = makeLabel(size: 28, color: colors.ink, lines: 0, display: true)
        name.setStyled(d.name, lineHeight: 1.1)
        col.add(name, gap: 8)
        if let rising = d.rising { col.add(startAligned(AdPaint.pill(rising, small: false, colors: colors, rtl: rtl)), gap: 8) }
        if let text = d.desc {
            let desc = makeLabel(size: 14, color: colors.muted, lines: d.descOpen ? 0 : 3)
            desc.setStyled(text, lineHeight: 1.4)
            col.add(desc, gap: 10)
            let toggle = TapButton { [weak self] in self?.ad("desc") }
            toggle.pressScale = 1
            let l = makeLabel(size: 11.5, color: colors.accent, weight: .bold)
            l.setCaps(d.descOpen ? d.less : d.more, spacing: 0.18, rtl: rtl)
            let chev = Icons.view("chevron_down", size: 12, tint: colors.accent)
            if d.descOpen { chev.transform = CGAffineTransform(rotationAngle: .pi) }
            let row = UIStackView(axis: .horizontal, spacing: 4, alignment: .center, views: [l, chev])
            row.isUserInteractionEnabled = false
            toggle.addSubview(row)
            row.pinEdges(to: toggle, insets: UIEdgeInsets(top: 6, left: 0, bottom: 4, right: 8))
            // "View more" only when the text runs past its three lines.
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.4
            let full = (text as NSString).boundingRect(
                with: CGSize(width: metrics.width - 40, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: Fonts.body(14), .paragraphStyle: p],
                context: nil
            ).height
            let cut = full > ceil(Fonts.body(14).lineHeight * 1.4 * 3) + 2
            let wrap = startAlignedPassthrough(toggle)
            wrap.isHidden = !(d.descOpen || cut)
            col.addArrangedSubview(wrap)
        }
        let buttons = FlowView(gapX: 8, gapY: 8)
        buttons.middle = true
        buttons.maxWidth = metrics.width - 40
        buttons.set(d.buttons.map { b in
            let id = b.id
            return button(b, height: 44, padding: 17) { [weak self] in self?.ad("btn:" + id) }
        })
        col.add(buttons, gap: 16)
        if !d.tags.isEmpty { col.add(pills(d.tags, width: metrics.width - 40), gap: 12) }
        frame.addSubview(col)
        col.pinEdges(to: frame, insets: UIEdgeInsets(top: 96, left: 20, bottom: 24, right: 20))
        if let st = d.stars {
            let s = TapButton { [weak self] in self?.ad("btn:rate") }
            let row = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [
                Icons.view("star", size: 22, tint: colors.accent, filled: true),
                makeLabel(st, size: 26, color: colors.ink, weight: .bold),
            ])
            row.isUserInteractionEnabled = false
            s.addSubview(row)
            row.pinEdges(to: s, insets: UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6))
            s.accessibilityLabel = st
            frame.addSubview(s)
            NSLayoutConstraint.activate([
                s.topAnchor.constraint(equalTo: frame.topAnchor, constant: 92),
                s.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -16),
            ])
        }
        fill(frame)
    }
}

/// "Project information" (see AdInfo).
final class AdInfoCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .info(let a)? = r.ad else { return }
        rowKey = r.key
        place(side: 0, bottom: 0)
        let rtl = m.rtl
        let lineColor = colors.ink.alpha(0.08)
        func rule() -> UIView {
            let v = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.backgroundColor = lineColor
            v.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return v
        }
        let col = UIStackView(axis: .vertical, spacing: 0)
        col.isLayoutMarginsRelativeArrangement = true
        col.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 32, leading: 20, bottom: 32, trailing: 20)
        col.backgroundColor = colors.surface.alpha(0.15)
        let note = makeLabel(size: 10.5, color: colors.subtle)
        note.setCaps(a.note, spacing: 0.22, rtl: rtl)
        let head = FlowView(gapX: 16, gapY: 4)
        head.middle = true
        head.maxWidth = metrics.width - 40
        head.set([makeLabel(a.title, size: 22, color: colors.ink, display: true), note])
        col.addArrangedSubview(head)
        col.setCustomSpacing(24, after: head)
        col.addArrangedSubview(rule())
        for st in a.stats {
            let k = makeLabel(size: 12, color: colors.subtle)
            k.setCaps(st.label, spacing: 0.16, rtl: rtl)
            k.setContentHuggingPriority(.required, for: .horizontal)
            let v = EndLabel(st.value, size: 13.5, color: colors.ink)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(axis: .horizontal, spacing: 24, alignment: .center, views: [k, v])
            col.addArrangedSubview(padded(row, top: 12, bottom: 12))
            col.addArrangedSubview(rule())
        }
        let urlLabel = makeLabel(size: 12, color: colors.subtle)
        urlLabel.setCaps(a.urlLabel, spacing: 0.16, rtl: rtl)
        urlLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let urlHead = PassthroughStack(axis: .horizontal, spacing: 6, alignment: .center, views: [urlLabel])
        if let cp = a.copy {
            urlHead.addArrangedSubview(button(PkButton(id: "copy", label: cp, style: "soft", icon: "copy", copy: a.url), height: 28, padding: 10) { [weak self] in self?.ad("copyurl") })
        }
        urlHead.addArrangedSubview(button(PkButton(id: "reveal", label: a.reveal, style: "soft", icon: a.copy != nil ? "eye-off" : "eye"), height: 28, padding: 10) { [weak self] in self?.ad("reveal") })
        let last = col.arrangedSubviews.last!
        col.setCustomSpacing(32, after: last)
        col.addArrangedSubview(urlHead)
        let url = PadLabel(size: 12.5, color: colors.muted, insets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16), lines: 0)
        url.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        url.setStyled(a.url, lineHeight: 1.35)
        url.rounded(colors.canvas.alpha(0.6), radius: 12, stroke: 1, strokeColor: lineColor)
        url.clipsToBounds = true
        col.setCustomSpacing(12, after: urlHead)
        col.addArrangedSubview(url)
        var prev: UIView = url
        if let h = a.hint {
            let l = makeLabel(size: 11.5, color: colors.subtle, lines: 0)
            l.setStyled(h, lineHeight: 1.3)
            col.setCustomSpacing(12, after: url)
            col.addArrangedSubview(l)
            prev = l
        }
        let r2 = rule()
        col.setCustomSpacing(40, after: prev)
        col.addArrangedSubview(r2)
        let foot = makeLabel(a.foot, size: 12, color: colors.subtle, lines: 0)
        foot.textAlignment = .center
        col.setCustomSpacing(24, after: r2)
        col.addArrangedSubview(foot)
        let credit = makeLabel(size: 11.5, color: colors.subtle, lines: 0)
        credit.setStyled(a.credit, lineHeight: 1.35)
        credit.textAlignment = .center
        credit.isUserInteractionEnabled = true
        credit.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(siteTapped)))
        col.setCustomSpacing(8, after: foot)
        col.addArrangedSubview(credit)
        fill(col)
    }

    @objc private func siteTapped() { ad("site") }
}

/// "Documentation" (see AdDoc): folded at about 420 points until "View more".
final class AdDocCell: AddonCell {
    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .doc(let d)? = r.ad else { return }
        rowKey = r.key
        place(side: 0, bottom: 0)
        let rtl = m.rtl
        let col = UIStackView(axis: .vertical, spacing: 0)
        col.isLayoutMarginsRelativeArrangement = true
        col.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 32, leading: 20, bottom: 8, trailing: 20)
        col.backgroundColor = colors.surface.alpha(0.15)
        let note = makeLabel(size: 10.5, color: colors.subtle)
        note.setCaps(d.note, spacing: 0.22, rtl: rtl)
        let head = FlowView(gapX: 16, gapY: 4)
        head.middle = true
        head.maxWidth = metrics.width - 40
        head.set([makeLabel(d.title, size: 22, color: colors.ink, display: true), note])
        col.addArrangedSubview(head)
        col.setCustomSpacing(24, after: head)
        let body = UIStackView(axis: .vertical, spacing: 0)
        for part in d.parts {
            let v: UIView
            switch part.kind {
            case "h1": v = makeLabel(part.text, size: 20, color: colors.ink, lines: 0, display: true)
            case "h2": v = makeLabel(part.text, size: 17, color: colors.ink, lines: 0, display: true)
            case "h3":
                let l = makeLabel(size: 14, color: colors.subtle, weight: .bold, lines: 0)
                l.setCaps(part.text, spacing: 0.14, rtl: rtl)
                v = l
            case "li":
                let l = makeLabel(size: 14, color: colors.muted, lines: 0)
                l.setStyled("•  " + part.text, lineHeight: 1.4)
                v = l
            case "code":
                let l = PadLabel(size: 12.5, color: colors.muted, insets: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), lines: 0)
                l.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                l.text = part.text
                l.rounded(colors.canvas.alpha(0.6), radius: 10)
                l.clipsToBounds = true
                v = l
            default:
                let l = makeLabel(size: 14, color: colors.muted, lines: 0)
                l.setStyled(part.text, lineHeight: 1.4)
                v = l
            }
            let gap: CGFloat
            switch part.kind {
            case "h1": gap = 20
            case "h2": gap = 16
            case "h3": gap = 14
            case "li": gap = 4
            default: gap = 10
            }
            body.add(v, gap: gap)
        }
        if d.open {
            col.addArrangedSubview(body)
        } else {
            // Folded at about the page's 420px, the text fading out at the fold.
            let fold = UIView()
            fold.translatesAutoresizingMaskIntoConstraints = false
            fold.clipsToBounds = true
            fold.heightAnchor.constraint(equalToConstant: 420).isActive = true
            fold.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: fold.topAnchor),
                body.leadingAnchor.constraint(equalTo: fold.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: fold.trailingAnchor),
            ])
            let fade = ShadeView()
            fade.fromBottom([Paint.toward(colors.canvas, colors.surface, 0.15), .clear])
            fold.addSubview(fade)
            fade.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                fade.leadingAnchor.constraint(equalTo: fold.leadingAnchor),
                fade.trailingAnchor.constraint(equalTo: fold.trailingAnchor),
                fade.bottomAnchor.constraint(equalTo: fold.bottomAnchor),
                fade.heightAnchor.constraint(equalToConstant: 64),
            ])
            col.addArrangedSubview(fold)
        }
        let toggle = TapButton { [weak self] in self?.ad("doc") }
        toggle.pressScale = 1
        let l = makeLabel(size: 11.5, color: colors.accent, weight: .bold)
        l.setCaps(d.open ? d.less : d.more, spacing: 0.18, rtl: rtl)
        let chev = Icons.view("chevron_down", size: 12, tint: colors.accent)
        if d.open { chev.transform = CGAffineTransform(rotationAngle: .pi) }
        let row = UIStackView(axis: .horizontal, spacing: 4, alignment: .center, views: [l, chev])
        row.isUserInteractionEnabled = false
        toggle.addSubview(row)
        row.pinEdges(to: toggle, insets: UIEdgeInsets(top: 12, left: 0, bottom: 8, right: 8))
        col.addArrangedSubview(startAligned(toggle))
        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = colors.ink.alpha(0.08)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        col.setCustomSpacing(24, after: col.arrangedSubviews.last!)
        col.addArrangedSubview(rule)
        fill(col)
    }
}
