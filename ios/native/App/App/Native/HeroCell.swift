import UIKit

/**
 * The hero (Android: HeroHolder): big slides swiped sideways, the next one on its own every 15
 * seconds (a swipe by hand waits a full interval), dots under them. A tap opens the title, Play
 * plays it, the second button adds it to the watchlist.
 */
final class HeroCell: SectionCell, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    /// The hero turns to its next slide after this long.
    static let turnSeconds: TimeInterval = 15

    private var pager: UICollectionView!
    private var heightC: NSLayoutConstraint!
    private let dots = UIStackView(axis: .horizontal, spacing: 6, alignment: .center)
    private var slides: [HomeSlide] = []
    private var timer: Timer?

    override func setUp() {
        let layout = FlipFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        pager = UICollectionView(frame: .zero, collectionViewLayout: layout)
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.backgroundColor = .clear
        pager.dataSource = self
        pager.delegate = self
        pager.register(SlideCell.self, forCellWithReuseIdentifier: "slide")
        contentView.addSubview(pager)
        pager.pinInCell(contentView)
        heightC = pager.heightAnchor.constraint(equalToConstant: 500)
        heightC.isActive = true
        dots.isUserInteractionEnabled = false
        contentView.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            dots.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopTurning()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopTurning() } else { scheduleTurn() }
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        heightC.constant = metrics.hero
        slides = m.hero
        pager.reloadData()
        pager.alpha = 1
        guard let screen else { return }
        if screen.memory.heroPage >= slides.count { screen.memory.heroPage = 0 }
        let page = screen.memory.heroPage
        if !slides.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, page < self.slides.count else { return }
                self.pager.layoutIfNeeded()
                self.pager.scrollToItem(at: IndexPath(item: page, section: 0), at: .centeredHorizontally, animated: false)
            }
        }
        paintDots()
        scheduleTurn()
    }

    override func willShow() {
        scheduleTurn()
    }

    private func stopTurning() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleTurn() {
        stopTurning()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: HeroCell.turnSeconds, repeats: false) { [weak self] _ in self?.autoTurn() }
    }

    /// Only while the screen shows and nobody is swiping it.
    private func autoTurn() {
        let n = slides.count
        if n > 1, let screen, screen.isShowing, !pager.isDragging, !pager.isDecelerating {
            let next = (screen.memory.heroPage + 1) % n
            if next == 0 {
                // Back to the first: a quick fade rather than sliding past every slide.
                UIView.animate(withDuration: 0.22, animations: { self.pager.alpha = 0 }, completion: { _ in
                    self.pager.scrollToItem(at: IndexPath(item: 0, section: 0), at: .centeredHorizontally, animated: false)
                    screen.memory.heroPage = 0
                    self.paintDots()
                    UIView.animate(withDuration: 0.32) { self.pager.alpha = 1 }
                })
            } else {
                pager.scrollToItem(at: IndexPath(item: next, section: 0), at: .centeredHorizontally, animated: true)
            }
        }
        scheduleTurn()
    }

    private func settle() {
        let mid = CGPoint(x: pager.bounds.midX, y: pager.bounds.midY)
        guard let ip = pager.indexPathForItem(at: mid), let screen else { return }
        screen.memory.heroPage = ip.item
        paintDots()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A swipe by hand: the next turn waits a full interval from now.
        scheduleTurn()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    private func paintDots() {
        let n = slides.count
        if dots.arrangedSubviews.count != n {
            dots.removeAllArranged()
            for _ in 0..<n {
                let d = UIView()
                d.translatesAutoresizingMaskIntoConstraints = false
                d.layer.cornerRadius = 3
                let w = d.widthAnchor.constraint(equalToConstant: 6)
                w.identifier = "w"
                NSLayoutConstraint.activate([w, d.heightAnchor.constraint(equalToConstant: 6)])
                dots.addArrangedSubview(d)
            }
        }
        dots.isHidden = n <= 1
        let page = screen?.memory.heroPage ?? 0
        for (i, d) in dots.arrangedSubviews.enumerated() {
            let on = i == page
            d.constraints.first { $0.identifier == "w" }?.constant = on ? 22 : 6
            d.backgroundColor = on ? colors.ink : colors.ink.alpha(0.35)
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { slides.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "slide", for: indexPath)
        if let s = cell as? SlideCell, let screen, let m = screen.model, indexPath.item < slides.count {
            let i = indexPath.item
            s.bind(slides[i], m, metrics: metrics) { [weak self] what in self?.act("hero", i: i, what: what) }
            s.setDirection(rtl: m.rtl)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: metrics.width, height: metrics.hero)
    }
}

/// One slide: the backdrop, darkened at the top and under the words; a rank pill, the logo (or the
/// name), the overview, year / rating / runtime, Play and the watchlist button.
final class SlideCell: UICollectionViewCell {
    private let tap = TapButton()
    private let backdrop = NetImageView()
    private let topShade = ShadeView()
    private let bottomShade = ShadeView()
    private let content = PassthroughStack(axis: .vertical, alignment: .leading)
    private let rank = PadLabel(size: 12, weight: .bold, insets: UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
    private let logo = LogoView(maxW: 260, maxH: 84)
    private let title = makeLabel(size: 34, lines: 2, display: true)
    private let desc = makeLabel(size: 14, lines: 2)
    private let stats = UIStackView(axis: .horizontal, spacing: 18, alignment: .center)
    private let playButton = TapButton()
    private let listButton = TapButton()
    private let playIcon = UIImageView()
    private let listIcon = UIImageView()
    private let playText = makeLabel(size: 14, weight: .bold)
    private let listText = makeLabel(size: 14)
    private var onAct: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        tap.pressScale = 1
        tap.onTap = { [weak self] in self?.onAct?("open") }
        contentView.addSubview(tap)
        tap.pinEdges(to: contentView)
        for v in [backdrop, topShade, bottomShade] as [UIView] {
            v.isUserInteractionEnabled = false
            tap.addSubview(v)
        }
        backdrop.pinEdges(to: tap)
        bottomShade.pinEdges(to: tap)
        topShade.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topShade.topAnchor.constraint(equalTo: tap.topAnchor),
            topShade.leadingAnchor.constraint(equalTo: tap.leadingAnchor),
            topShade.trailingAnchor.constraint(equalTo: tap.trailingAnchor),
            topShade.heightAnchor.constraint(equalToConstant: 112),
        ])
        tap.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: tap.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: tap.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: tap.bottomAnchor, constant: -40),
        ])
        rank.clipsToBounds = true
        content.addArrangedSubview(rank)
        content.setCustomSpacing(10, after: rank)
        content.addArrangedSubview(logo)
        content.addArrangedSubview(title)
        title.layer.shadowColor = UIColor.black.cgColor
        title.layer.shadowOpacity = 0.45
        title.layer.shadowRadius = 6
        title.layer.shadowOffset = CGSize(width: 0, height: 3)
        content.add(desc, gap: 8)
        content.add(stats, gap: 10)
        for (b, ic, t) in [(playButton, playIcon, playText), (listButton, listIcon, listText)] {
            ic.translatesAutoresizingMaskIntoConstraints = false
            ic.sized(w: 18, h: 18)
            let row = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [ic, t])
            row.isUserInteractionEnabled = false
            b.addSubview(row)
            NSLayoutConstraint.activate([
                b.heightAnchor.constraint(equalToConstant: 44),
                row.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                row.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                row.leadingAnchor.constraint(greaterThanOrEqualTo: b.leadingAnchor, constant: 10),
            ])
        }
        playButton.onTap = { [weak self] in self?.onAct?("play") }
        listButton.onTap = { [weak self] in self?.onAct?("list") }
        let buttons = PassthroughStack(axis: .horizontal, spacing: 10, alignment: .fill, views: [playButton, listButton])
        buttons.distribution = .fillEqually
        content.add(buttons, gap: 18)
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalTo: content.widthAnchor),
            desc.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImageLoader.shared.clear(backdrop)
        ImageLoader.shared.clear(logo)
    }

    func bind(_ s: HomeSlide, _ m: HomeModel, metrics: Metrics, onAct: @escaping (String) -> Void) {
        self.onAct = onAct
        let colors = m.colors
        tap.backgroundColor = colors.canvas
        tap.accessibilityLabel = s.title
        topShade.colors = [colors.canvas.alpha(0.8), .clear]
        bottomShade.fromBottom([colors.canvas, colors.canvas.alpha(0.85), colors.canvas.alpha(0.35), .clear])
        ImageLoader.shared.load(backdrop, urls: s.images, size: CGSize(width: metrics.width, height: metrics.hero))

        rank.isHidden = s.rank == nil
        rank.text = s.rank
        rank.textColor = colors.ink
        rank.rounded(colors.canvas.alpha(0.85), radius: 6)
        rank.clipsToBounds = true

        title.text = s.title
        title.textColor = colors.ink
        title.isHidden = false
        logo.isHidden = true
        if let l = s.logo {
            logo.setBox(floor(metrics.width * 0.7), 84)
            logo.isHidden = false
            logo.alpha = 0
            title.isHidden = true
            logo.load([l]) { [weak self] ok in
                self?.logo.alpha = 1
                self?.logo.isHidden = !ok
                self?.title.isHidden = ok
            }
        }
        desc.text = s.description
        desc.isHidden = (s.description ?? "").isEmpty
        desc.textColor = colors.muted

        stats.removeAllArranged()
        if let y = s.year { stats.addArrangedSubview(stat(m.label("year", "Year"), y, colors)) }
        if let r = s.rating { stats.addArrangedSubview(Paint.ratingBadge(r, size: 13, colors: colors)) }
        if let rt = s.runtime { stats.addArrangedSubview(stat(m.label("runtime", "Runtime"), rt, colors)) }
        stats.isHidden = stats.arrangedSubviews.isEmpty

        playButton.rounded(colors.ink, radius: 22)
        playIcon.image = Icons.image("play", size: 18)
        playIcon.tintColor = colors.canvas
        playText.text = m.label("play", "Play")
        playText.textColor = colors.canvas
        listButton.rounded(colors.canvas.alpha(0.55), radius: 22, stroke: 1, strokeColor: colors.ink.alpha(0.25))
        listIcon.image = Icons.image(s.inList ? "check" : "plus", size: 18)
        listIcon.tintColor = colors.ink
        listText.text = s.inList ? m.label("inList", "In Watchlist") : m.label("add", "Add to Watchlist")
        listText.textColor = colors.ink
    }

    private func stat(_ name: String, _ value: String, _ colors: HomeColors) -> UIView {
        // A gap rather than a trailing space: in Arabic the label drops the space at its end.
        UIStackView(axis: .horizontal, spacing: 4, alignment: .center, views: [
            makeLabel("\(name):", size: 13, color: colors.subtle),
            makeLabel(value, size: 13, color: colors.ink),
        ])
    }
}

