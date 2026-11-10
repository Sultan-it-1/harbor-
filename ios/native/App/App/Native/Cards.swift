import UIKit

/// A stack that lets touches through where it has nothing of its own (buttons in it still work).
final class PassthroughStack: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The looks a card can have (Android: C_POSTER … C_LEAD). Live TV's cards come with its phase.
enum CardKind: String, CaseIterable {
    case poster, rank, cw, tile, logo, feature, lead

    init(_ k: HomeRow.Kind) {
        switch k {
        case .cw: self = .cw
        case .rank: self = .rank
        case .tile: self = .tile
        case .logo: self = .logo
        case .feature: self = .feature
        default: self = .poster
        }
    }

    /// The title is under the picture (not on it).
    var titleBelow: Bool { self == .poster || self == .rank || self == .cw }

    /// How wide in a sideways row.
    func width(_ m: Metrics) -> CGFloat {
        switch self {
        case .cw: return m.cw
        case .rank: return m.rank
        case .tile: return m.tile
        case .logo: return m.logo
        case .feature: return m.feature
        case .lead: return 280
        case .poster: return m.poster
        }
    }

    /// The picture's height for [w].
    func boxHeight(_ w: CGFloat, row: HomeRow) -> CGFloat {
        switch self {
        case .cw: return floor(w * 9 / 16)
        case .lead: return 216
        case .tile: return row.ratio > 0 ? floor(w * row.ratio) : floor(w * 4 / 5)
        case .logo: return 80
        case .feature: return Swift.max(Swift.min(floor(w * 10 / 16), 440), 300)
        case .poster, .rank: return floor(w * 3 / 2)
        }
    }

    /// What goes under the picture (the title), for a card [w] wide in [row].
    func extraHeight(_ w: CGFloat, row: HomeRow) -> CGFloat {
        let line13 = ceil(Fonts.body(13).lineHeight)
        switch self {
        case .poster:
            let sub = row.items.contains { !($0.sub ?? "").isEmpty } ? 2 + ceil(Fonts.body(12).lineHeight) : 0
            return 8 + 2 * line13 + sub
        case .rank:
            return 8 + Swift.max(2 * line13, ceil(CardView.rankFont(w).lineHeight))
        case .cw:
            return 8 + line13
        default:
            return 0
        }
    }
}

/**
 * One card, as the page draws it (Android: CardHolder): a poster (rating badge, watched check,
 * a small pill), a Top 10 poster with its number, Continue Watching (how far in, Play), a tile with
 * its name on it, a logo, the wide feature card or a spotlight on a person.
 * A tap sends {a:"open"}, a long press {a:"hold"}, Play {a:"play"} (with the row and the card).
 */
final class CardView: TapButton {
    let kind: CardKind
    weak var screen: NativeScreen?
    private(set) var row: HomeRow?
    /// The card's place in its row's items (-1: the row's lead card).
    private var index = -1

    private let col = UIStackView(axis: .vertical, alignment: .leading)
    let box = UIView()
    let image = NetImageView()
    private let boxFill = ShadeView()
    private let shade = ShadeView()
    private var bw: NSLayoutConstraint!
    private var bh: NSLayoutConstraint!
    private var imageInsets: [NSLayoutConstraint] = []
    private var imageH: NSLayoutConstraint!

