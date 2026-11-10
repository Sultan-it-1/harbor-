import UIKit

// The play picker's other layout (Android: the Pk*Holder classes): the source the page picked as a
// big card, the qualities, the drawer of every source (a line each, in one box), what was found
// where, messages in boxes, and the search's breathing logo. Taps send {a:"pk", row, what, i}.

extension Paint {
    static func pkTone(_ tone: String, _ colors: HomeColors) -> UIColor {
        switch tone {
        case "accent": return colors.accent
        case "green": return Palette.green
        case "subtle": return colors.subtle
        case "danger": return Palette.danger
        case "ink": return colors.ink
        default: return colors.muted
        }
    }

    /// A format badge: its picture [b.w] wide (as tall as its shape, at most [maxH]), or its name.
    static func pkBadge(_ b: PkBadge, maxH: CGFloat, colors: HomeColors) -> UIView {
        let text = PadLabel(b.label, size: 10.5, color: colors.ink, weight: .bold, insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        text.rounded(colors.canvas.alpha(0.6), radius: 5, stroke: 1, strokeColor: colors.ink.alpha(0.14))
        text.clipsToBounds = true
        let box = UIStackView(axis: .vertical, spacing: 0, alignment: .trailing, views: [text])
        guard let src = b.src else { return box }
        let w = b.w
        // The page's badges are at most about as tall as they are wide.
        let maxPx = Swift.max(maxH, b.w * 0.94)
        let img = NetImageView()
        img.contentMode = .scaleAspectFit
        img.isHidden = true
        let size = img.sized(w: w, h: Swift.min(maxPx, w))
        box.addArrangedSubview(img)
        ImageLoader.shared.load(img, urls: [src], size: CGSize(width: w, height: maxPx)) { ok in
            guard ok else { return }
            if let i = img.image, i.size.width > 0 {
                size.h?.constant = Swift.max(8, Swift.min(maxPx, w * i.size.height / i.size.width))
            }
            img.isHidden = false
            text.isHidden = true
        }
        return box
    }

    /// An audio language: its flag (an emoji) and, when [named], its name; "Multi" as a pill.
    static func pkFlag(_ f: PkFlag, big: Bool, named: Bool, colors: HomeColors, rtl: Bool) -> UIView {
        guard let emoji = f.emoji else {
            let shown = named || f.multi ? f.label : String(f.label.prefix(2))
            let l = PadLabel(size: big ? 11 : 9.5, color: f.multi ? colors.accent : colors.subtle, weight: .bold, insets: UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5))
            l.setCaps(shown, spacing: 0.16, rtl: rtl)
            if f.multi {
                l.rounded(colors.accent.alpha(0.15), radius: 3, stroke: 1, strokeColor: colors.accent.alpha(0.35))
            } else if !named {
                l.rounded(colors.canvas.alpha(0.7), radius: 3, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            }
            l.clipsToBounds = true
            return l
        }
        let line = UIStackView(axis: .horizontal, spacing: 6, alignment: .center, views: [makeLabel(emoji, size: big ? 19 : 14)])
        if named { line.addArrangedSubview(makeLabel(f.label, size: big ? 15 : 13, color: colors.muted, weight: .bold)) }
        return line
    }

    /// A coloured line with its icon (cached, queued, in your library…).
    static func pkStatus(_ s: PkStatus, size: CGFloat, spacing: CGFloat, colors: HomeColors, rtl: Bool) -> UIView {
        let c = pkTone(s.tone, colors)
        let line = UIStackView(axis: .horizontal, spacing: 5, alignment: .center)
        if let icon = pkIcon(s.icon) { line.addArrangedSubview(Icons.view(icon, size: 12, tint: c, filled: s.icon == "zap")) }
        let l = makeLabel(size: size, color: c, weight: .bold)
        if s.upper {
            l.setCaps(s.text, spacing: spacing, rtl: rtl)
        } else {
            l.setStyled(s.text, spacing: rtl ? 0 : spacing)
        }
        line.addArrangedSubview(l)
        return line
    }

    /// A small pill: REMUX, a release group, an edition, "Same file as host".
    static func pkTag(_ t: PkTag, colors: HomeColors, rtl: Bool) -> UIView {
        let l = PadLabel(size: 10.5, weight: .bold, insets: UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 9))
        switch t.style {
        case "remux":
            l.textColor = colors.ink
            l.rounded(colors.canvas.alpha(0.95), radius: 13, stroke: 1, strokeColor: colors.ink.alpha(0.16))
        case "group":
            l.textColor = colors.muted
            l.rounded(colors.canvas.alpha(0.45), radius: 13, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        case "accent":
            l.textColor = colors.accent
            l.rounded(colors.accent.alpha(0.15), radius: 6, stroke: 1, strokeColor: colors.accent.alpha(0.3))
        case "danger":
            l.textColor = Palette.danger
            l.rounded(Palette.danger.alpha(0.2), radius: 13, stroke: 1, strokeColor: Palette.danger.alpha(0.4))
        default:
            l.textColor = colors.muted
            l.rounded(colors.surface.alpha(0.9), radius: 6, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        }
        l.clipsToBounds = true
        l.setCaps(t.text, spacing: 0.14, rtl: rtl)
        return l
    }

    /// An addon's round logo (or its initial on a plate), [size] across.
    static func pkLogo(_ l: PkLogo, size: CGFloat, ring: CGFloat = 0, colors: HomeColors) -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.rounded(colors.surface, radius: size / 2, stroke: ring, strokeColor: colors.canvas)
        box.clipsToBounds = true
        box.sized(w: size, h: size)
        let initial = makeLabel(String(l.initial.prefix(1)).uppercased(), size: size * 0.45, color: colors.muted, weight: .bold)
        box.addSubview(initial)
        initial.centerIn(box)
        if !l.images.isEmpty {
            let img = NetImageView()
            box.addSubview(img)
            img.pinEdges(to: box)
            ImageLoader.shared.load(img, urls: l.images, size: CGSize(width: size, height: size)) { ok in img.isHidden = !ok }
        }
        return box
    }
}

/// A picker block's cell: the screen's margins (16 at the sides), [bottomGap] under it.
class PickerCell: SectionCell {
    var rowKey = ""

