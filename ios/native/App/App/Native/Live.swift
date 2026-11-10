import UIKit

/// A thin bar showing how far along (a programme, a download), filled from the reading side.
final class BarView: UIView {
    var progress: CGFloat = 0 { didSet { setNeedsLayout() } }
    /// The filled part never shows thinner than this share (a sliver for "just started").
    var minimum: CGFloat = 0 { didSet { setNeedsLayout() } }
    let fill = UIView()

    init(color: UIColor, track: UIColor, radius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        backgroundColor = track
        layer.cornerRadius = radius
        clipsToBounds = true
        fill.backgroundColor = color
        fill.layer.cornerRadius = radius
        addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let p = Swift.min(Swift.max(progress, minimum), 1)
        let w = bounds.width * Swift.max(0, p)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        fill.frame = CGRect(x: rtl ? bounds.width - w : 0, y: 0, width: w, height: bounds.height)
    }
}

/// Room that grows (in a stack), so what follows sits at the end.
func flexSpace() -> UIView {
    let v = UIView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.isUserInteractionEnabled = false
    v.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
    v.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
    v.setContentCompressionResistancePriority(UILayoutPriority(1), for: .vertical)
    v.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
    return v
}

/**
 * Live TV's cards, as the page draws them (Android: LiveFace):
 * - live: a channel now (16:9): the programme's picture (or the channel's logo), "● LIVE", the
 *   number, logo and name, the programme, its bar and the time left;
 * - guide: On now: the logo, "● LIVE", the number and name, the programme and its bar, "Next…";
 * - channel: the channel grid: the title's poster or the logo, "● LIVE", the name, the programme
 *   with the time left and its bar (or the channel's group);
 * - sport: a game's score card.
 * Card fields: title, sub (channel name / programme), kicker (number), images (picture), logo,
 * progress + bar, desc (time left / next / group).
 */
enum LiveFaces {
    static let red = Palette.danger

    /// How tall a channel card is (its top is taller with a poster).
    static func channelHeight(_ c: HomeCard) -> CGFloat {
        let topH: CGFloat = c.images.isEmpty ? 90 : 160
        let l145 = ceil(Fonts.bold(14.5).lineHeight)
        var body = 10 + l145 + 4
        if c.sub != nil {
            body += Swift.max(ceil(Fonts.body(12.5).lineHeight), ceil(Fonts.body(10.5).lineHeight))
            if c.bar { body += 9 }
        } else {
            body += ceil(Fonts.body(12.5).lineHeight)
        }
        return topH + body + 10
    }

    /// "● LIVE": the page's red label (on a dark pill over pictures).
    static func liveLabel(_ size: CGFloat, pill: Bool, colors: HomeColors, model m: HomeModel?) -> UIView {
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = red
        dot.layer.cornerRadius = 3
        dot.sized(w: 6, h: 6)
        let text = makeLabel(size: size, color: red, weight: .bold)
        text.setCaps(m?.label("live", "Live") ?? "Live", spacing: 0.16, rtl: m?.rtl == true)
        let row = UIStackView(axis: .horizontal, spacing: 6, alignment: .center, views: [dot, text])
        guard pill else { return row }
        return Paint.boxed(row, insets: UIEdgeInsets(top: 0, left: 9, bottom: 0, right: 10), color: colors.canvas.alpha(0.9), radius: 11)
    }

    static func bar(_ progress: CGFloat, track: UIColor) -> BarView {
        let b = BarView(color: red, track: track, radius: 2)
        b.progress = progress
        return b
    }

    static func tvIcon(_ size: CGFloat, colors: HomeColors) -> UIView {
        Icons.view("tv", size: size, tint: colors.subtle)
    }

    /// The face for [kind] showing [c], [w] wide.
    static func make(_ kind: CardKind, _ c: HomeCard, width w: CGFloat, colors: HomeColors, model m: HomeModel?) -> UIView {
        let v: UIView
        switch kind {
        case .guide: v = guide(c, w, colors, m)
        case .channel: v = channel(c, w, colors, m)
        case .sport: v = sport(c, w, colors)
        default: v = now(c, w, colors, m)
        }
        v.isUserInteractionEnabled = false
        return v
    }