    private let title: UILabel
    private let posterSub = makeLabel(size: 12)
    private let rankNumber = makeLabel(size: 32, weight: .bold)
    private let rankLine = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)
    private let check = UIView()
    private let badge = UIView()
    private var badgeTop: NSLayoutConstraint!
    private var badgeBottom: NSLayoutConstraint!
    private let kicker = PadLabel(size: 10, weight: .bold)
    private let sub = PadLabel(size: 11, insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
    private let track = UIView()
    private let bar = UIView()
    private var barW: NSLayoutConstraint!
    private let play = TapButton()
    private let overlay = PassthroughStack(axis: .vertical)
    private let bigTitle: UILabel
    private let bigSub: UILabel
    private let stats = UIStackView(axis: .horizontal, spacing: 0, alignment: .center)
    private let featurePlay = TapButton()
    private let featurePlayText = makeLabel(size: 14, weight: .bold)
    private let featurePlayIcon = UIImageView()

    static func rankFont(_ w: CGFloat) -> UIFont {
        let size = Swift.min(Swift.max(w * 0.3, 26), 48)
        if #available(iOS 16.0, *) { return UIFont.systemFont(ofSize: size, weight: .heavy, width: .condensed) }
        return UIFont.systemFont(ofSize: size, weight: .heavy)
    }

    init(kind: CardKind) {
        self.kind = kind
        title = makeLabel(size: 13, lines: kind == .cw ? 1 : 2)
        bigTitle = makeLabel(size: kind == .feature ? 24 : kind == .lead ? 26 : 17, lines: 2, display: true)
        bigSub = makeLabel(size: kind == .feature ? 13.5 : 11.5, lines: kind == .feature ? 3 : 1)
        super.init(onTap: nil)
        pressScale = 0.97
        onTap = { [weak self] in self?.tap("open") }
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        addGestureRecognizer(hold)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { tap("hold") }
    }

    private func build() {
        col.isUserInteractionEnabled = false
        addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer.cornerRadius = 12
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        bw = box.widthAnchor.constraint(equalToConstant: 100)
        bh = box.heightAnchor.constraint(equalToConstant: 150)
        NSLayoutConstraint.activate([bw, bh])
        col.addArrangedSubview(box)

        boxFill.isHidden = true
        (boxFill.layer as? CAGradientLayer)?.startPoint = CGPoint(x: 0, y: 0)
        (boxFill.layer as? CAGradientLayer)?.endPoint = CGPoint(x: 1, y: 1)
        box.addSubview(boxFill)
        boxFill.pinEdges(to: box)

        box.addSubview(image)
        image.translatesAutoresizingMaskIntoConstraints = false
        imageInsets = [
            image.topAnchor.constraint(equalTo: box.topAnchor),
            image.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: image.trailingAnchor),
        ]
        imageH = image.heightAnchor.constraint(equalToConstant: 150)
        NSLayoutConstraint.activate(imageInsets + [imageH])

        switch kind {
        case .cw:
            box.addSubview(shade)
            shade.pinEdges(to: box)
            box.addSubview(sub)
            track.translatesAutoresizingMaskIntoConstraints = false
            bar.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(bar)
            box.addSubview(track)
            barW = bar.widthAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                sub.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
                sub.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
                track.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                track.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                track.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                track.heightAnchor.constraint(equalToConstant: 3),
                bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                bar.topAnchor.constraint(equalTo: track.topAnchor),
                bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                barW,
            ])
            play.onTap = { [weak self] in self?.tap("play") }
            let ic = UIImageView(image: Icons.image("play", size: 20))
            ic.translatesAutoresizingMaskIntoConstraints = false
            play.addSubview(ic)
            ic.centerIn(play)
            addSubview(play)
            NSLayoutConstraint.activate([
                play.widthAnchor.constraint(equalToConstant: 48),
                play.heightAnchor.constraint(equalToConstant: 48),
                play.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                play.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
        case .lead:
            // A spotlight on a person (a genre page): the photo, a small label over the name.
            box.addSubview(shade)
            shade.pinEdges(to: box)
            bigSub.font = Fonts.bold(11)
            overlay.spacing = 4
            overlay.addArrangedSubview(bigSub)
            overlay.addArrangedSubview(bigTitle)
            overlay.isLayoutMarginsRelativeArrangement = true
            overlay.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16)
            box.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            shadow(bigTitle, radius: 10, alpha: 0.4)
        case .tile, .feature:
            box.addSubview(shade)
            shade.pinEdges(to: box)
            let pad: CGFloat = kind == .feature ? 18 : 14
            overlay.spacing = 6
            overlay.alignment = .leading
            overlay.isLayoutMarginsRelativeArrangement = true
            overlay.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: pad, bottom: kind == .feature ? 16 : 12, trailing: pad)
            overlay.addArrangedSubview(bigTitle)
            if kind == .feature { overlay.addArrangedSubview(stats) }
            overlay.addArrangedSubview(bigSub)
            shadow(bigTitle, radius: 10, alpha: 0.6)
            NSLayoutConstraint.activate([
                bigTitle.widthAnchor.constraint(lessThanOrEqualTo: overlay.layoutMarginsGuide.widthAnchor),
                bigSub.widthAnchor.constraint(lessThanOrEqualTo: overlay.layoutMarginsGuide.widthAnchor),
            ])
            kicker.isHidden = true
            box.addSubview(kicker)
            if kind == .feature {
                kicker.insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
                kicker.font = Fonts.bold(11.5)
                NSLayoutConstraint.activate([
                    kicker.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                    kicker.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
                ])
                featurePlay.onTap = { [weak self] in self?.tap("play") }
                featurePlayIcon.translatesAutoresizingMaskIntoConstraints = false
                let pr = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [featurePlayIcon, featurePlayText])
                pr.isUserInteractionEnabled = false
                featurePlay.addSubview(pr)
                NSLayoutConstraint.activate([
                    featurePlayIcon.widthAnchor.constraint(equalToConstant: 16),
                    featurePlayIcon.heightAnchor.constraint(equalToConstant: 16),
                    featurePlay.heightAnchor.constraint(equalToConstant: 42),
                    pr.centerYAnchor.constraint(equalTo: featurePlay.centerYAnchor),
                    pr.leadingAnchor.constraint(equalTo: featurePlay.leadingAnchor, constant: 18),
                    pr.trailingAnchor.constraint(equalTo: featurePlay.trailingAnchor, constant: -20),
                ])
                overlay.add(featurePlay, gap: 14)
                // The play button takes taps: the text over the picture sits on the card itself.
                addSubview(overlay)
            } else {
                // A collection's "7 FILMS" pill in its corner.
                kicker.insets = UIEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
                NSLayoutConstraint.activate([
                    kicker.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
                    kicker.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
                ])
                box.addSubview(overlay)
            }
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
        case .logo:
            bigTitle.textAlignment = .center
            box.addSubview(bigTitle)
            NSLayoutConstraint.activate([
                bigTitle.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                bigTitle.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                bigTitle.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            ])
        case .poster, .rank:
            badge.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(badge)
            badgeTop = badge.topAnchor.constraint(equalTo: box.topAnchor, constant: 6)
            badgeBottom = badge.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6)
            NSLayoutConstraint.activate([badge.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6), badgeBottom])
            if kind == .poster {
                // A small pill in the top corner (an award's "3×" on a winner's photo).
                kicker.insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
                kicker.isHidden = true
                box.addSubview(kicker)
                NSLayoutConstraint.activate([
                    kicker.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                    kicker.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
                ])
            }
            // The watched check, bottom-start like the page's posters.
            check.isHidden = true
            check.translatesAutoresizingMaskIntoConstraints = false
            check.layer.cornerRadius = 11
            check.layer.borderWidth = 2
            let ic = UIImageView(image: Icons.image("check", size: 13, weight: 3))
            ic.translatesAutoresizingMaskIntoConstraints = false
            ic.tag = 1
            check.addSubview(ic)
            ic.centerIn(check)
            box.addSubview(check)
            NSLayoutConstraint.activate([
                check.widthAnchor.constraint(equalToConstant: 22),
                check.heightAnchor.constraint(equalToConstant: 22),
                check.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
                check.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            ])
        }

        if kind == .rank {
            // Top 10: the whole poster clear; under it the number, big and bold in the accent
            // colour, the title beside it.
            rankLine.addArrangedSubview(rankNumber)
            rankLine.addArrangedSubview(title)
            rankNumber.setContentHuggingPriority(.required, for: .horizontal)
            rankNumber.setContentCompressionResistancePriority(.required, for: .horizontal)
            col.add(rankLine, gap: 8)
            rankLine.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        } else if kind.titleBelow {
            col.add(title, gap: 8)
            title.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
            if kind == .poster {
                posterSub.isHidden = true
                col.setCustomSpacing(2, after: title)
                col.addArrangedSubview(posterSub)
                posterSub.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
            }
        }
    }

    private func shadow(_ l: UILabel, radius: CGFloat, alpha: Float) {
        l.layer.shadowColor = UIColor.black.cgColor
        l.layer.shadowOpacity = alpha
        l.layer.shadowRadius = radius / 2
        l.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    /// Lets go of the picture (the card is reused for another).
    func clear() {
        ImageLoader.shared.clear(image)
        Paint.uncrop(image)
    }

    private func tap(_ what: String) {
        guard let r = row, let screen else { return }
        if index < 0 {
            if what == "open" { screen.act("lead", row: r.key) }
            return
        }
        // A title's stills: full screen, here.
        if r.gallery {
            if what == "open" { screen.overlays.showStills(r.items.compactMap { $0.images.first }, start: index) }
            return
        }
        screen.act(what, row: r.key, i: index)
    }

    /// Shows [c] of [r] ([i]: its place in the row's items, -1 for the lead), [w] wide.
    func bind(row r: HomeRow, card c: HomeCard, index i: Int, width w: CGFloat, screen s: NativeScreen) {
        row = r
        index = i
        screen = s
        let colors = s.colors
        let rtl = s.rtl
        let h = kind.boxHeight(w, row: r)
        bw.constant = w
        bh.constant = h
        accessibilityLabel = c.title
        if kind == .rank { rankNumber.font = CardView.rankFont(w) }

        // The picture's plate (an award: its colour lit from the top corner, deep at the bottom).
        boxFill.isHidden = true
        if kind == .tile && c.emblem, let tint = c.tint {
            boxFill.isHidden = false
            boxFill.colors = [tint, Paint.toward(tint, .black, 0.6)]
            box.backgroundColor = .clear
        } else if kind == .lead {
            boxFill.isHidden = false
            boxFill.colors = [colors.surface, colors.canvas]
            box.backgroundColor = .clear
        } else if kind == .logo {
            box.backgroundColor = colors.surface.alpha(0.9)
        } else if kind == .poster && c.kicker != nil {
            box.backgroundColor = Paint.plate(c.title)
        } else {
            box.backgroundColor = c.tint ?? Paint.plate(c.title)
        }

        // Award tiles: the emblem whole in the top part; logos: inside a margin; the rest fills.
        var pad: CGFloat = 0
        var imgH = h
        if kind == .tile && c.emblem {
            pad = 14
            imgH = floor(h * 0.66) - 14
            image.contentMode = .scaleAspectFit
        } else if kind == .logo {
            pad = 22
            imgH = h - 44
            image.contentMode = .scaleAspectFit
        } else {
            Paint.uncrop(image)
        }
        imageInsets[0].constant = pad
        imageInsets[1].constant = pad
        imageInsets[2].constant = pad
        imageH.constant = imgH
        let lead = kind == .lead
        ImageLoader.shared.load(image, urls: c.images, size: CGSize(width: w, height: h)) { [weak self] ok in
            guard let self else { return }
            // A logo that didn't come: its name instead.
            if self.kind == .logo { self.bigTitle.isHidden = ok }
            // A face: framed from its upper part (the page's "center 22%").
            if lead && ok { Paint.crop(self.image, size: CGSize(width: w, height: h), fy: 0.22) }
        }

        title.text = c.title
        title.textColor = colors.ink
        if kind == .poster {
            posterSub.text = c.sub
            posterSub.isHidden = (c.sub ?? "").isEmpty
            posterSub.textColor = colors.muted
        }
        if kind == .poster || kind == .rank {
            check.isHidden = !c.watched
            if c.watched {
                check.backgroundColor = colors.accent
                check.layer.borderColor = colors.canvas.alpha(0.7).cgColor
                check.viewWithTag(1)?.tintColor = colors.canvas
                check.accessibilityLabel = s.model?.label("watched", "Watched")
            }
        }

        switch kind {
        case .cw:
            shade.fromBottom([colors.canvas.alpha(0.8), .clear])
            sub.text = c.sub
            sub.isHidden = (c.sub ?? "").isEmpty
            sub.textColor = colors.ink
            sub.rounded(colors.canvas.alpha(0.95), radius: 6)
            sub.clipsToBounds = true
            track.backgroundColor = colors.canvas.alpha(0.4)
            bar.backgroundColor = colors.accent
            barW.constant = floor(w * c.progress)
            play.rounded(colors.canvas.alpha(0.85), radius: 24, stroke: 1, strokeColor: colors.ink.alpha(0.15))
            play.accessibilityLabel = s.model?.label("play", "Play")
            play.subviews.first?.tintColor = colors.ink
        case .rank:
            rankNumber.text = c.rank > 0 ? String(c.rank) : ""
            rankNumber.textColor = colors.accent
        case .lead:
            shade.fromBottom([colors.canvas, colors.canvas.alpha(0.65), .clear, .clear])
            bigSub.textColor = colors.accent
            bigSub.setCaps(c.sub ?? "", spacing: 0.22, rtl: rtl)
            bigSub.isHidden = (c.sub ?? "").isEmpty
            bigTitle.text = c.title
            bigTitle.textColor = colors.ink
        case .tile, .feature:
            // Tiles: the picture washed with the tile's colour (more at the bottom, under the
            // name); an emblem stays clear. The feature card: like the hero, dark under its text.
            let base = c.tint ?? colors.canvas
            if kind == .feature {
                shade.fromBottom([colors.canvas, colors.canvas.alpha(0.85), colors.canvas.alpha(0.25), .clear])
            } else if c.emblem {
                shade.fromBottom([Paint.toward(base, .black, 0.6).alpha(0.7), .clear])
            } else {
                shade.fromBottom([base.alpha(0.95), base.alpha(0.6), base.alpha(0.45)])
            }
            bigTitle.text = c.title
            bigTitle.textColor = .white
            bigSub.text = c.sub
            bigSub.isHidden = (c.sub ?? "").isEmpty
            bigSub.textColor = UIColor.white.alpha(0.75)
            if kind == .tile {
                kicker.font = Fonts.bold(10)
                kicker.textColor = UIColor.white.alpha(0.85)
                kicker.setCaps(c.kicker ?? "", spacing: 0.16, rtl: rtl)
                kicker.isHidden = (c.kicker ?? "").isEmpty
                kicker.rounded(UIColor.black.alpha(0.4), radius: 12)
                kicker.clipsToBounds = true
            } else {
                kicker.text = c.kicker
                kicker.isHidden = (c.kicker ?? "").isEmpty
                kicker.textColor = colors.ink
                kicker.rounded(colors.canvas.alpha(0.85), radius: 6)
                kicker.clipsToBounds = true
                stats.removeAllArranged()
                if let r = c.rating { stats.addArrangedSubview(Paint.ratingBadge(r, size: 13, colors: colors)) }
                stats.isHidden = stats.arrangedSubviews.isEmpty
                featurePlay.isHidden = !c.play
                featurePlay.rounded(colors.ink, radius: 21)
                featurePlayIcon.image = Icons.image("play", size: 16)
                featurePlayIcon.tintColor = colors.canvas
                featurePlayText.text = s.model?.label("play", "Play")
                featurePlayText.textColor = colors.canvas
            }
        case .logo:
            bigTitle.text = c.title
            bigTitle.textColor = colors.ink
        case .poster:
            kicker.font = Fonts.bold(10)
            kicker.text = c.kicker
            kicker.isHidden = (c.kicker ?? "").isEmpty
            kicker.textColor = colors.canvas
            kicker.rounded(c.tint ?? colors.accent, radius: 10)
            kicker.clipsToBounds = true
        }
        if kind == .poster || kind == .rank {
            // The rating in the poster's corner (bottom, or top per Settings).
            badge.removeAllSubviews()
            if let r = c.rating {
                badge.isHidden = false
                let b = Paint.ratingBadge(r, size: 9.5, colors: colors)
                badge.addSubview(b)
                b.pinEdges(to: badge)
                let top = s.model?.badgesTop == true
                badgeBottom.isActive = !top
                badgeTop.isActive = top
            } else {
                badge.isHidden = true
            }
        }
        setDirection(rtl: rtl)
    }
}