    func pk(_ what: String, i: Int? = nil) { act("pk", row: rowKey, i: i, what: what) }

    /// A round button that copies [url] (and says so).
    func copyButton(_ url: String, size: CGFloat) -> UIView {
        let b = Paint.iconButton("copy", size: size, iconSize: 15, tint: colors.muted, label: model?.label("copyLink", "Copy link")) { [weak self] in
            UIPasteboard.general.string = url
            if let self, let m = self.model { self.screen?.overlays.showToast(m.label("copied", "Link copied")) }
        }
        b.rounded(colors.canvas.alpha(0.6), radius: size / 2, stroke: 1, strokeColor: colors.ink.alpha(0.1))
        return b
    }

    var innerWidth: CGFloat { metrics.width - 32 }
}

/// The source the page picked, as its big card. Its button sends {a:"pk", what:"primary"}.
final class PkPickCell: PickerCell {
    private let card = UIStackView(axis: .vertical, alignment: .fill)
    private let art = UIView()
    private var artW: NSLayoutConstraint!
    private var artH: NSLayoutConstraint!
    private let pic = NetImageView()
    private let logoShade = ShadeView()
    private let logo = LogoView(maxW: 200, maxH: 60)
    private let badgeShade = ShadeView()
    private var badgeShadeH: NSLayoutConstraint!
    private let badges = UIStackView(axis: .vertical, spacing: 4, alignment: .trailing)
    private let flags = FlowView(gapX: 12, gapY: 8)
    private let confirm = makeLabel(size: 12, weight: .bold, lines: 2)
    private let match = UIView()
    private let title = makeLabel(size: 15.5, lines: 0)
    private let file = makeLabel(size: 12.5, lines: 0)
    private let summary = makeLabel(size: 13, weight: .bold, lines: 0)
    private let chips = FlowView(gapX: 10, gapY: 8)
    private let actions = FlowView(gapX: 18, gapY: 14)

    override func setUp() {
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 20, trailing: 18)
        contentView.addSubview(card)
        card.pinInCell(contentView, leading: 16, bottom: 20, trailing: 16)