    private static func now(_ c: HomeCard, _ w: CGFloat, _ colors: HomeColors, _ m: HomeModel?) -> UIView {
        let h = floor(w * 9 / 16)
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.rounded(colors.surface, radius: 8, stroke: 1, strokeColor: colors.ink.alpha(0.07))
        box.clipsToBounds = true
        let logoBox = UIView()
        logoBox.backgroundColor = colors.surface.alpha(0.7)
        logoBox.isHidden = true
        box.addSubview(logoBox)
        logoBox.pinEdges(to: box)
        let bigLogo = NetImageView()
        bigLogo.contentMode = .scaleAspectFit
        logoBox.addSubview(bigLogo)
        bigLogo.centerIn(logoBox)
        bigLogo.sized(w: floor(w * 0.78), h: floor(h * 0.64))
        let art = NetImageView()
        box.addSubview(art)
        art.pinEdges(to: box)
        let showLogo = {
            art.isHidden = true
            logoBox.isHidden = false
            if let l = c.logo {
                ImageLoader.shared.load(bigLogo, urls: [l], size: CGSize(width: w * 0.78, height: h * 0.64)) { ok in
                    if !ok {
                        let ic = tvIcon(34, colors: colors)
                        logoBox.addSubview(ic)
                        ic.centerIn(logoBox)
                    }
                }
            } else {
                let ic = tvIcon(34, colors: colors)
                logoBox.addSubview(ic)
                ic.centerIn(logoBox)
            }
        }
        if c.images.isEmpty {
            showLogo()
        } else {
            ImageLoader.shared.load(art, urls: c.images, size: CGSize(width: w, height: h)) { ok in if !ok { showLogo() } }
        }
        let shade = ShadeView()
        shade.fromBottom([colors.canvas, colors.canvas.alpha(0.35), .clear])
        box.addSubview(shade)
        shade.pinEdges(to: box)
        let live = liveLabel(10.5, pill: true, colors: colors, model: m)
        box.addSubview(live)
        NSLayoutConstraint.activate([
            live.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            live.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            live.heightAnchor.constraint(equalToConstant: 22),
        ])
        let line = UIStackView(axis: .horizontal, spacing: 6, alignment: .center)
        if let k = c.kicker { line.addArrangedSubview(makeLabel(k, size: 11.5, color: colors.subtle)) }
        if !c.images.isEmpty, let l = c.logo {
            let small = LogoView(maxW: 40, maxH: 16)
            line.addArrangedSubview(small)
            small.load([l]) { ok in if !ok { small.isHidden = true } }
        }
        let sub = makeLabel(c.sub ?? "", size: 11.5, color: colors.muted)
        sub.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.addArrangedSubview(sub)
        let bottom = UIStackView(axis: .vertical, spacing: 4, views: [line, makeLabel(c.title, size: 14.5, color: colors.ink, weight: .bold)])
        if c.bar {
            let row = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)
            let b = bar(c.progress, track: colors.canvas.alpha(0.55))
            b.heightAnchor.constraint(equalToConstant: 3).isActive = true
            b.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(b)
            if let d = c.desc {
                let l = makeLabel(d, size: 10.5, color: colors.subtle)
                l.setContentCompressionResistancePriority(.required, for: .horizontal)
                row.addArrangedSubview(l)
            }
            bottom.add(row, gap: 8)
        }
        box.addSubview(bottom)
        NSLayoutConstraint.activate([
            bottom.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            bottom.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
        return box
    }

    private static func guide(_ c: HomeCard, _ w: CGFloat, _ colors: HomeColors, _ m: HomeModel?) -> UIView {
        let col = UIStackView(axis: .vertical, alignment: .fill)
        col.isLayoutMarginsRelativeArrangement = true
        col.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        col.rounded(colors.surface, radius: 8, stroke: 1, strokeColor: colors.ink.alpha(0.07))
        let logoBox = UIView()
        logoBox.translatesAutoresizingMaskIntoConstraints = false
        logoBox.rounded(colors.canvas.alpha(0.6), radius: 4)
        logoBox.sized(w: 48, h: 28)
        if let l = c.logo {
            let lg = NetImageView()
            lg.contentMode = .scaleAspectFit
            logoBox.addSubview(lg)
            lg.centerIn(logoBox)
            lg.sized(w: 40, h: 20)
            ImageLoader.shared.load(lg, urls: [l], size: CGSize(width: 40, height: 20)) { ok in
                if !ok {
                    let ic = tvIcon(14, colors: colors)
                    logoBox.addSubview(ic)
                    ic.centerIn(logoBox)
                }
            }
        } else {
            let ic = tvIcon(14, colors: colors)
            logoBox.addSubview(ic)
            ic.centerIn(logoBox)
        }
        let who = EndLabel([c.kicker, c.sub].compactMap { $0 }.joined(separator: " "), size: 11.5, color: colors.subtle)
        who.setContentHuggingPriority(.defaultLow, for: .horizontal)
        who.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [logoBox, liveLabel(10.5, pill: false, colors: colors, model: m), who])
        col.addArrangedSubview(top)
        let a = flexSpace()
        let b = flexSpace()
        col.addArrangedSubview(a)
        col.addArrangedSubview(makeLabel(c.title, size: 14, color: colors.ink, weight: .bold))
        if c.bar {
            let bv = bar(c.progress, track: colors.canvas.alpha(0.55))
            bv.heightAnchor.constraint(equalToConstant: 3).isActive = true
            col.add(bv, gap: 6)
        }
        col.addArrangedSubview(b)
        col.addArrangedSubview(makeLabel(c.desc ?? "", size: 11.5, color: colors.subtle))
        a.heightAnchor.constraint(equalTo: b.heightAnchor).isActive = true
        return col
    }

