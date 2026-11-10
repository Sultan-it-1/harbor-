import UIKit

/**
 * Critics' Pick, like the page's card (Android: CriticCard): the title's picture with its logo (or
 * name), year and IMDb rating; under it the review (paged, "Read full"), four stills (full screen on
 * a tap), the cast, the director, the genres and Play.
 */
final class CriticCard: UIView {
    private weak var screen: NativeScreen?
    private var rowKey = ""
    private var info: CriticInfo?

    private let col = UIStackView(axis: .vertical, spacing: 12)
    private let poster = TapButton()
    private var posterH: NSLayoutConstraint!
    private let backdrop = NetImageView()
    private let shade = ShadeView()
    private let logo = LogoView(maxW: 200, maxH: 72)
    private let bigTitle = makeLabel(size: 28, lines: 2, display: true)
    private let posterStats = UIStackView(axis: .horizontal, spacing: 10, alignment: .center)

    private let panel = UIStackView(axis: .vertical)
    private let quoteIcon = UIImageView()
    private let quote = makeLabel(size: 15, lines: 5)
    private let author = makeLabel(size: 11)
    private let source = TapButton()
    private let sourceIcon = UIImageView()
    private let pager = UIStackView(axis: .horizontal, spacing: 0, alignment: .center)
    private let prevButton = TapButton()
    private let nextButton = TapButton()
    private let count = makeLabel(size: 10.5)
    private let readFull = TapButton()
    private let readFullText = makeLabel(size: 11.5, weight: .bold)
    private let stills = UIStackView(axis: .vertical, spacing: 6)
    private var stillViews: [NetImageView] = []
    private var stillHeights: [NSLayoutConstraint] = []
    private let castLabel = makeLabel(size: 10.5)
    private let cast = SideScroll(spacing: 6, inset: 0, alignment: .top)
    private let directorRow = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)
    private let directorLabel = makeLabel(size: 10.5)
    private let directorName = TapButton()
    private let directorText = makeLabel(size: 13)
    private let genres = UIStackView(axis: .horizontal, spacing: 6, alignment: .center)
    private let play = TapButton()
    private let playIcon = UIImageView()
    private let playText = makeLabel(size: 13.5, weight: .bold)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        col.pinEdges(to: self, insets: UIEdgeInsets(top: 4, left: 20, bottom: 0, right: 20))

        // The title's picture.
        poster.pressScale = 0.98
        poster.onTap = { [weak self] in
            guard let self else { return }
            self.screen?.act("open", row: self.rowKey, i: 0)
        }
        poster.layer.cornerRadius = 16
        poster.clipsToBounds = true
        backdrop.isUserInteractionEnabled = false
        shade.isUserInteractionEnabled = false
        poster.addSubview(backdrop)
        backdrop.pinEdges(to: poster)
        poster.addSubview(shade)
        shade.pinEdges(to: poster)
        let text = UIStackView(axis: .vertical, spacing: 0, alignment: .leading, views: [logo, bigTitle])
        text.add(posterStats, gap: 10)
        text.isUserInteractionEnabled = false
        poster.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: poster.leadingAnchor, constant: 20),
            text.trailingAnchor.constraint(equalTo: poster.trailingAnchor, constant: -20),
            text.bottomAnchor.constraint(equalTo: poster.bottomAnchor, constant: -20),
            bigTitle.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
        ])
        bigTitle.layer.shadowColor = UIColor.black.cgColor
        bigTitle.layer.shadowOpacity = 0.55
        bigTitle.layer.shadowRadius = 6
        bigTitle.layer.shadowOffset = CGSize(width: 0, height: 2)
        posterH = poster.heightAnchor.constraint(equalToConstant: 300)
        posterH.isActive = true
        col.addArrangedSubview(poster)

        // The panel under it.
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        col.addArrangedSubview(panel)
        quoteIcon.translatesAutoresizingMaskIntoConstraints = false
        quoteIcon.sized(w: 22, h: 22)
        panel.addArrangedSubview(startAligned(quoteIcon))
        let base = Fonts.display(15)
        if let italic = base.fontDescriptor.withSymbolicTraits(.traitItalic) { quote.font = UIFont(descriptor: italic, size: 15) } else { quote.font = base }
        quote.isUserInteractionEnabled = true
        quote.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(fullTapped)))
        panel.add(quote, gap: 8)

        source.onTap = { [weak self] in
            guard let self, let url = self.currentReview()?.url else { return }
            self.screen?.act("link", row: self.rowKey, text: url)
        }
        sourceIcon.translatesAutoresizingMaskIntoConstraints = false
        source.addSubview(sourceIcon)
        sourceIcon.centerIn(source)
        sourceIcon.sized(w: 16, h: 16)
        source.sized(w: 24, h: 24)
        for (b, d) in [(prevButton, -1), (nextButton, 1)] {
            let ic = UIImageView()
            ic.translatesAutoresizingMaskIntoConstraints = false
            ic.tag = 1
            b.addSubview(ic)
            ic.centerIn(b)
            ic.sized(w: 16, h: 16)
            b.sized(w: 26, h: 26)
            b.onTap = { [weak self] in self?.step(d) }
        }
        pager.addArrangedSubview(prevButton)
        pager.addArrangedSubview(count)
        pager.addArrangedSubview(nextButton)
        readFull.addSubview(readFullText)
        readFullText.isUserInteractionEnabled = false
        readFullText.pinEdges(to: readFull, insets: UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 0))
        readFull.onTap = { [weak self] in self?.showFull() }
        author.setContentHuggingPriority(.defaultLow, for: .horizontal)
        author.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let byline = UIStackView(axis: .horizontal, spacing: 2, alignment: .center, views: [author, source, pager, readFull])
        byline.setCustomSpacing(8, after: source)
        panel.add(byline, gap: 8)

        // Four stills, two by two.
        for r in 0..<2 {
            let line = UIStackView(axis: .horizontal, spacing: 6, alignment: .fill)
            line.distribution = .fillEqually
            for c in 0..<2 {
                let i = r * 2 + c
                let v = NetImageView()
                v.layer.cornerRadius = 10
                v.isUserInteractionEnabled = true
                v.tag = i
                v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stillTapped(_:))))
                let h = v.heightAnchor.constraint(equalToConstant: 80)
                h.isActive = true
                stillHeights.append(h)
                stillViews.append(v)
                line.addArrangedSubview(v)
            }
            stills.addArrangedSubview(line)
        }
        panel.add(stills, gap: 16)

        panel.add(castLabel, gap: 18)
        panel.add(cast, gap: 10)

        directorName.addSubview(directorText)
        directorText.isUserInteractionEnabled = false
        directorText.pinEdges(to: directorName)
        directorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directorRow.addArrangedSubview(directorLabel)
        directorRow.addArrangedSubview(directorName)
        panel.add(directorRow, gap: 18)
        panel.add(startAligned(genres), gap: 10)

        play.onTap = { [weak self] in
            guard let self else { return }
            self.screen?.act("play", row: self.rowKey, i: 0)
        }
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.sized(w: 15, h: 15)
        let pr = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [playIcon, playText])
        pr.isUserInteractionEnabled = false
        play.addSubview(pr)
        NSLayoutConstraint.activate([
            play.heightAnchor.constraint(equalToConstant: 42),
            pr.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            pr.leadingAnchor.constraint(equalTo: play.leadingAnchor, constant: 20),
            pr.trailingAnchor.constraint(equalTo: play.trailingAnchor, constant: -24),
        ])
        // At the end of its line.
        let playLine = UIView()
        playLine.translatesAutoresizingMaskIntoConstraints = false
        playLine.addSubview(play)
        NSLayoutConstraint.activate([
            play.topAnchor.constraint(equalTo: playLine.topAnchor),
            play.bottomAnchor.constraint(equalTo: playLine.bottomAnchor),
            play.trailingAnchor.constraint(equalTo: playLine.trailingAnchor),
            play.leadingAnchor.constraint(greaterThanOrEqualTo: playLine.leadingAnchor),
        ])
        panel.add(playLine, gap: 20)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var colors: HomeColors { screen?.colors ?? .standard }

    private func reviews() -> [CriticReview] { info?.reviews ?? [] }

    private func index() -> Int {
        let n = reviews().count
        return Swift.min(Swift.max(screen?.memory.criticReview[rowKey] ?? 0, 0), Swift.max(0, n - 1))
    }

    private func currentReview() -> CriticReview? {
        let r = reviews()
        let i = index()
        return i < r.count ? r[i] : nil
    }

    private func step(_ d: Int) {
        let n = reviews().count
        guard n > 1, let m = screen?.model else { return }
        screen?.memory.criticReview[rowKey] = (index() + d + n) % n
        paintReview(m)
    }

    func bind(_ m: HomeModel, key: String, info c: CriticInfo, screen s: NativeScreen) {
        screen = s
        rowKey = key
        info = c
        let colors = s.colors
        let cardW = s.metrics.width - 40
        posterH.constant = Swift.max(300, Swift.min(floor(cardW * 9 / 16), 460))
        poster.backgroundColor = colors.surface
        poster.accessibilityLabel = c.title
        shade.fromBottom([colors.canvas.alpha(0.92), colors.canvas.alpha(0.3), .clear])
        ImageLoader.shared.load(backdrop, urls: c.images, size: CGSize(width: cardW, height: posterH.constant))
        bigTitle.text = c.title
        bigTitle.textColor = colors.ink
        bigTitle.isHidden = false
        logo.isHidden = true
        if let l = c.logo {
            logo.setBox(floor(cardW * 0.6), 72)
            logo.isHidden = false
            logo.alpha = 0
            bigTitle.isHidden = true
            logo.load([l]) { [weak self] ok in
                self?.logo.alpha = 1
                self?.logo.isHidden = !ok
                self?.bigTitle.isHidden = ok
            }
        }
        posterStats.removeAllArranged()
        if let y = c.year { posterStats.addArrangedSubview(makeLabel(y, size: 13, color: colors.ink.alpha(0.8))) }
        if let r = c.rating { posterStats.addArrangedSubview(Paint.ratingBadge(r, size: 12.5, colors: colors)) }
        posterStats.isHidden = posterStats.arrangedSubviews.isEmpty

        panel.rounded(colors.surface.alpha(0.55), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        quoteIcon.image = Icons.image("quote", size: 22)
        quoteIcon.tintColor = colors.accent
        paintReview(m)

        // Four stills (the title's picture where there are fewer).
        let inner = cardW - 40
        let stillH = floor((inner - 6) / 2 * 9 / 16)
        let shots = c.stills
        stills.isHidden = shots.isEmpty
        for (i, v) in stillViews.enumerated() {
            stillHeights[i].constant = stillH
            v.backgroundColor = colors.surface
            let src = i < shots.count ? shots[i] : c.images.first
            if !shots.isEmpty, let src {
                ImageLoader.shared.load(v, urls: [src], size: CGSize(width: inner / 2, height: stillH))
            } else {
                ImageLoader.shared.clear(v)
            }
        }

        castLabel.textColor = colors.subtle
        castLabel.setCaps(c.castTitle ?? m.label("cast", "Cast"), spacing: 0.2, rtl: m.rtl)
        cast.set(c.cast.map { p in castChip(p) })
        castLabel.isHidden = c.cast.isEmpty
        cast.isHidden = c.cast.isEmpty

        directorRow.isHidden = c.director == nil
        directorLabel.textColor = colors.subtle
        directorLabel.setCaps(m.label("director", "Director"), spacing: 0.2, rtl: m.rtl)
        directorText.text = c.director?.name
        directorText.textColor = colors.ink
        let d = c.director
        directorName.onTap = { [weak self] in
            guard let self, let d else { return }
            self.screen?.act("person", row: self.rowKey, what: String(d.id))
        }

        genres.removeAllArranged()
        for g in c.genres.prefix(3) {
            let l = PadLabel(g, size: 11.5, color: colors.muted, insets: UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10))
            l.rounded(.clear, radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.12))
            genres.addArrangedSubview(l)
        }
        genres.superview?.isHidden = genres.arrangedSubviews.isEmpty

        play.rounded(colors.ink, radius: 21)
        playIcon.image = Icons.image("play", size: 15)
        playIcon.tintColor = colors.canvas
        playText.text = m.label("play", "Play")
        playText.textColor = colors.canvas
        setDirection(rtl: m.rtl)
    }

    private func paintReview(_ m: HomeModel) {
        guard let c = info else { return }
        let r = currentReview()
        quote.textColor = colors.ink.alpha(0.9)
        quote.setStyled(r?.text ?? c.quote ?? "", lineHeight: 1.25)
        quote.isHidden = (r?.text ?? c.quote ?? "").isEmpty
        author.textColor = colors.muted
        author.setCaps(r.map { [$0.author, $0.score].compactMap { $0 }.joined(separator: " · ") } ?? "", spacing: 0.12, rtl: m.rtl)
        source.isHidden = r?.url == nil
        sourceIcon.image = Icons.image("external_link", size: 16)
        sourceIcon.tintColor = colors.subtle
        source.accessibilityLabel = m.label("source", "Open review source")
        let n = reviews().count
        pager.isHidden = n <= 1
        for (b, name) in [(prevButton, "chevron_left"), (nextButton, "chevron_right")] {
            let ic = b.viewWithTag(1) as? UIImageView
            ic?.image = Icons.image(name, size: 16)
            ic?.tintColor = colors.subtle
            // The arrows point the way they move in a right-to-left page too.
            ic?.transform = m.rtl ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        }
        count.text = "\(index() + 1)/\(n)"
        count.textColor = colors.subtle
        let full = r?.full ?? c.overview
        readFull.isHidden = (full ?? "").isEmpty
        readFullText.textColor = colors.accent
        readFullText.setCaps(m.label("readFull", "Read full"), spacing: 0.12, rtl: m.rtl)
    }

    @objc private func fullTapped() { showFull() }

    @objc private func stillTapped(_ g: UITapGestureRecognizer) {
        guard let c = info, let i = g.view?.tag else { return }
        let list = c.stills.isEmpty ? Array(c.images.prefix(1)) : c.stills
        screen?.overlays.showStills(list, start: i)
    }

    /// The whole review (or the overview), in a box that scrolls.
    private func showFull() {
        guard let c = info, let m = screen?.model else { return }
        let r = currentReview()
        guard let text = r?.full ?? c.overview else { return }
        let a = UIAlertController(title: r?.author ?? c.title, message: text, preferredStyle: .alert)
        if let url = r?.url {
            a.addAction(UIAlertAction(title: m.label("source", "Open review source"), style: .default) { [weak self] _ in
                guard let self else { return }
                self.screen?.act("link", row: self.rowKey, text: url)
            })
        }
        a.addAction(UIAlertAction(title: m.label("close", "Close"), style: .cancel))
        topController(from: self)?.present(a, animated: true)
    }

    private func castChip(_ p: CriticPerson) -> UIView {
        let b = TapButton { [weak self] in
            guard let self else { return }
            self.screen?.act("person", row: self.rowKey, what: String(p.id))
        }
        b.accessibilityLabel = p.name
        let face = Paint.face(name: p.name, image: p.image, size: 52, initialSize: 13, colors: colors)
        let name = makeLabel(p.name, size: 11, color: colors.ink)
        name.textAlignment = .center
        let col = UIStackView(axis: .vertical, spacing: 6, alignment: .center, views: [face, name])
        col.isUserInteractionEnabled = false
        b.addSubview(col)
        col.pinEdges(to: b)
        name.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        b.widthAnchor.constraint(equalToConstant: 68).isActive = true
        return b
    }
}