        art.translatesAutoresizingMaskIntoConstraints = false
        art.layer.cornerRadius = 16
        art.clipsToBounds = true
        artW = art.widthAnchor.constraint(equalToConstant: 170)
        artH = art.heightAnchor.constraint(equalToConstant: 255)
        NSLayoutConstraint.activate([artW, artH])
        for v in [pic, logoShade] as [UIView] {
            art.addSubview(v)
            v.pinEdges(to: art)
        }
        logoShade.fromBottom([UIColor.black.alpha(0.75), UIColor.black.alpha(0.3), .clear])
        logo.alpha = 0.7
        art.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: art.leadingAnchor, constant: 14),
            logo.bottomAnchor.constraint(equalTo: art.bottomAnchor, constant: -12),
        ])
        badgeShade.colors = [UIColor.black.alpha(0.65), UIColor.black.alpha(0.2), .clear]
        art.addSubview(badgeShade)
        badgeShade.translatesAutoresizingMaskIntoConstraints = false
        badgeShadeH = badgeShade.heightAnchor.constraint(equalToConstant: 80)
        NSLayoutConstraint.activate([
            badgeShade.topAnchor.constraint(equalTo: art.topAnchor),
            badgeShade.leadingAnchor.constraint(equalTo: art.leadingAnchor),
            badgeShade.trailingAnchor.constraint(equalTo: art.trailingAnchor),
            badgeShadeH,
        ])
        art.addSubview(badges)
        NSLayoutConstraint.activate([
            badges.topAnchor.constraint(equalTo: art.topAnchor, constant: 8),
            badges.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: -8),
        ])
        card.addArrangedSubview(startAligned(art))
        flags.middle = true
        card.add(flags, gap: 18)
        card.add(confirm, gap: 14)
        card.add(match, gap: 12)
        title.font = .monospacedSystemFont(ofSize: 15.5, weight: .regular)
        card.add(title, gap: 14)
        file.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        card.add(file, gap: 8)
        card.add(summary, gap: 14)
        chips.middle = true
        card.add(chips, gap: 14)
        actions.middle = true
        card.add(actions, gap: 22)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .pick(let p)? = r.pk else { return }
        rowKey = r.key
        let rtl = m.rtl
        card.rounded(colors.canvas.alpha(0.85), radius: 24, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        let inner = innerWidth - 36
        let aw = p.wide ? inner : Swift.min(inner, 170)
        let ah = floor(p.wide ? aw * 9 / 16 : aw * 3 / 2)
        artW.constant = aw
        artH.constant = ah
        art.backgroundColor = colors.canvas.alpha(0.5)
        art.layer.borderWidth = 1
        art.layer.borderColor = colors.ink.alpha(0.08).cgColor
        if p.images.isEmpty { ImageLoader.shared.clear(pic) } else { ImageLoader.shared.load(pic, urls: p.images, size: CGSize(width: aw, height: ah)) }
        let showLogo = p.wide && p.logo != nil
        logoShade.isHidden = !showLogo
        logo.isHidden = !showLogo
        if showLogo, let l = p.logo {
            logo.setBox(floor(aw * 0.58), floor(ah * 0.26))
            logo.load([l])
        } else {
            ImageLoader.shared.clear(logo)
        }
        badges.removeAllArranged()
        for b in p.badges { badges.addArrangedSubview(Paint.pkBadge(b, maxH: 28, colors: colors)) }
        badgeShade.isHidden = p.badges.isEmpty
        badgeShadeH.constant = floor(ah / 3)

        let fw = inner
        flags.maxWidth = fw
        var fl: [UIView] = []
        if !p.flags.isEmpty {
            fl = p.flags.map { Paint.pkFlag($0, big: true, named: true, colors: colors, rtl: rtl) }
            if let more = p.moreFlags { fl.append(makeLabel(more, size: 13, color: colors.subtle, weight: .bold)) }
        } else if let none = p.noAudio {
            let l = PadLabel(size: 11, color: colors.subtle, weight: .bold, insets: UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
            l.setCaps(none, spacing: 0.18, rtl: rtl)
            l.rounded(colors.canvas.alpha(0.6), radius: 13, stroke: 1, strokeColor: colors.ink.alpha(0.1))
            l.clipsToBounds = true
            fl = [l]
        }
        flags.set(fl)
        flags.isHidden = fl.isEmpty
        confirm.isHidden = p.confirm == nil
        confirm.textColor = colors.subtle
        if let c = p.confirm { confirm.setCaps(c, spacing: 0.28, rtl: rtl) }
        match.removeAllSubviews()
        if let t = p.match {
            let v = Paint.pkTag(t, colors: colors, rtl: rtl)
            match.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: match.topAnchor),
                v.bottomAnchor.constraint(equalTo: match.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: match.leadingAnchor),
                v.trailingAnchor.constraint(lessThanOrEqualTo: match.trailingAnchor),
            ])
        }
        match.isHidden = p.match == nil
        title.textColor = colors.ink
        title.setStyled(p.title, lineHeight: 1.3)
        file.textColor = colors.subtle.alpha(0.8)
        file.setStyled(p.file ?? "", lineHeight: 1.3)
        file.isHidden = p.file == nil
        summary.textColor = colors.muted
        summary.setCaps(p.summary.joined(separator: "  ·  "), spacing: 0.16, rtl: rtl)
        summary.isHidden = p.summary.isEmpty

        var ch: [UIView] = []
        if let s = p.status { ch.append(Paint.pkStatus(s, size: 12.5, spacing: 0.04, colors: colors, rtl: rtl)) }
        for c in p.chips { ch.append(Paint.pkTag(c, colors: colors, rtl: rtl)) }
        chips.maxWidth = fw
        chips.set(ch)
        chips.isHidden = ch.isEmpty

        var acts: [UIView] = [Paint.pkButton(p.button, height: 52, radius: 26, colors: colors, rtl: rtl) { [weak self] in self?.pk("primary") }]
        if let v = p.via { acts.append(via(v, rtl)) }
        if let url = p.copy { acts.append(copyButton(url, size: 36)) }
        actions.maxWidth = fw
        actions.set(acts)
    }

    private func via(_ v: PkVia, _ rtl: Bool) -> UIView {
        func addonLine(_ prefix: String, _ size: CGFloat, _ color: UIColor, _ spacing: CGFloat) -> UIView {
            let line = UIStackView(axis: .horizontal, spacing: 6, alignment: .center)
            if !prefix.isEmpty {
                let l = makeLabel(size: size, color: color, weight: .bold)
                l.setCaps(prefix, spacing: spacing, rtl: rtl)
                line.addArrangedSubview(l)
            }
            line.addArrangedSubview(Paint.pkLogo(PkLogo(images: v.logo, initial: v.addon), size: 16, colors: colors))
            let a = makeLabel(size: size, color: color, weight: .bold)
            a.setCaps(v.addon, spacing: spacing, rtl: rtl)
            line.addArrangedSubview(a)
            return line
        }
        guard let topText = v.top else { return addonLine(v.by, 11, colors.subtle, 0.28) }
        let c = v.tone == "danger" ? Palette.danger.alpha(0.8) : colors.muted
        let top = UIStackView(axis: .horizontal, spacing: 5, alignment: .center)
        if v.zap { top.addArrangedSubview(Icons.view("zap", size: 11, tint: colors.accent, filled: true)) }
        let t = makeLabel(size: 11, color: c, weight: .bold)
        t.setCaps(topText, spacing: 0.28, rtl: rtl)
        top.addArrangedSubview(t)
        return UIStackView(axis: .vertical, spacing: 4, alignment: .leading, views: [top, addonLine(v.by, 10, colors.subtle.alpha(0.7), 0.18)])
    }
}

/// "Switch quality", its note, the Cached / language pills and a button per quality.
final class PkTiersCell: PickerCell {
    private let title = makeLabel(size: 12, weight: .bold)
    private let info = TapButton()
    private let infoIcon = UIImageView()
    private let pills = UIStackView(axis: .horizontal, spacing: 4, alignment: .center)
    private var note: UIView!
    private let noteTitle = makeLabel(size: 10.5, weight: .bold)
    private let noteBody = makeLabel(size: 12.5, lines: 0)
    private let tiers = FlowView(gapX: 10, gapY: 10)