    private static func channel(_ c: HomeCard, _ w: CGFloat, _ colors: HomeColors, _ m: HomeModel?) -> UIView {
        let col = UIStackView(axis: .vertical, alignment: .fill)
        col.rounded(colors.surface, radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.07))
        col.clipsToBounds = true
        let poster = !c.images.isEmpty
        let topH: CGFloat = poster ? 160 : 90
        let top = UIView()
        top.translatesAutoresizingMaskIntoConstraints = false
        top.backgroundColor = poster ? colors.canvas : colors.surface.alpha(0.7)
        top.heightAnchor.constraint(equalToConstant: topH).isActive = true
        if poster {
            let img = NetImageView()
            top.addSubview(img)
            img.pinEdges(to: top)
            let shade = ShadeView()
            shade.fromBottom([colors.canvas.alpha(0.85), .clear, .clear])
            top.addSubview(shade)
            shade.pinEdges(to: top)
            ImageLoader.shared.load(img, urls: c.images, size: CGSize(width: w, height: topH))
        } else if let l = c.logo {
            let lg = NetImageView()
            lg.contentMode = .scaleAspectFit
            top.addSubview(lg)
            lg.pinEdges(to: top, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
            ImageLoader.shared.load(lg, urls: [l], size: CGSize(width: w, height: topH)) { ok in
                if !ok {
                    let ic = tvIcon(22, colors: colors)
                    top.addSubview(ic)
                    ic.centerIn(top)
                }
            }
        } else {
            let ic = tvIcon(22, colors: colors)
            top.addSubview(ic)
            ic.centerIn(top)
        }
        let live = liveLabel(10, pill: true, colors: colors, model: m)
        top.addSubview(live)
        NSLayoutConstraint.activate([
            live.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 10),
            live.topAnchor.constraint(equalTo: top.topAnchor, constant: 10),
            live.heightAnchor.constraint(equalToConstant: 20),
        ])
        col.addArrangedSubview(top)
        let body = UIStackView(axis: .vertical, spacing: 4)
        body.isLayoutMarginsRelativeArrangement = true
        body.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        body.addArrangedSubview(makeLabel(c.title, size: 14.5, color: colors.ink, weight: .bold))
        if let sub = c.sub {
            let s = makeLabel(sub, size: 12.5, color: colors.muted)
            s.setContentHuggingPriority(.defaultLow, for: .horizontal)
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(axis: .horizontal, spacing: 8, alignment: .lastBaseline, views: [s])
            if let d = c.desc { row.addArrangedSubview(makeLabel(d, size: 10.5, color: colors.subtle)) }
            body.addArrangedSubview(row)
            if c.bar {
                let b = bar(c.progress, track: colors.canvas.alpha(0.55))
                b.heightAnchor.constraint(equalToConstant: 3).isActive = true
                body.add(b, gap: 6)
            }
        } else {
            body.addArrangedSubview(makeLabel(c.desc ?? "", size: 12.5, color: colors.subtle))
        }
        col.addArrangedSubview(body)
        // Its top part at the top whatever the card's height.
        col.addArrangedSubview(flexSpace())
        return col
    }

    /**
     * A game, as the page's score card: the state (red "● 2nd 12:31" while live, "Final", or the
     * start time) and the league, then each side's logo, short name and score (the loser dimmed).
     * Fields: title / sub = away / home, rating / desc = scores, images / logo = logos, kicker =
     * state text, tone = accent (live) / plain (final), button = league, rank bits = who's dimmed.
     */
    private static func sport(_ c: HomeCard, _ w: CGFloat, _ colors: HomeColors) -> UIView {
        let col = UIStackView(axis: .vertical, alignment: .fill)
        col.isLayoutMarginsRelativeArrangement = true
        col.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        col.rounded(colors.surface, radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.07))
        let state = c.tone == "accent" ? "in" : c.tone == "plain" ? "post" : "pre"
        let stateView: UIView
        if state == "in" {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = .white
            dot.layer.cornerRadius = 3
            dot.sized(w: 6, h: 6)
            let row = UIStackView(axis: .horizontal, spacing: 4, alignment: .center, views: [dot, makeLabel((c.kicker ?? "").uppercased(), size: 10.5, color: .white, weight: .bold)])
            stateView = Paint.boxed(row, insets: UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6), color: red, radius: 4)
            stateView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        } else {
            stateView = makeLabel(state == "post" ? (c.kicker ?? "").uppercased() : c.kicker ?? "", size: 11, color: state == "post" ? colors.muted : colors.subtle, weight: .bold)
        }
        let top = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [stateView, flexSpace(), makeLabel((c.button ?? "").uppercased(), size: 10, color: colors.subtle, weight: .bold)])
        col.addArrangedSubview(top)
        col.addArrangedSubview(flexSpace())
        let active = state == "in" || state == "post"
        let sides: [(String, String?, Bool, String?)] = [
            (c.title, c.rating, (c.rank & 1) != 0, c.images.first),
            (c.sub ?? "", c.desc, (c.rank & 2) != 0, c.logo),
        ]
        for (i, side) in sides.enumerated() {
            let (name, score, dim, logoUrl) = side
            let logo = NetImageView()
            logo.contentMode = .scaleAspectFit
            logo.backgroundColor = colors.canvas.alpha(0.6)
            logo.layer.cornerRadius = 10
            logo.sized(w: 20, h: 20)
            if let u = logoUrl, !u.trimmingCharacters(in: .whitespaces).isEmpty {
                ImageLoader.shared.load(logo, urls: [u], size: CGSize(width: 20, height: 20)) { ok in if ok { logo.backgroundColor = .clear } }
            }
            let n = makeLabel(name.uppercased(), size: 13, color: dim ? colors.subtle : colors.ink, weight: .bold)
            n.setContentHuggingPriority(.defaultLow, for: .horizontal)
            n.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let position = score.map { $0.range(of: "^\\d+(st|nd|rd|th)$", options: .regularExpression) != nil } ?? false
            let s = EndLabel(score ?? "", size: position ? 13 : 20, color: active ? (dim ? colors.muted : colors.ink) : colors.subtle, weight: .bold)
            s.font = Fonts.digits(position ? 13 : 20, .bold)
            if !position { s.widthAnchor.constraint(equalToConstant: 36).isActive = true }
            let line = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [logo, n, s])
            col.add(line, gap: i > 0 ? 2 : 0)
        }
        return col
    }
}