/// A page's heading (Shows, Library, a genre, a person…): a small kicker, a big title (or a logo),
/// a line under it, maybe a picture behind it or a portrait above it.
final class HeaderCell: SectionCell {
    private let backdrop = NetImageView()
    private let shadeUp = ShadeView()
    private let shadeSide = ShadeView()
    private let glow = GlowView()
    private let col = UIStackView(axis: .vertical, alignment: .fill)
    private var colTop: NSLayoutConstraint!
    private let photo = NetImageView()
    private var photoWrap: UIView!
    private let kickerLine = UIStackView(axis: .horizontal, spacing: 10, alignment: .center)
    private let iconBox = UIView()
    private let iconView = UIImageView()
    private let kicker = makeLabel(size: 11, weight: .bold)
    private let badge = PadLabel(size: 11, weight: .bold, insets: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
    private let titleTap = TapButton()
    private let logo = LogoView(maxW: 200, maxH: 56)
    private let title = makeLabel(size: 30, lines: 2, display: true)
    private var titleMax: NSLayoutConstraint!
    private let chevron = UIView()
    private let chevronIcon = UIImageView()
    private let count = makeLabel(size: 14)
    private let subtitle = makeLabel(size: 14, lines: 3)
    private let body = makeLabel(size: 15, lines: 3)
    private var bodyKey = ""
    private var header: HomeHeader?

    override func setUp() {
        contentView.clipsToBounds = true
        for v in [glow, backdrop, shadeUp, shadeSide] as [UIView] {
            v.isUserInteractionEnabled = false
            contentView.addSubview(v)
        }
        glow.pinEdges(to: contentView)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        shadeUp.pinEdges(to: contentView)
        shadeSide.pinEdges(to: contentView)

        contentView.addSubview(col)
        col.translatesAutoresizingMaskIntoConstraints = false
        colTop = col.topAnchor.constraint(equalTo: contentView.topAnchor)
        let b = col.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        b.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            colTop, b,
            col.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            col.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        ])