    override func setUp() {
        infoIcon.translatesAutoresizingMaskIntoConstraints = false
        info.addSubview(infoIcon)
        infoIcon.centerIn(info)
        infoIcon.sized(w: 14, h: 14)
        info.sized(w: 26, h: 26)
        info.onTap = { [weak self] in
            guard let self, let screen = self.screen else { return }
            screen.memory.pkInfoOpen.toggle()
            self.note.isHidden = !screen.memory.pkInfoOpen
            screen.refreshHeights()
        }
        let pillsWrap = UIView()
        pillsWrap.translatesAutoresizingMaskIntoConstraints = false
        pillsWrap.addSubview(pills)
        NSLayoutConstraint.activate([
            pills.topAnchor.constraint(equalTo: pillsWrap.topAnchor),
            pills.bottomAnchor.constraint(equalTo: pillsWrap.bottomAnchor),
            pills.trailingAnchor.constraint(equalTo: pillsWrap.trailingAnchor),
            pills.leadingAnchor.constraint(greaterThanOrEqualTo: pillsWrap.leadingAnchor),
        ])
        let head = UIStackView(axis: .horizontal, spacing: 2, alignment: .center, views: [title, info, pillsWrap])
        head.setCustomSpacing(8, after: info)
        title.setContentHuggingPriority(.required, for: .horizontal)
        let noteCol = UIStackView(axis: .vertical, spacing: 8, views: [noteTitle, noteBody])
        note = Paint.boxed(noteCol, insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16), color: nil, radius: 12)
        let col = UIStackView(axis: .vertical, spacing: 10, views: [head, note])
        col.add(tiers, gap: 14)
        contentView.addSubview(col)
        col.pinInCell(contentView, leading: 16, bottom: 24, trailing: 16)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .tiers(let t)? = r.pk, let screen else { return }
        rowKey = r.key
        let rtl = m.rtl
        title.textColor = colors.subtle
        title.setCaps(t.title, spacing: 0.32, rtl: rtl)
        infoIcon.image = Icons.image("info", size: 14)
        infoIcon.tintColor = colors.subtle.alpha(0.7)
        info.accessibilityLabel = t.infoTitle
        note.rounded(colors.surface, radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.1))
        noteTitle.textColor = colors.accent
        noteTitle.setCaps(t.infoTitle, spacing: 0.18, rtl: rtl)
        noteBody.textColor = colors.muted
        noteBody.setStyled(t.infoBody, lineHeight: 1.25)
        note.isHidden = !screen.memory.pkInfoOpen
        pills.removeAllArranged()
        for p in t.pills {
            let zap = p.icon == "zap"
            let c: UIColor = p.on ? (zap ? colors.accent : colors.muted) : colors.subtle.alpha(0.8)
            let id = p.id
            let b = TapButton { [weak self] in self?.pk("pill:" + id) }
            b.rounded(p.on ? (zap ? colors.accent.alpha(0.15) : colors.ink.alpha(0.08)) : .clear, radius: 14)
            let row = UIStackView(axis: .horizontal, spacing: 5, alignment: .center)
            if let icon = Paint.pkIcon(p.icon) { row.addArrangedSubview(Icons.view(icon, size: 11, tint: c, filled: zap)) }
            let l = makeLabel(size: 10.5, color: c, weight: .bold)
            l.setCaps(p.label, spacing: 0.18, rtl: rtl)
            row.addArrangedSubview(l)
            row.isUserInteractionEnabled = false
            b.addSubview(row)
            row.pinEdges(to: b, insets: UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10))
            b.accessibilityLabel = p.label
            pills.addArrangedSubview(b)
        }
        tiers.maxWidth = innerWidth
        tiers.set(t.tiers.enumerated().map { i, tier in tierView(tier, i, rtl) })
    }

    private func tierView(_ t: PkTier, _ i: Int, _ rtl: Bool) -> UIView {
        let b = TapButton { [weak self] in self?.pk("tier", i: i) }
        if t.on {
            b.rounded(colors.ink.alpha(0.05), radius: 14, stroke: 1, strokeColor: colors.ink.alpha(0.35))
        } else {
            b.rounded(.clear, radius: 14, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        }
        b.alpha = t.dim ? 0.65 : 1
        b.accessibilityLabel = t.label
        let label = makeLabel(size: 12.5, color: t.on ? colors.ink : colors.muted, weight: .bold)
        label.setCaps(t.label, spacing: 0.16, rtl: rtl)
        let st = UIStackView(axis: .horizontal, spacing: 5, alignment: .center)
        if let z = t.zap { st.addArrangedSubview(Icons.view("zap", size: 10, tint: z == "fill" ? colors.accent.alpha(0.8) : colors.muted.alpha(0.7), filled: z == "fill")) }
        st.addArrangedSubview(makeLabel(t.status, size: 12, color: colors.subtle, weight: .bold))
        let texts = UIStackView(axis: .vertical, spacing: 2, alignment: .leading, views: [label, st])
        let row = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [Paint.pkBadge(t.badge, maxH: 56, colors: colors), texts])
        row.isUserInteractionEnabled = false
        b.addSubview(row)
        row.pinEdges(to: b, insets: UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 16))
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        return b
    }
}