/**
 * Live TV's spotlight (Android: LiveHeroHolder): one channel at a time (every 9 s the next), its
 * programme's picture (or its logo, large), the channel's logo in the corner, the dots, "LIVE" with
 * the time left, the programme in large type, "channel · group", the red bar along the bottom.
 * A tap plays it.
 */
final class LiveHeroCell: SectionCell {
    private let card = TapButton()
    private var row: HomeRow?
    private var idx = 0
    private var key = ""
    private var timer: Timer?
    private static let height: CGFloat = 420

    override func setUp() {
        card.pressScale = 0.99
        card.layer.cornerRadius = 8
        card.clipsToBounds = true
        card.onTap = { [weak self] in
            guard let self, let r = self.row else { return }
            self.act("open", row: r.key, i: self.idx)
        }
        contentView.addSubview(card)
        card.pinInCell(contentView, leading: 16, bottom: 32, trailing: 16)
        card.heightAnchor.constraint(equalToConstant: LiveHeroCell.height).isActive = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        timer = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        } else {
            schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard window != nil, (row?.items.count ?? 0) > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 9, repeats: false) { [weak self] _ in self?.advance() }
    }

    private func advance() {
        guard let r = row, r.items.count > 1 else { return }
        idx = (idx + 1) % r.items.count
        paint(fade: true)
        schedule()
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row else { return }
        let k = r.items.map { ($0.sub ?? "") + $0.title }.joined(separator: "|")
        if k != key {
            if r.items.map({ $0.sub }) != (row?.items.map { $0.sub } ?? []) { idx = 0 }
            key = k
        }
        row = r
        if idx >= r.items.count { idx = 0 }
        paint(fade: false)
        schedule()
    }

    private func paint(fade: Bool) {
        guard let r = row, idx < r.items.count, let m = model else { return }
        let c = r.items[idx]
        let rtl = m.rtl
        let w = metrics.width - 32
        let h = LiveHeroCell.height
        card.removeAllSubviews()
        card.backgroundColor = colors.canvas
        card.accessibilityLabel = [c.title, c.sub].compactMap { $0 }.joined(separator: " · ")

        let big = NetImageView()
        big.contentMode = .scaleAspectFit
        big.isUserInteractionEnabled = false
        card.addSubview(big)
        big.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            big.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            big.topAnchor.constraint(equalTo: card.topAnchor, constant: floor(h * 0.17)),
            big.widthAnchor.constraint(equalToConstant: floor(w * 0.4)),
            big.heightAnchor.constraint(equalToConstant: floor(h * 0.42)),
        ])
        let art = NetImageView()
        art.isUserInteractionEnabled = false
        card.addSubview(art)
        art.pinEdges(to: card)
        let logoInstead = {
            art.isHidden = true
            if let l = c.logo { ImageLoader.shared.load(big, urls: [l], size: CGSize(width: w * 0.4, height: h * 0.42)) }
        }
        if c.images.isEmpty {
            logoInstead()
        } else {
            ImageLoader.shared.load(art, urls: c.images, size: CGSize(width: w, height: h)) { ok in if !ok { logoInstead() } }
        }
        let up = ShadeView()
        up.fromBottom([colors.canvas, colors.canvas.alpha(0.35), .clear])
        let side = ShadeView()
        side.fromStart([colors.canvas.alpha(0.65), .clear, .clear], rtl: rtl)
        for s in [up, side] {
            card.addSubview(s)
            s.pinEdges(to: card)
        }
        // The channel's logo in the corner.
        if let l = c.logo {
            let lg = NetImageView()
            lg.contentMode = .scaleAspectFit
            lg.sized(w: 92, h: 28)
            let bug = Paint.boxed(lg, insets: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), color: colors.canvas.alpha(0.85), radius: 8)
            bug.isUserInteractionEnabled = false
            card.addSubview(bug)
            NSLayoutConstraint.activate([
                bug.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
                bug.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            ])
            ImageLoader.shared.load(lg, urls: [l], size: CGSize(width: 92, height: 28)) { ok in if !ok { bug.isHidden = true } }
        }
        // The dots (a tap shows that one).
        if r.items.count > 1 {
            let dots = PassthroughStack(axis: .horizontal, spacing: 8, alignment: .center)
            for i in r.items.indices {
                let b = TapButton { [weak self] in
                    guard let self else { return }
                    self.idx = i
                    self.paint(fade: true)
                    self.schedule()
                }
                b.pressScale = 1
                b.isAccessibilityElement = false
                let bar = UIView()
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.isUserInteractionEnabled = false
                bar.backgroundColor = i == idx ? colors.ink : colors.muted.alpha(0.6)
                bar.layer.cornerRadius = 3
                b.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                    bar.leadingAnchor.constraint(equalTo: b.leadingAnchor),
                    bar.trailingAnchor.constraint(equalTo: b.trailingAnchor),
                    bar.heightAnchor.constraint(equalToConstant: 6),
                    b.heightAnchor.constraint(equalToConstant: 24),
                    b.widthAnchor.constraint(equalToConstant: i == idx ? 32 : 16),
                ])
                dots.addArrangedSubview(b)
            }
            card.addSubview(dots)
            NSLayoutConstraint.activate([
                dots.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
                dots.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            ])
        }
        let text = UIStackView(axis: .vertical, spacing: 10, alignment: .leading)
        text.isUserInteractionEnabled = false
        let liveText = PadLabel(size: 11, color: .white, weight: .bold, insets: UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10))
        liveText.setCaps(m.label("live", "Live"), spacing: 0.16, rtl: rtl)
        liveText.textAlignment = .center
        liveText.rounded(LiveFaces.red, radius: 6)
        liveText.clipsToBounds = true
        liveText.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let badges = UIStackView(axis: .horizontal, spacing: 6, alignment: .center, views: [liveText])
        if let d = c.desc {
            badges.setCustomSpacing(12, after: liveText)
            badges.addArrangedSubview(Icons.view("rotate_ccw", size: 14, tint: colors.ink))
            badges.addArrangedSubview(makeLabel(d, size: 13, color: colors.ink, weight: .bold))
        }
        text.addArrangedSubview(badges)
        let title = makeLabel(size: 34, color: colors.ink, lines: 2)
        let serif = Fonts.display(34, .bold)
        title.font = serif
        title.setStyled(c.title, lineHeight: 1.04)
        text.addArrangedSubview(title)
        title.widthAnchor.constraint(lessThanOrEqualToConstant: floor(w * 0.88)).isActive = true
        if let s = c.sub { text.addArrangedSubview(makeLabel(s, size: 14, color: colors.muted, weight: .bold)) }
        card.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            text.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24),
            text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
        ])
        if c.bar {
            let b = BarView(color: LiveFaces.red, track: UIColor.black.alpha(0.35), radius: 0)
            b.progress = c.progress
            card.addSubview(b)
            NSLayoutConstraint.activate([
                b.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                b.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                b.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                b.heightAnchor.constraint(equalToConstant: 5),
            ])
        }
        card.setDirection(rtl: rtl)
        if fade {
            text.alpha = 0
            text.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(withDuration: 0.42) {
                text.alpha = 1
                text.transform = .identity
            }
        }
    }
}