/// A card in a sideways row.
final class CardCell: UICollectionViewCell {
    private(set) var current: CardView?

    /// The card view for [kind] (made the first time, or when the cell changes kind).
    func cardView(_ kind: CardKind) -> CardView {
        if let c = current, c.kind == kind { return c }
        current?.removeFromSuperview()
        let c = CardView(kind: kind)
        contentView.addSubview(c)
        NSLayoutConstraint.activate([
            c.topAnchor.constraint(equalTo: contentView.topAnchor),
            c.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            c.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            c.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        current = c
        return c
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        current?.clear()
    }
}

/// A sideways layout that turns around for right-to-left pages.
final class FlipFlowLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }
}

/// One line of a grid: as many cards across as fit, the same cards as the rows'.
final class GridLineCell: SectionCell {
    private let line = UIStackView(axis: .horizontal, spacing: 16, alignment: .top)
    private var cards: [CardView] = []
    private var bottom: NSLayoutConstraint?

    override func setUp() {
        contentView.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        let b = line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22)
        b.priority = UILayoutPriority(999)
        bottom = b
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: contentView.topAnchor),
            b,
            line.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
        ])
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let row = item.row, let screen else { return }
        let kind: CardKind = item.kind == .gridTile ? .tile : .poster
        bottom?.constant = kind == .poster ? -22 : -16
        let met = metrics
        let cols = met.gridCols(row)
        let w = met.gridWidth(cols)
        if cards.first?.kind != kind {
            for c in cards { c.removeFromSuperview() }
            cards = []
        }
        while cards.count < cols {
            let c = CardView(kind: kind)
            cards.append(c)
            line.addArrangedSubview(c)
        }
        while cards.count > cols {
            let c = cards.removeLast()
            line.removeArrangedSubview(c)
            c.removeFromSuperview()
        }
        let h = kind.boxHeight(w, row: row) + kind.extraHeight(w, row: row)
        for (i, c) in cards.enumerated() {
            let idx = item.index + i
            c.removeConstraints(c.constraints.filter { $0.identifier == "grid" })
            let wc = c.widthAnchor.constraint(equalToConstant: w)
            let hc = c.heightAnchor.constraint(equalToConstant: h)
            wc.identifier = "grid"
            hc.identifier = "grid"
            NSLayoutConstraint.activate([wc, hc])
            if idx < row.items.count {
                c.alpha = 1
                c.isUserInteractionEnabled = true
                c.bind(row: row, card: row.items[idx], index: idx, width: w, screen: screen)
            } else {
                c.alpha = 0
                c.isUserInteractionEnabled = false
                c.clear()
            }
        }
        // Near the end: the next page (once per length, like the rows).
        if row.more && item.index + cols * 4 >= row.items.count && screen.memory.askedMore[row.key] != row.items.count {
            screen.memory.askedMore[row.key] = row.items.count
            act("more", row: row.key)
        }
    }
}