/// The drawer's button ("All sources 42", logos, "3 addons") and, open, the addon pills.
final class PkDrawerCell: PickerCell {
    private let toggle = TapButton()
    private let chevron = UIImageView()
    private let lineText = makeLabel(size: 11.5, weight: .bold)
    private let count = makeLabel(size: 11.5, weight: .bold)
    private let logos = UIView()
    private var logosW: NSLayoutConstraint!
    private let addons = makeLabel(size: 11.5, weight: .bold)
    private let pills = FlowView(gapX: 6, gapY: 6)

    override func setUp() {
        toggle.onTap = { [weak self] in self?.pk("drawer") }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.sized(w: 14, h: 14)
        logos.translatesAutoresizingMaskIntoConstraints = false
        logosW = logos.widthAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([logosW, logos.heightAnchor.constraint(equalToConstant: 20)])
        let row = UIStackView(axis: .horizontal, spacing: 10, alignment: .center, views: [chevron, lineText, count, logos, addons])
        row.setCustomSpacing(8, after: logos)
        row.isUserInteractionEnabled = false
        toggle.addSubview(row)
        row.pinEdges(to: toggle, insets: UIEdgeInsets(top: 9, left: 16, bottom: 9, right: 16))
        let col = UIStackView(axis: .vertical, spacing: 14, views: [startAligned(toggle), pills])
        contentView.addSubview(col)
        col.pinInCell(contentView, leading: 16, bottom: 16, trailing: 16)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .drawer(let d)? = r.pk else { return }
        rowKey = r.key
        let rtl = m.rtl
        toggle.rounded(colors.canvas.alpha(0.7), radius: 20, stroke: 1, strokeColor: colors.ink.alpha(0.1))
        chevron.image = Icons.image("chevron_down", size: 14)
        chevron.tintColor = colors.muted
        chevron.transform = d.open ? CGAffineTransform(rotationAngle: .pi) : .identity
        lineText.textColor = colors.muted
        lineText.setCaps(d.label, spacing: 0.22, rtl: rtl)
        count.text = d.count
        count.textColor = colors.subtle.alpha(0.8)
        toggle.accessibilityLabel = d.label + " " + d.count
        logos.removeAllSubviews()
        let shown = Array(d.logos.prefix(5))
        for (i, l) in shown.enumerated() {
            let v = Paint.pkLogo(l, size: 20, ring: 2, colors: colors)
            logos.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: logos.topAnchor),
                v.leadingAnchor.constraint(equalTo: logos.leadingAnchor, constant: CGFloat(i) * 13),
            ])
        }
        logosW.constant = shown.isEmpty ? 0 : 20 + CGFloat(shown.count - 1) * 13
        logos.isHidden = shown.isEmpty
        addons.text = d.addons
        addons.isHidden = d.addons == nil
        addons.textColor = colors.subtle.alpha(0.8)
        pills.maxWidth = innerWidth
        pills.set(d.pills.map { p in
            let id = p.id
            let b = TapButton { [weak self] in self?.pk("filter:" + id) }
            if p.on {
                b.rounded(colors.ink, radius: 16)
            } else {
                b.rounded(colors.surface.alpha(0.5), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            }
            let l = makeLabel(p.label, size: 12, color: p.on ? colors.canvas : colors.muted, weight: .bold)
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            let row = UIStackView(axis: .horizontal, spacing: 6, alignment: .center, views: [l])
            if let c = p.count { row.addArrangedSubview(makeLabel(c, size: 12, color: p.on ? colors.canvas.alpha(0.7) : colors.subtle.alpha(0.8), weight: .bold)) }
            row.isUserInteractionEnabled = false
            b.addSubview(row)
            row.pinEdges(to: b, insets: UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12))
            b.accessibilityLabel = p.label
            return b
        })
        pills.isHidden = !(d.open && d.pills.count > 1)
    }
}

/// One line's part of the box around every source: rounded at the box's ends, edged at the sides.
final class SegmentView: UIView {
    private let shape = CAShapeLayer()
    var first = true { didSet { setNeedsLayout() } }
    var last = true { didSet { setNeedsLayout() } }
    var fill: UIColor = .clear { didSet { shape.fillColor = fill.cgColor } }
    var edge: UIColor = .clear { didSet { shape.strokeColor = edge.cgColor } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        shape.lineWidth = 1
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
        // The edge between two lines is drawn by neither (outside the clip); a divider shows there.
        let top: CGFloat = first ? 0.5 : -2
        let bottom: CGFloat = last ? bounds.height - 0.5 : bounds.height + 2
        let rect = CGRect(x: 0.5, y: top, width: bounds.width - 1, height: bottom - top)
        var corners: UIRectCorner = []
        if first { corners.formUnion([.topLeft, .topRight]) }
        if last { corners.formUnion([.bottomLeft, .bottomRight]) }
        shape.path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: 16, height: 16)).cgPath
    }
}

/// One source in the drawer's box: badges, its name, file, addon and facts, languages, cached, Play.
final class PkStreamCell: PickerCell {
    private let segment = SegmentView()
    private let divider = UIView()
    private let line = TapButton()
    private let badges = UIStackView(axis: .vertical, spacing: 4, alignment: .leading)
    private let title = makeLabel(size: 14, lines: 2)
    private let edition = UIView()
    private let file = makeLabel(size: 11, lines: 2)
    private let addonLogo = UIView()
    private let addon = makeLabel(size: 12, weight: .bold, lines: 2)
    private let meta = FlowView(gapX: 10, gapY: 6)
    private let endIcon = UIImageView()
    private let spinner = Paint.spinner(.gray)
    private let copyBox = UIView()
    private var bottomGap: NSLayoutConstraint!