        photo.layer.cornerRadius = 16
        photo.sized(w: 200, h: 300)
        photoWrap = startAligned(photo, bottom: 24)
        col.addArrangedSubview(photoWrap)

        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconView)
        iconView.centerIn(iconBox)
        iconView.sized(w: 16, h: 16)
        iconBox.sized(w: 36, h: 36)
        badge.isUserInteractionEnabled = true
        badge.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(badgeTapped)))
        kickerLine.addArrangedSubview(iconBox)
        kickerLine.addArrangedSubview(kicker)
        kickerLine.addArrangedSubview(badge)
        kickerLine.setCustomSpacing(12, after: kicker)
        col.addArrangedSubview(startAligned(kickerLine))

        // The title (or a logo in its place); a genre page's title opens the other genres.
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevronIcon.translatesAutoresizingMaskIntoConstraints = false
        chevron.addSubview(chevronIcon)
        chevronIcon.centerIn(chevron)
        chevronIcon.sized(w: 18, h: 18)
        chevron.sized(w: 40, h: 40)
        chevron.layer.cornerRadius = 20
        chevron.layer.borderWidth = 1
        let titleLine = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [logo, title, chevron, count])
        titleLine.setCustomSpacing(14, after: chevron)
        titleLine.isUserInteractionEnabled = false
        titleTap.pressScale = 1
        titleTap.onTap = { [weak self] in self?.pickSwitch() }
        titleTap.addSubview(titleLine)
        titleLine.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLine.topAnchor.constraint(equalTo: titleTap.topAnchor),
            titleLine.bottomAnchor.constraint(equalTo: titleTap.bottomAnchor),
            titleLine.leadingAnchor.constraint(equalTo: titleTap.leadingAnchor),
            titleLine.trailingAnchor.constraint(lessThanOrEqualTo: titleTap.trailingAnchor),
        ])
        titleMax = title.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        titleMax.isActive = true
        col.add(titleTap, gap: 6)
        col.add(subtitle, gap: 8)
        body.isUserInteractionEnabled = true
        body.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bodyTapped)))
        col.add(body, gap: 10)
    }

    @objc private func badgeTapped() { act("chip", row: "badge", what: "badge") }

    /// A long biography: all of it on a tap, back to its first lines on another.
    @objc private func bodyTapped() {
        guard let screen, let h = header, let m = model else { return }
        if screen.memory.headerBodyOpen.contains(bodyKey) {
            screen.memory.headerBodyOpen.remove(bodyKey)
        } else {
            screen.memory.headerBodyOpen.insert(bodyKey)
        }
        paintBody(h, m)
        screen.refreshHeights()
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let h = m.header else { return }
        header = h
        let rtl = m.rtl
        let met = metrics
        // A picture behind: it starts at the very top (the list has no top room then).
        let hasBackdrop = !h.backdrop.isEmpty
        colTop.constant = hasBackdrop ? 150 : 0
        backdrop.isHidden = !hasBackdrop
        shadeUp.isHidden = !hasBackdrop
        shadeSide.isHidden = !hasBackdrop
        if hasBackdrop {
            ImageLoader.shared.load(backdrop, urls: h.backdrop, size: CGSize(width: met.width, height: 420))
            shadeUp.fromBottom([colors.canvas, colors.canvas.alpha(0.7), colors.canvas.alpha(0.1)])
            shadeSide.fromStart([colors.canvas.alpha(0.9), colors.canvas.alpha(0.25), .clear], rtl: rtl)
        } else {
            ImageLoader.shared.clear(backdrop)
        }
        // A glow of the service's colour from the top (like the page's).
        glow.isHidden = h.tint == nil || hasBackdrop
        glow.color = h.tint
        glow.centerX = rtl ? 0.7 : 0.3

        let icon: String?
        switch h.icon {
        case "tag": icon = "tag"
        case "calendar": icon = "calendar"
        case "clock": icon = "clock"
        case "globe": icon = "globe"
        case "languages": icon = "languages"
        case "building": icon = "building_2"
        case "tv": icon = "tv"
        default: icon = nil
        }
        iconBox.isHidden = icon == nil
        if let icon {
            iconView.image = Icons.image(icon, size: 16)
            iconView.tintColor = colors.muted
            iconBox.rounded(colors.surface.alpha(0.7), radius: 12)
        }
        kicker.font = Fonts.bold(icon != nil ? 12.5 : 11)
        kicker.textColor = colors.subtle
        // Arabic has no letter case and its letters must stay joined.
        kicker.setCaps(h.kicker ?? "", spacing: icon != nil ? 0.22 : 0.28, rtl: rtl)
        kicker.isHidden = (h.kicker ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        badge.textColor = colors.accent
        badge.setCaps(h.badge ?? "", spacing: 0.14, rtl: rtl)
        badge.isHidden = (h.badge ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        badge.rounded(colors.accent.alpha(0.1), radius: 6, stroke: 1, strokeColor: colors.accent.alpha(0.3))
        badge.clipsToBounds = true
        kickerLine.superview?.isHidden = kicker.isHidden && icon == nil && badge.isHidden

        // The title, or the service's logo in its place.
        title.text = h.title
        title.font = Fonts.display(h.size ?? 30)
        title.textColor = colors.ink
        let switching = !h.switchChips.isEmpty
        titleMax.constant = (met.width - 40) * (switching || h.count != nil ? 0.72 : 1)
        title.isHidden = h.title.trimmingCharacters(in: .whitespaces).isEmpty || h.logo != nil
        logo.isHidden = h.logo == nil
        if let l = h.logo {
            logo.setBox(floor(met.width * 0.6), 56)
            logo.load([l]) { [weak self] ok in
                self?.logo.isHidden = !ok
                self?.title.isHidden = ok
            }
        } else {
            ImageLoader.shared.clear(logo)
        }
        chevron.isHidden = !switching
        if switching {
            chevronIcon.image = Icons.image("chevron_down", size: 18)
            chevronIcon.tintColor = colors.muted
            chevron.layer.borderColor = colors.ink.alpha(0.12).cgColor
        }
        titleTap.isEnabled = switching
        count.text = h.count
        count.isHidden = (h.count ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        count.textColor = colors.subtle
        subtitle.textColor = colors.muted
        subtitle.setStyled(h.subtitle ?? "", lineHeight: 1.2)
        subtitle.isHidden = (h.subtitle ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        paintBody(h, m)

        photoWrap.isHidden = h.photo == nil
        if let p = h.photo {
            photo.backgroundColor = Paint.plate(h.title)
            ImageLoader.shared.load(photo, urls: [p], size: CGSize(width: 200, height: 300))
        } else {
            ImageLoader.shared.clear(photo)
        }
    }

    private func paintBody(_ h: HomeHeader, _ m: HomeModel) {
        bodyKey = h.title
        let open = screen?.memory.headerBodyOpen.contains(bodyKey) == true
        body.numberOfLines = open ? 0 : h.bodyLines
        body.textColor = colors.muted
        body.setStyled(h.body ?? "", lineHeight: 1.25)
        body.isHidden = (h.body ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        body.setDirection(rtl: m.rtl)
    }

    /// The other genres, to switch to one.
    private func pickSwitch() {
        guard let h = header, !h.switchChips.isEmpty else { return }
        let a = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for c in h.switchChips {
            a.addAction(UIAlertAction(title: c.on ? "✓ " + c.label : c.label, style: .default) { [weak self] _ in
                self?.act("chip", row: "switch", what: c.id)
            })
        }
        a.addAction(UIAlertAction(title: model?.label("cancel", "Cancel") ?? "Cancel", style: .cancel))
        a.popoverPresentationController?.sourceView = titleTap
        a.popoverPresentationController?.sourceRect = titleTap.bounds
        topController(from: self)?.present(a, animated: true)
    }
}