// MARK: - The TV guide

/// The guide's scale: points per millisecond, the channels' column, a row's height.
enum GuideScale {
    static let perMs: CGFloat = 5 / 60_000
    static let column: CGFloat = 124
    static let rowHeight: CGFloat = 76
}

/**
 * The programmes' area of a guide row (or the ruler's): drawn here, scrolled sideways together
 * (the offset is the screen's; every strip redraws when it moves). A tap opens the programme
 * under the finger, or the channel.
 */
final class GuideStripView: UIView, UIGestureRecognizerDelegate {
    let ruler: Bool
    weak var screen: NativeScreen?
    var guide: HomeGuide?
    var row = -1
    private var velocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    init(ruler: Bool) {
        self.ruler = ruler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        contentMode = .redraw
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var rtl: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }
    private var colors: HomeColors { screen?.colors ?? .standard }

    /// Sideways only: a mostly vertical drag scrolls the page.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: self)
        return abs(v.x) > abs(v.y)
    }

    private func scrollBy(_ dx: CGFloat) {
        guard let g = guide, let screen else { return }
        let total = CGFloat(g.end - g.start) * GuideScale.perMs
        let maxX = Swift.max(0, total - bounds.width)
        let next = Swift.min(Swift.max(screen.memory.guideX + dx, 0), maxX)
        guard next != screen.memory.guideX else {
            velocity = 0
            return
        }
        screen.memory.guideX = next
        for s in screen.memory.guideStrips.allObjects { s.setNeedsDisplay() }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let sign: CGFloat = rtl ? 1 : -1
        switch pan.state {
        case .began:
            stopFling()
        case .changed:
            let t = pan.translation(in: self)
            scrollBy(t.x * sign)
            pan.setTranslation(.zero, in: self)
        case .ended:
            velocity = pan.velocity(in: self).x * sign
            startFling()
        default:
            break
        }
    }

    private func startFling() {
        stopFling()
        guard abs(velocity) > 50 else { return }
        lastTick = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopFling() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(now - lastTick)
        lastTick = now
        scrollBy(velocity * dt)
        velocity *= pow(0.135, dt) // about two seconds to stop
        if abs(velocity) < 20 { stopFling() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopFling() }
    }

    @objc private func tapped(_ t: UITapGestureRecognizer) {
        guard let g = guide, !ruler, row >= 0, row < g.channels.count, let screen else { return }
        let p = t.location(in: self)
        let x = screen.memory.guideX + (rtl ? bounds.width - p.x : p.x)
        let at = g.start + Int64(x / GuideScale.perMs)
        let ch = g.channels[row]
        if let pi = ch.programs.firstIndex(where: { at >= $0.s && at < $0.e }) {
            screen.act("guide", i: row, what: "pg", text: String(pi))
        } else {
            screen.act("guide", i: row, what: "ch")
        }
    }

    override func draw(_ rect: CGRect) {
        guard let g = guide, let ctx = UIGraphicsGetCurrentContext() else { return }
        let colors = self.colors
        let gx = screen?.memory.guideX ?? 0
        let w = bounds.width
        let h = bounds.height
        let rtl = self.rtl
        func sx(_ ms: Int64) -> CGFloat {
            let x = CGFloat(ms - g.start) * GuideScale.perMs - gx
            return rtl ? w - x : x
        }
        func drawText(_ s: String, font: UIFont, color: UIColor, x: CGFloat, baseline: CGFloat, alignEnd: Bool = false) {
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (s as NSString).size(withAttributes: a)
            let left = alignEnd ? x - size.width : x
            (s as NSString).draw(at: CGPoint(x: left, y: baseline - font.ascender), withAttributes: a)
        }
        if ruler {
            let font = Fonts.bold(11)
            for t in g.ticks {
                let x = sx(t.at)
                if x < -80 || x > w + 80 { continue }
                ctx.setFillColor(colors.ink.alpha(0.12).cgColor)
                ctx.fill(CGRect(x: x, y: h - 10, width: 1, height: 10))
                drawText(t.label, font: font, color: colors.subtle, x: rtl ? x - 6 : x + 6, baseline: h / 2 + 4, alignEnd: rtl)
            }
        } else if row >= 0 && row < g.channels.count {
            let ch = g.channels[row]
            ctx.setFillColor(colors.ink.alpha(0.05).cgColor)
            ctx.fill(CGRect(x: 0, y: h - 1, width: w, height: 1))
            if ch.programs.isEmpty {
                let s = g.label("none", "No program info")
                drawText(s, font: Fonts.body(11.5), color: colors.subtle, x: rtl ? w - 12 : 12, baseline: h / 2 + 4, alignEnd: rtl)
            }
            for p in ch.programs {
                let a = sx(p.s)
                let b = sx(p.e)
                let l = Swift.min(a, b) + 3
                let r = Swift.max(a, b) - 3
                if r < 0 || l > w || r - l < 4 { continue }
                let past = p.e <= g.now
                let live = !past && p.s <= g.now
                let box = CGRect(x: l, y: 4, width: r - l, height: h - 8)
                let path = UIBezierPath(roundedRect: box, cornerRadius: 8)
                let fill: UIColor = live ? LiveFaces.red.alpha(0.15) : p.replay ? colors.surface.alpha(0.7) : past ? colors.surface.alpha(0.18) : colors.surface.alpha(0.85)
                let edge: UIColor = live ? LiveFaces.red.alpha(0.45) : p.replay ? colors.accent.alpha(0.35) : past ? colors.ink.alpha(0.04) : colors.ink.alpha(0.1)
                fill.setFill()
                path.fill()
                edge.setStroke()
                path.lineWidth = 1
                path.stroke()
                ctx.saveGState()
                path.addClip()
                let bw = r - l
                let pad: CGFloat = 10
                let inner = Swift.max(0, bw - 2 * pad)
                let titleFont = Fonts.bold(bw < 40 ? 11 : 12.5)
                let titleColor: UIColor = past && !p.replay ? colors.muted.alpha(0.6) : past ? colors.muted : colors.ink
                let title = GuideStripView.fit(p.title, font: titleFont, width: inner)
                drawText(title, font: titleFont, color: titleColor, x: rtl ? r - pad : l + pad, baseline: 24, alignEnd: rtl)
                if bw >= 70 {
                    let times = "\(p.from)  \(p.to)"
                    drawText(times, font: Fonts.body(10.5), color: colors.subtle, x: rtl ? r - pad : l + pad, baseline: h - 16, alignEnd: rtl)
                    let badge: String? = live ? g.label("live", "Live") : p.replay ? g.label("replay", "Replay") : past ? g.label("ended", "Ended") : nil
                    if let badge, bw >= 140 {
                        let f = Fonts.bold(8.5)
                        let text = badge.uppercased()
                        let tw = (text as NSString).size(withAttributes: [.font: f]).width + 10
                        let br = rtl ? l + pad + tw : r - pad
                        let pill = CGRect(x: br - tw, y: h - 28, width: tw, height: 14)
                        let pillFill: UIColor = live ? LiveFaces.red.alpha(0.8) : p.replay ? colors.accent.alpha(0.2) : colors.canvas.alpha(0.55)
                        pillFill.setFill()
                        UIBezierPath(roundedRect: pill, cornerRadius: 7).fill()
                        let tc: UIColor = live ? colors.canvas : p.replay ? colors.accent : colors.subtle
                        drawText(text, font: f, color: tc, x: pill.minX + 5, baseline: h - 18)
                    }
                }
                ctx.restoreGState()
            }
        }
        // Now.
        if g.now >= g.start && g.now < g.end {
            ctx.setFillColor(LiveFaces.red.cgColor)
            ctx.fill(CGRect(x: sx(g.now), y: 0, width: 1, height: h))
        }
    }

    /// [s] cut with "…" to fit [width].
    static func fit(_ s: String, font: UIFont, width: CGFloat) -> String {
        let a: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: a).width <= width { return s }
        var chars = Array(s)
        while !chars.isEmpty {
            chars.removeLast()
            let t = String(chars) + "…"
            if (t as NSString).size(withAttributes: a).width <= width { return t }
        }
        return ""
    }
}