    override func setUp() {
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(holder)
        holder.translatesAutoresizingMaskIntoConstraints = false
        let b = holder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        b.priority = UILayoutPriority(999)
        bottomGap = b
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: contentView.topAnchor),
            b,
            holder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            holder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
        holder.addSubview(segment)
        segment.pinEdges(to: holder)
        divider.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: holder.topAnchor),
            divider.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 1),
            divider.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -1),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        line.pressScale = 0.99
        line.onTap = { [weak self] in
            guard let self, let i = self.item?.index else { return }
            self.pk("stream", i: i)
        }
        holder.addSubview(line)
        line.pinEdges(to: holder, insets: UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0))

        title.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        file.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addonLogo.translatesAutoresizingMaskIntoConstraints = false
        addonLogo.sized(w: 18, h: 18)
        let addonLine = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [addonLogo, addon])
        meta.middle = true
        let mid = UIStackView(axis: .vertical, spacing: 4, views: [title, edition, file])
        mid.add(addonLine, gap: 6)
        mid.add(meta, gap: 8)
        mid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mid.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let end = UIView()
        end.translatesAutoresizingMaskIntoConstraints = false
        endIcon.translatesAutoresizingMaskIntoConstraints = false
        end.addSubview(endIcon)
        endIcon.centerIn(end)
        endIcon.sized(w: 16, h: 16)
        end.addSubview(spinner)
        spinner.centerIn(end)
        end.sized(w: 32, h: 32)
        copyBox.translatesAutoresizingMaskIntoConstraints = false
        copyBox.sized(w: 32, h: 32)
        let side = PassthroughStack(axis: .vertical, spacing: 6, alignment: .center, views: [end, copyBox])
        let badgeWrap = startAligned(badges, top: 2)
        let row = PassthroughStack(axis: .horizontal, spacing: 12, alignment: .top, views: [badgeWrap, mid, side])
        row.setCustomSpacing(8, after: mid)
        for v in [badgeWrap, mid, end] as [UIView] { v.isUserInteractionEnabled = false }
        line.addSubview(row)
        row.pinEdges(to: line, insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 12))
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .streams(let list)? = r.pk, item.index < list.items.count else { return }
        rowKey = r.key
        let rtl = m.rtl
        let s = list.items[item.index]
        let first = item.index == 0
        let last = item.index == list.items.count - 1
        bottomGap.constant = last ? -20 : 0
        segment.first = first
        segment.last = last
        segment.fill = colors.canvas.alpha(0.8)
        segment.edge = colors.ink.alpha(0.08)
        divider.isHidden = first
        divider.backgroundColor = colors.ink.alpha(0.05)
        line.accessibilityLabel = s.title
        badges.removeAllArranged()
        for b in s.badges { badges.addArrangedSubview(Paint.pkBadge(b, maxH: 40, colors: colors)) }
        badges.superview?.isHidden = s.badges.isEmpty
        title.text = s.title
        title.textColor = colors.ink
        edition.removeAllSubviews()
        if let e = s.edition {
            let v = Paint.pkTag(PkTag(text: e, style: "accent"), colors: colors, rtl: rtl)
            edition.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: edition.topAnchor),
                v.bottomAnchor.constraint(equalTo: edition.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: edition.leadingAnchor),
                v.trailingAnchor.constraint(lessThanOrEqualTo: edition.trailingAnchor),
            ])
        }
        edition.isHidden = s.edition == nil
        file.text = s.file
        file.isHidden = s.file == nil
        file.textColor = colors.subtle.alpha(0.75)
        addonLogo.removeAllSubviews()
        let lg = Paint.pkLogo(s.logo, size: 18, colors: colors)
        addonLogo.addSubview(lg)
        lg.pinEdges(to: addonLogo)
        addon.textColor = colors.subtle
        addon.setCaps(s.addon + (s.summary.map { "  ·  " + $0 } ?? ""), spacing: 0.14, rtl: rtl)
        var mv: [UIView] = []
        if let t = s.match { mv.append(Paint.pkTag(t, colors: colors, rtl: rtl)) }
        if !s.flags.isEmpty {
            let fl = UIStackView(axis: .horizontal, spacing: 4, alignment: .center)
            for f in s.flags { fl.addArrangedSubview(Paint.pkFlag(f, big: false, named: false, colors: colors, rtl: rtl)) }
            if s.moreFlags > 0 { fl.addArrangedSubview(makeLabel("+\(s.moreFlags)", size: 10, color: colors.subtle, weight: .bold)) }
            mv.append(fl)
        }
        if let st = s.status { mv.append(Paint.pkStatus(st, size: 12, spacing: 0.14, colors: colors, rtl: rtl)) }
        meta.maxWidth = innerWidth - 28 - 12 - 8 - 32 - (s.badges.isEmpty ? 0 : 56)
        meta.set(mv)
        meta.isHidden = mv.isEmpty
        let busy = s.end == "busy"
        spinner.isHidden = !busy
        spinner.color = colors.muted
        endIcon.isHidden = busy
        endIcon.image = Icons.image(s.end == "external" ? "external_link" : "play", size: 16)
        endIcon.tintColor = colors.muted.alpha(0.6)
        endIcon.transform = rtl && s.end != "external" ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        line.isEnabled = !busy
        line.alpha = busy ? 0.6 : 1
        copyBox.removeAllSubviews()
        if let url = s.copy {
            let b = copyButton(url, size: 30)
            copyBox.addSubview(b)
            b.centerIn(copyBox)
        }
        copyBox.isHidden = s.copy == nil
    }
}

