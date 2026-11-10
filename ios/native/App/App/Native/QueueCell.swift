import UIKit

/**
 * The discovery queue, like the page (Android: QueueHolder): a big card for the title up now (its
 * tag, name, year · runtime · IMDb · genres, overview; Play tonight, Save, Skip, Not interested;
 * details at the top), then the queue's pictures in a strip (a tap jumps there, the one up now
 * ringed, those already passed faded). The card turns to the next / previous title with a swipe:
 * forward is toward the reading side's start (to the left; to the right in Arabic).
 */
final class QueueCell: SectionCell, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private static let dark = UIColor(red: 10 / 255, green: 12 / 255, blue: 19 / 255, alpha: 1)

    private let wrap = UIView()
    private let card = UIView()
    private let backdrop = NetImageView()
    private let shadeUp = ShadeView()
    private let shadeSide = ShadeView()
    private let content = UIStackView(axis: .vertical, alignment: .fill)
    private let position = makeLabel(size: 12, weight: .bold)
    private let info = TapButton()
    private let infoIcon = UIImageView()
    private let tags = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)
    private let tagPill = PadLabel(size: 11.5, weight: .bold, insets: UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))
    private let seriesPill = PadLabel(size: 11.5, weight: .bold, insets: UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))
    private let title = makeLabel(size: 34, lines: 2, display: true)
    private let facts = FlowView(gapX: 10, gapY: 4)
    private let desc = makeLabel(size: 15.5, lines: 3)
    private let buttons = FlowView(gapX: 12, gapY: 8)
    private let message = PadLabel(size: 15, insets: UIEdgeInsets(top: 48, left: 32, bottom: 48, right: 32), lines: 0)
    private let stripLabel = makeLabel(size: 11, weight: .bold)
    private var strip: UICollectionView!

    private var canPrev = false
    private var canNext = false
    /// Where the card went (signed) on the last turn, until the next title takes it back.
    private var turnedTo: CGFloat = 0
    private var settle: DispatchWorkItem?
    private var shownTitle = ""
    private var stripKey = ""
    private var tiles: [QueueTile] = []
    private var active = 0

    override func setUp() {
        let col = UIStackView(axis: .vertical, alignment: .fill)
        contentView.addSubview(col)
        col.pinInCell(contentView, top: 4, bottom: 28)

        // The card: its picture and shades take the size of its words.
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderWidth = 1
        for v in [backdrop, shadeUp, shadeSide] as [UIView] {
            v.isUserInteractionEnabled = false
            card.addSubview(v)
            v.pinEdges(to: card)
        }
        shadeUp.fromBottom([QueueCell.dark.alpha(0.96), QueueCell.dark.alpha(0.55), .clear, .clear])
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 28, leading: 24, bottom: 48, trailing: 24)
        card.addSubview(content)
        content.pinEdges(to: card)
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true

        // The top: where in the queue, and the details button.
        info.onTap = { [weak self] in self?.act("q", what: "info") }
        infoIcon.translatesAutoresizingMaskIntoConstraints = false
        info.addSubview(infoIcon)
        infoIcon.centerIn(info)
        infoIcon.sized(w: 18, h: 18)
        info.sized(w: 44, h: 44)
        let top = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [position, info])
        position.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(top)
        // Room that grows: the words sit at the bottom of the card.
        let gapV = UIView()
        gapV.translatesAutoresizingMaskIntoConstraints = false
        gapV.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        gapV.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.addArrangedSubview(gapV)
        tagPill.clipsToBounds = true
        seriesPill.clipsToBounds = true
        tags.addArrangedSubview(tagPill)
        tags.addArrangedSubview(seriesPill)
        content.addArrangedSubview(startAligned(tags))
        title.layer.shadowColor = UIColor.black.cgColor
        title.layer.shadowOpacity = 0.55
        title.layer.shadowRadius = 7
        title.layer.shadowOffset = CGSize(width: 0, height: 2)
        content.add(title, gap: 20)
        facts.middle = true
        content.add(facts, gap: 16)
        content.add(desc, gap: 18)
        content.add(buttons, gap: 26)

        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(card)
        message.textAlignment = .center
        message.layer.cornerRadius = 28
        message.layer.borderWidth = 1
        message.clipsToBounds = true
        wrap.addSubview(message)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrap.topAnchor),
            card.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -24),
            message.topAnchor.constraint(equalTo: wrap.topAnchor),
            message.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -24),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
            wrap.bottomAnchor.constraint(greaterThanOrEqualTo: card.bottomAnchor),
            wrap.bottomAnchor.constraint(greaterThanOrEqualTo: message.bottomAnchor),
        ])
        // The wrap is as tall as what shows in it.
        let fitCard = wrap.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        fitCard.priority = .defaultHigh
        fitCard.identifier = "card"
        let fitMessage = wrap.bottomAnchor.constraint(equalTo: message.bottomAnchor)
        fitMessage.priority = .defaultLow
        fitMessage.identifier = "message"
        NSLayoutConstraint.activate([fitCard, fitMessage])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        wrap.addGestureRecognizer(pan)
        col.addArrangedSubview(wrap)

        col.addArrangedSubview(padded(stripLabel, top: 24, leading: 24, trailing: 24))
        let layout = FlipFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 10_000
        layout.itemSize = CGSize(width: 200, height: 112)
        layout.sectionInset = UIEdgeInsets(top: 12, left: 24, bottom: 4, right: 24)
        strip = UICollectionView(frame: .zero, collectionViewLayout: layout)
        strip.backgroundColor = .clear
        strip.showsHorizontalScrollIndicator = false
        strip.dataSource = self
        strip.delegate = self
        strip.register(QueueTileCell.self, forCellWithReuseIdentifier: "tile")
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.heightAnchor.constraint(equalToConstant: 128).isActive = true
        col.addArrangedSubview(strip)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let q = m.queue else { return }
        let has = !q.title.trimmingCharacters(in: .whitespaces).isEmpty
        card.isHidden = !has
        canPrev = has && q.canPrev
        canNext = has && q.canNext
        message.isHidden = has || (q.message ?? "").isEmpty
        message.text = q.message
        message.textColor = colors.muted
        message.backgroundColor = colors.surface.alpha(0.3)
        message.layer.borderColor = colors.ink.alpha(0.08).cgColor
        for c in wrap.constraints {
            if c.identifier == "card" { c.priority = has ? .defaultHigh : .defaultLow }
            if c.identifier == "message" { c.priority = has ? .defaultLow : .defaultHigh }
        }
        if has { bindCard(q, m.rtl) }
        bindStrip(q, m.rtl)
    }

    private func bindCard(_ q: HomeQueue, _ rtl: Bool) {
        let met = metrics
        card.backgroundColor = colors.canvas
        card.layer.borderColor = colors.ink.alpha(0.08).cgColor
        shadeSide.fromStart([QueueCell.dark.alpha(0.62), QueueCell.dark.alpha(0.25), .clear, .clear], rtl: rtl)
        ImageLoader.shared.load(backdrop, urls: q.backdrop, size: CGSize(width: met.width - 48, height: 560))

        position.textColor = colors.ink.alpha(0.85)
        position.setStyled(q.position, spacing: 0.22)
        info.rounded(colors.canvas.alpha(0.35), radius: 22, stroke: 1, strokeColor: colors.ink.alpha(0.15))
        info.accessibilityLabel = q.label("info", "See details")
        infoIcon.image = Icons.image("info", size: 18)
        infoIcon.tintColor = colors.ink.alpha(0.85)

        tagPill.textColor = colors.canvas
        tagPill.setCaps(q.tag ?? "", spacing: 0.22, rtl: rtl)
        tagPill.isHidden = (q.tag ?? "").isEmpty
        tagPill.rounded(colors.accent.alpha(0.9), radius: 14)
        seriesPill.textColor = colors.ink.alpha(0.85)
        seriesPill.setCaps(q.series ?? "", spacing: 0.22, rtl: rtl)
        seriesPill.isHidden = (q.series ?? "").isEmpty
        seriesPill.rounded(.clear, radius: 14, stroke: 1, strokeColor: colors.ink.alpha(0.3))
        tags.superview?.isHidden = tagPill.isHidden && seriesPill.isHidden

        title.text = q.title
        title.textColor = colors.ink

        // Year · runtime · IMDb rating · genres.
        let inner = met.width - 48 - 48
        var parts: [UIView] = q.facts.map { makeLabel($0, size: 14, color: colors.ink.alpha(0.85)) }
        if let r = q.rating { parts.append(Paint.ratingBadge(r, size: 13, colors: colors)) }
        if let g = q.genres { parts.append(makeLabel(g, size: 14, color: colors.ink.alpha(0.85))) }
        var withDots: [UIView] = []
        for (i, v) in parts.enumerated() {
            if i > 0 { withDots.append(makeLabel("·", size: 14, color: colors.ink.alpha(0.4))) }
            withDots.append(v)
        }
        facts.maxWidth = inner
        facts.set(withDots)
        facts.isHidden = parts.isEmpty

        desc.textColor = colors.ink.alpha(0.8)
        desc.setStyled(q.desc ?? "", lineHeight: 1.4)
        desc.isHidden = (q.desc ?? "").isEmpty

        buttons.maxWidth = inner
        buttons.set([
            button("play", q.label("play", "Play tonight"), "play", filled: true),
            button(q.saved ? "bookmark_check" : "bookmark", q.saved ? q.label("saved", "Saved") : q.label("save", "Save"), "save", on: q.saved),
            button("skip_forward", q.label("skip", "Skip"), "skip"),
            button("thumbs_down", q.label("block", "Not interested"), "block"),
        ])
        card.setDirection(rtl: rtl)

        // Another title: it slides in; after a swipe the card comes in from the other side.
        let ident = q.title + q.position
        if !shownTitle.isEmpty && shownTitle != ident {
            let from = takeTurnedFrom()
            if from != 0 {
                card.layer.removeAllAnimations()
                card.transform = CGAffineTransform(translationX: -from * 0.35, y: 0)
                card.alpha = 0
                UIView.animate(withDuration: 0.22) {
                    self.card.transform = .identity
                    self.card.alpha = 1
                }
            } else {
                content.alpha = 0
                content.transform = CGAffineTransform(translationX: rtl ? -24 : 24, y: 0)
                UIView.animate(withDuration: 0.2) {
                    self.content.alpha = 1
                    self.content.transform = .identity
                }
            }
        }
        shownTitle = ident
    }

    private func button(_ icon: String, _ text: String, _ what: String, filled: Bool = false, on: Bool = false) -> UIView {
        let fg: UIColor = filled ? colors.canvas : on ? colors.accent : colors.ink.alpha(0.85)
        let b = TapButton { [weak self] in self?.act("q", what: what) }
        if filled {
            b.rounded(colors.ink, radius: 24)
        } else if on {
            b.rounded(colors.accent.alpha(0.15), radius: 24, stroke: 1, strokeColor: colors.accent.alpha(0.6))
        } else {
            b.rounded(colors.canvas.alpha(0.3), radius: 24, stroke: 1, strokeColor: colors.ink.alpha(0.15))
        }
        let row = UIStackView(axis: .horizontal, spacing: filled ? 10 : 8, alignment: .center, views: [
            Icons.view(icon, size: 18, tint: fg),
            makeLabel(text, size: filled ? 15 : 14, color: fg, weight: filled ? .bold : .regular),
        ])
        row.isUserInteractionEnabled = false
        b.addSubview(row)
        let pad: CGFloat = filled ? 28 : 20
        NSLayoutConstraint.activate([
            b.heightAnchor.constraint(equalToConstant: 48),
            row.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: pad),
            row.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -pad),
        ])
        b.accessibilityLabel = text
        return b
    }

    // MARK: - The swipe

    private func takeTurnedFrom() -> CGFloat {
        let v = turnedTo
        turnedTo = 0
        settle?.cancel()
        return v
    }

    private func forward(_ dx: CGFloat) -> Bool { rtl ? dx > 0 : dx < 0 }

    private func allowed(_ dx: CGFloat) -> Bool { forward(dx) ? canNext : canPrev }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: wrap)
        return !card.isHidden && abs(v.x) > abs(v.y) * 1.5
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let dx = pan.translation(in: wrap).x
        let w = Swift.max(1, wrap.bounds.width)
        switch pan.state {
        case .began:
            card.layer.removeAllAnimations()
        case .changed:
            // Toward an end of the queue it gives only a little.
            let x = allowed(dx) ? dx : dx * 0.25
            card.transform = CGAffineTransform(translationX: x, y: 0)
            card.alpha = 1 - Swift.min(0.35, abs(x) / w)
        case .ended, .cancelled, .failed:
            let vx = pan.velocity(in: wrap).x
            let flung = abs(vx) > 700 && (vx > 0) == (dx > 0)
            let go = pan.state == .ended && allowed(dx) && (abs(dx) > w * 0.25 || flung)
            if go {
                let to: CGFloat = (dx > 0 ? 1 : -1) * w
                let fwd = forward(dx)
                UIView.animate(withDuration: 0.16, animations: {
                    self.card.transform = CGAffineTransform(translationX: to, y: 0)
                    self.card.alpha = 0
                }, completion: { _ in
                    self.turnedTo = to
                    self.act("q", what: fwd ? "next" : "prev")
                    // No new title after all (the end of the queue): back in place.
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.turnedTo != 0 else { return }
                        self.turnedTo = 0
                        UIView.animate(withDuration: 0.18) {
                            self.card.transform = .identity
                            self.card.alpha = 1
                        }
                    }
                    self.settle = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                })
            } else {
                UIView.animate(withDuration: 0.18) {
                    self.card.transform = .identity
                    self.card.alpha = 1
                }
            }
        default:
            break
        }
    }

    // MARK: - The strip

    private func bindStrip(_ q: HomeQueue, _ rtl: Bool) {
        stripLabel.textColor = colors.subtle
        stripLabel.setCaps(q.label("queue", "Queue"), spacing: 0.24, rtl: rtl)
        stripLabel.superview?.isHidden = q.strip.isEmpty
        strip.isHidden = q.strip.isEmpty
        let key = q.strip.map { $0.tag + ($0.img.first ?? "") }.joined(separator: "|")
        let fresh = stripKey.isEmpty
        let was = active
        let changed = key != stripKey
        active = q.active
        tiles = q.strip
        if changed {
            stripKey = key
            strip.reloadData()
        } else if was != q.active {
            var paths = [IndexPath(item: q.active, section: 0)]
            if was < tiles.count { paths.append(IndexPath(item: was, section: 0)) }
            strip.reloadItems(at: paths.filter { $0.item < tiles.count })
        }
        guard q.active >= 0 && q.active < q.strip.count else { return }
        // The one up now, in the middle of the strip.
        if fresh || was != q.active || changed {
            let target = IndexPath(item: q.active, section: 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, target.item < self.tiles.count else { return }
                self.strip.layoutIfNeeded()
                self.strip.scrollToItem(at: target, at: .centeredHorizontally, animated: !fresh)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { tiles.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tile", for: indexPath)
        if let t = cell as? QueueTileCell, indexPath.item < tiles.count {
            let i = indexPath.item
            t.bind(tiles[i], index: i, active: active, colors: colors, rtl: rtl) { [weak self] in self?.act("q", i: i, what: "jump") }
        }
        return cell
    }
}

/// One of the queue's pictures: its tag in the corner; the one up now ringed, those before faded.
final class QueueTileCell: UICollectionViewCell {
    private let tap = TapButton()
    private let img = NetImageView()
    private let glow = ShadeView()
    private let tagLabel = PadLabel(size: 9.5, weight: .bold, insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(tap)
        tap.pinEdges(to: contentView)
        tap.layer.cornerRadius = 10
        tap.clipsToBounds = true
        for v in [img, glow] as [UIView] {
            v.isUserInteractionEnabled = false
            tap.addSubview(v)
            v.pinEdges(to: tap)
        }
        tagLabel.clipsToBounds = true
        tap.addSubview(tagLabel)
        NSLayoutConstraint.activate([
            tagLabel.leadingAnchor.constraint(equalTo: tap.leadingAnchor, constant: 6),
            tagLabel.topAnchor.constraint(equalTo: tap.topAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImageLoader.shared.clear(img)
    }

    func bind(_ t: QueueTile, index i: Int, active: Int, colors: HomeColors, rtl: Bool, onTap: @escaping () -> Void) {
        tap.onTap = onTap
        tap.backgroundColor = Paint.plate(t.tag + String(i))
        tap.accessibilityLabel = t.tag
        ImageLoader.shared.load(img, urls: t.img, size: CGSize(width: 200, height: 112))
        tagLabel.textColor = colors.ink
        tagLabel.setCaps(t.tag, spacing: 0.12, rtl: rtl)
        tagLabel.isHidden = t.tag.trimmingCharacters(in: .whitespaces).isEmpty
        tagLabel.rounded(colors.canvas.alpha(0.85), radius: 6)
        let on = i == active
        tap.alpha = i < active ? 0.5 : 1
        tap.layer.borderWidth = on ? 2 : 0
        tap.layer.borderColor = colors.accent.cgColor
        glow.isHidden = !on
        glow.colors = [colors.accent.alpha(0.18), colors.accent.alpha(0.28)]
        setDirection(rtl: rtl)
    }
}