/// The guide's top: the day, then the hours.
final class GuideRulerCell: SectionCell {
    private let day = makeLabel(size: 11, weight: .bold)
    private let strip = GuideStripView(ruler: true)

    override func setUp() {
        let dayBox = UIView()
        dayBox.translatesAutoresizingMaskIntoConstraints = false
        dayBox.addSubview(day)
        day.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            day.leadingAnchor.constraint(equalTo: dayBox.leadingAnchor, constant: 12),
            day.trailingAnchor.constraint(equalTo: dayBox.trailingAnchor, constant: -8),
            day.centerYAnchor.constraint(equalTo: dayBox.centerYAnchor),
            dayBox.widthAnchor.constraint(equalToConstant: GuideScale.column),
        ])
        let line = UIStackView(axis: .horizontal, alignment: .fill, views: [dayBox, strip])
        contentView.addSubview(line)
        line.pinInCell(contentView)
        line.heightAnchor.constraint(equalToConstant: 52).isActive = true
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let g = m.guide, let screen else { return }
        contentView.backgroundColor = colors.surface
        day.textColor = colors.subtle
        day.setCaps(g.day, spacing: 0.2, rtl: m.rtl)
        // A new window (or the first): "now" a little in from the start.
        if screen.memory.guideX < 0 || screen.memory.guideKey != g.start {
            screen.memory.guideKey = g.start
            screen.memory.guideX = Swift.max(0, CGFloat(g.now - g.start) * GuideScale.perMs - (metrics.width - GuideScale.column) / 4)
        }
        strip.screen = screen
        strip.guide = g
        screen.memory.guideStrips.add(strip)
        strip.setNeedsDisplay()
    }
}