/// "12 cached · 40 found across 3 sources" and, open, each source's count.
final class PkDiagCell: PickerCell {
    private let head = TapButton()
    private let lead = makeLabel(size: 12, weight: .bold)
    private let lineText = makeLabel(size: 12, lines: 2)
    private let chevron = UIImageView()
    private let more = makeLabel(size: 11, lines: 0)

    override func setUp() {
        head.pressScale = 1
        head.onTap = { [weak self] in self?.pk("diag") }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.sized(w: 13, h: 13)
        lead.setContentHuggingPriority(.required, for: .horizontal)
        lead.setContentCompressionResistancePriority(.required, for: .horizontal)
        lineText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lineText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [lead, lineText, chevron])
        row.isUserInteractionEnabled = false
        head.addSubview(row)
        row.pinEdges(to: head, insets: UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        let col = UIStackView(axis: .vertical, spacing: 6, views: [head, padded(more, leading: 4)])
        contentView.addSubview(col)
        col.pinInCell(contentView, leading: 16, bottom: 18, trailing: 16)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .diag(let d)? = r.pk else { return }
        rowKey = r.key
        lead.text = d.lead
        lead.textColor = colors.muted
        lineText.text = "·  " + d.text
        lineText.textColor = colors.subtle.alpha(0.8)
        chevron.image = Icons.image("chevron_down", size: 13)
        chevron.tintColor = colors.subtle.alpha(0.8)
        chevron.transform = d.open ? CGAffineTransform(rotationAngle: .pi) : .identity
        more.textColor = colors.subtle.alpha(0.7)
        more.setStyled(d.more.joined(separator: "  ·  "), lineHeight: 1.3)
        more.superview?.isHidden = !(d.open && !d.more.isEmpty)
    }
}

/// A box with a dashed outline of any corner radius.
final class DashedOutline: UIView {
    private let dash = CAShapeLayer()
    var radius: CGFloat = 16 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        dash.fillColor = UIColor.clear.cgColor
        dash.lineWidth = 1
        dash.lineDashPattern = [6, 4]
        layer.addSublayer(dash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var color: UIColor = .gray { didSet { dash.strokeColor = color.cgColor } }

    override func layoutSubviews() {
        super.layoutSubviews()
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius).cgPath
    }
}

/// A message in a box (see PkPanel); its button sends {a:"pk", what:"panel"}.
final class PkPanelCell: PickerCell {
    private let frameBox = UIView()
    private let art = NetImageView()
    private let shade = ShadeView()
    private let dashed = DashedOutline()
    private let col = UIStackView(axis: .vertical, alignment: .center)
    private var insets: [NSLayoutConstraint] = []
    private let kicker = makeLabel(size: 10.5, weight: .bold, lines: 0)
    private let title = makeLabel(size: 28, lines: 0)
    private let body = makeLabel(size: 14, lines: 0)
    private let pills = FlowView(gapX: 8, gapY: 8)
    private let mono = makeLabel(size: 10.5, lines: 0)
    private let button = UIView()
    private let note = makeLabel(size: 11, weight: .bold, lines: 0)

    override func setUp() {
        frameBox.translatesAutoresizingMaskIntoConstraints = false
        frameBox.clipsToBounds = true
        contentView.addSubview(frameBox)
        frameBox.pinInCell(contentView, leading: 16, bottom: 20, trailing: 16)
        art.alpha = 0.25
        for v in [art, shade, dashed] as [UIView] {
            v.isUserInteractionEnabled = false
            frameBox.addSubview(v)
            v.pinEdges(to: frameBox)
        }
        mono.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        col.addArrangedSubview(kicker)
        col.addArrangedSubview(title)
        col.addArrangedSubview(body)
        col.addArrangedSubview(pills)
        col.addArrangedSubview(mono)
        col.addArrangedSubview(button)
        col.addArrangedSubview(note)
        for v in [kicker, title, body, pills, mono, note] as [UIView] {
            v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        frameBox.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        insets = [
            col.topAnchor.constraint(equalTo: frameBox.topAnchor, constant: 40),
            col.leadingAnchor.constraint(equalTo: frameBox.leadingAnchor, constant: 26),
            frameBox.trailingAnchor.constraint(equalTo: col.trailingAnchor, constant: 26),
            frameBox.bottomAnchor.constraint(equalTo: col.bottomAnchor, constant: 40),
        ]
        NSLayoutConstraint.activate(insets)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .panel(let p)? = r.pk else { return }
        rowKey = r.key
        let rtl = m.rtl
        let warn = p.look == "warn"
        let isDashed = p.look == "dashed"
        let plain = p.look == "plain"
        let center = !warn
        let radius: CGFloat = warn || isDashed ? 16 : 24
        dashed.isHidden = !isDashed
        dashed.radius = radius
        dashed.color = colors.ink.alpha(0.16)
        if plain {
            frameBox.rounded(nil, radius: 0)
        } else if warn {
            frameBox.rounded(Palette.amber300.alpha(0.06), radius: radius, stroke: 1, strokeColor: Palette.amber300.alpha(0.3))
        } else if isDashed {
            frameBox.rounded(colors.canvas.alpha(0.7), radius: radius)
        } else {
            frameBox.rounded(colors.canvas.alpha(p.look == "art" ? 0.6 : 0.8), radius: radius, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        }
        let showArt = p.look == "art" && !p.art.isEmpty
        art.isHidden = !showArt
        shade.isHidden = !showArt
        if showArt {
            ImageLoader.shared.load(art, urls: p.art, size: CGSize(width: innerWidth, height: 360))
            shade.colors = [colors.canvas.alpha(0.6), colors.canvas.alpha(0.8), colors.canvas]
        } else {
            ImageLoader.shared.clear(art)
        }
        let pad: (CGFloat, CGFloat)
        if plain { pad = (4, 16) } else if warn { pad = (14, 20) } else if isDashed { pad = (44, 24) } else if p.look == "art" { pad = (52, 28) } else { pad = (40, 26) }
        insets[0].constant = pad.0
        insets[1].constant = pad.1
        insets[2].constant = pad.1
        insets[3].constant = plain ? 8 : warn ? 16 : pad.0
        col.alignment = center ? .center : .leading
        for l in [kicker, title, body, mono, note] { l.textAlignment = center ? .center : .natural }

        kicker.isHidden = p.kicker == nil
        kicker.textColor = colors.subtle
        if let k = p.kicker { kicker.setCaps(k, spacing: 0.42, rtl: rtl) }
        title.isHidden = p.title == nil
        if warn {
            title.font = Fonts.bold(13)
            title.textColor = Palette.amber200
            title.setStyled(p.title ?? "")
        } else {
            title.font = Fonts.display(p.titleSize)
            title.textColor = colors.ink
            title.setStyled(p.title ?? "", lineHeight: 1.05)
        }
        col.setCustomSpacing(p.kicker == nil ? 0 : 16, after: kicker)
        body.isHidden = p.body == nil
        body.font = Fonts.body(plain ? 11.5 : warn ? 12.5 : isDashed ? 14 : 13.5)
        body.textColor = plain ? colors.subtle : colors.muted
        body.setStyled(p.body ?? "", lineHeight: 1.35)
        col.setCustomSpacing(p.title == nil && p.kicker == nil ? 0 : (warn ? 2 : 16), after: title)
        col.setCustomSpacing(16, after: body)
        pills.centerLines = center
        pills.maxWidth = innerWidth - 2 * pad.1
        pills.set(p.pills.map { t in
            let l = PadLabel(t, size: 12, color: colors.muted, weight: .bold, insets: UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))
            l.rounded(colors.canvas.alpha(0.6), radius: 14, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            l.clipsToBounds = true
            return l
        })
        pills.isHidden = p.pills.isEmpty
        col.setCustomSpacing(16, after: pills)
        mono.isHidden = p.mono == nil
        mono.textColor = colors.subtle.alpha(0.7)
        if let t = p.mono { mono.setCaps(t, spacing: 0.18, rtl: rtl) }
        col.setCustomSpacing(warn ? 12 : 20, after: mono)
        button.removeAllSubviews()
        if let b = p.button {
            let h: CGFloat = b.style == "amber" ? 36 : b.style == "outline" ? 44 : isDashed ? 40 : 48
            let v = Paint.pkButton(b, height: h, radius: isDashed ? 12 : h / 2, colors: colors, rtl: rtl) { [weak self] in self?.pk("panel") }
            button.addSubview(v)
            v.pinEdges(to: button)
        }
        button.isHidden = p.button == nil
        col.setCustomSpacing(18, after: button)
        note.isHidden = p.note == nil
        note.textColor = colors.subtle
        if let n = p.note { note.setCaps(n, spacing: 0.32, rtl: rtl) }
        // Whatever is hidden above, the button keeps its room from the text.
        if p.mono == nil {
            let before = [pills, body, title, kicker].first { !$0.isHidden }
            if let before { col.setCustomSpacing(warn ? 12 : 20, after: before) }
        }
    }
}

/// Searching: the title's logo (or name) breathing, and the caption under it.
final class PkLoaderCell: PickerCell {
    private let col = UIStackView(axis: .vertical, spacing: 0, alignment: .center)
    private let logo = NetImageView()
    private var logoW: NSLayoutConstraint!
    private let name = makeLabel(size: 40, lines: 3, display: true)
    private let caption = makeLabel(size: 11, weight: .bold, lines: 2)

    override func setUp() {
        logo.contentMode = .scaleAspectFit
        logoW = logo.sized(w: 260, h: 150).w
        name.textAlignment = .center
        caption.textAlignment = .center
        col.addArrangedSubview(logo)
        col.addArrangedSubview(name)
        col.setCustomSpacing(32, after: name)
        col.setCustomSpacing(32, after: logo)
        col.addArrangedSubview(caption)
        name.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        caption.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        contentView.addSubview(col)
        col.pinInCell(contentView, top: 72, leading: 16, bottom: 80, trailing: 16)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        col.layer.removeAllAnimations()
        col.alpha = 1
        guard window != nil else { return }
        UIView.animate(withDuration: 1.1, delay: 0, options: [.autoreverse, .repeat, .allowUserInteraction], animations: { self.col.alpha = 0.55 })
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row, case .loader(let l)? = r.pk else { return }
        rowKey = r.key
        let lw = floor(metrics.width * 0.7)
        logoW?.constant = lw
        name.text = l.text
        name.textColor = colors.ink
        if l.logo.isEmpty {
            ImageLoader.shared.clear(logo)
            logo.isHidden = true
            name.isHidden = false
        } else {
            logo.isHidden = false
            name.isHidden = true
            ImageLoader.shared.load(logo, urls: l.logo, size: CGSize(width: lw, height: 150)) { [weak self] ok in
                self?.logo.isHidden = !ok
                self?.name.isHidden = ok
            }
        }
        caption.textColor = colors.subtle
        caption.setCaps(l.caption, spacing: 0.42, rtl: m.rtl)
    }
}