/// A channel's line: its number, logo and name (a tap plays it), then its programmes.
final class GuideRowCell: SectionCell {
    private let cell = TapButton()
    private let logo = LogoView(maxW: 56, maxH: 22)
    private let number = makeLabel(size: 10.5, weight: .bold)
    private let name = makeLabel(size: 12, weight: .bold, lines: 2)
    private let strip = GuideStripView(ruler: false)
    private var index = -1

    override func setUp() {
        cell.pressScale = 0.98
        cell.onTap = { [weak self] in
            guard let self, self.index >= 0 else { return }
            self.act("guide", i: self.index, what: "ch")
        }
        number.sized(w: 26)
        let texts = UIStackView(axis: .vertical, spacing: 4, alignment: .leading, views: [logo, name])
        name.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let inner = UIStackView(axis: .horizontal, spacing: 0, alignment: .center, views: [number, texts])
        inner.isUserInteractionEnabled = false
        cell.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            inner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cell.widthAnchor.constraint(equalToConstant: GuideScale.column),
        ])
        let line = UIStackView(axis: .horizontal, alignment: .fill, views: [cell, strip])
        contentView.addSubview(line)
        line.pinInCell(contentView)
        line.heightAnchor.constraint(equalToConstant: GuideScale.rowHeight).isActive = true
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let g = m.guide, item.index < g.channels.count, let screen else { return }
        let i = item.index
        let ch = g.channels[i]
        index = i
        cell.backgroundColor = colors.surface
        cell.accessibilityLabel = ch.name
        number.text = ch.number
        number.textColor = colors.subtle
        name.text = ch.name
        name.textColor = colors.ink
        if let l = ch.logo {
            logo.isHidden = false
            logo.load([l]) { [weak self] ok in self?.logo.isHidden = !ok }
        } else {
            ImageLoader.shared.clear(logo)
            logo.isHidden = true
        }
        strip.screen = screen
        strip.guide = g
        strip.row = i
        screen.memory.guideStrips.add(strip)
        strip.setNeedsDisplay()
        // Near the end of the list: the next channels.
        if g.more && i >= g.channels.count - 8 && screen.memory.guideAskedMore != g.channels.count {
            screen.memory.guideAskedMore = g.channels.count
            act("guide", what: "more")
        }
    }
}
