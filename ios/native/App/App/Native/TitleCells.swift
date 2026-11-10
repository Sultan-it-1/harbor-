import UIKit

/**
 * A title's hero as the page draws it (Android: DetailHolder): the backdrop darkened from the
 * bottom and the start, the tagline, the logo (or the name), the pills (year, ratings, runtime,
 * genres), the awards, Play and the round "…" (the page's own menu); then the synopsis, four
 * lines until opened.
 */
final class DetailCell: SectionCell {
    private let frameView = UIView()
    private var frameH: NSLayoutConstraint!
    private let backdrop = NetImageView()
    private let shadeUp = ShadeView()
    private let shadeSide = ShadeView()
    private let content = PassthroughStack(axis: .vertical, alignment: .fill)
    /// The hero's words (tagline, logo or name, pills, awards): hidden while the details load.
    private let words = PassthroughStack(axis: .vertical, alignment: .fill)
    private let tagline = makeLabel(size: 13, weight: .bold, lines: 2)
    private let logo = LogoView(maxW: 280, maxH: 96)
    private let title = makeLabel(size: 36, lines: 3, display: true)
    private let pills = FlowView(gapX: 10, gapY: 10)
    private let awards = makeLabel(size: 13, lines: 2)
    private let play = TapButton()
    private let playIcon = UIImageView()
    private let playText = makeLabel(size: 15, weight: .bold)
    private let extra = TapButton()
    private let extraText = makeLabel(size: 14)
    private let more = TapButton()
    private let moreIcon = UIImageView()
    private let synopsis = makeLabel(size: 16, lines: 4)
    private let synopsisToggle = TapButton()
    private let synopsisToggleText = makeLabel(size: 13.5, weight: .bold)
    private var synopsisWrap: UIView!
    private var toggleWrap: UIView!
    /// The gap under the synopsis (gone with it).
    private let synopsisGap = UIView()
    private var key = ""
    private var shownFor = ""
    private var reveal: DispatchWorkItem?
    private var nameFallback: DispatchWorkItem?

    override func setUp() {
        let col = UIStackView(axis: .vertical, alignment: .fill)
        contentView.addSubview(col)
        col.pinInCell(contentView)

        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.clipsToBounds = true
        frameH = frameView.heightAnchor.constraint(equalToConstant: 500)
        frameH.isActive = true
        for v in [backdrop, shadeUp, shadeSide] as [UIView] {
            v.isUserInteractionEnabled = false
            frameView.addSubview(v)
            v.pinEdges(to: frameView)
        }
        frameView.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: frameView.bottomAnchor, constant: -28),
            content.topAnchor.constraint(greaterThanOrEqualTo: frameView.topAnchor, constant: 60),
        ])
        tagline.isUserInteractionEnabled = true
        tagline.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(taglineTapped)))
        words.addArrangedSubview(tagline)
        words.setCustomSpacing(14, after: tagline)
        words.addArrangedSubview(startAligned(logo))
        title.layer.shadowColor = UIColor.black.cgColor
        title.layer.shadowOpacity = 0.45
        title.layer.shadowRadius = 6
        title.layer.shadowOffset = CGSize(width: 0, height: 3)
        words.addArrangedSubview(title)
        words.add(pills, gap: 20)
        words.add(awards, gap: 12)
        content.addArrangedSubview(words)

        play.onTap = { [weak self] in self?.act("d", what: "play") }
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.sized(w: 18, h: 18)
        let pr = UIStackView(axis: .horizontal, spacing: 10, alignment: .center, views: [playIcon, playText])
        pr.isUserInteractionEnabled = false
        play.addSubview(pr)
        NSLayoutConstraint.activate([
            play.heightAnchor.constraint(equalToConstant: 48),
            pr.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            pr.leadingAnchor.constraint(equalTo: play.leadingAnchor, constant: 24),
            pr.trailingAnchor.constraint(equalTo: play.trailingAnchor, constant: -28),
        ])
        extra.onTap = { [weak self] in self?.act("d", what: "extra") }
        extraText.isUserInteractionEnabled = false
        extra.addSubview(extraText)
        NSLayoutConstraint.activate([
            extra.heightAnchor.constraint(equalToConstant: 48),
            extraText.centerYAnchor.constraint(equalTo: extra.centerYAnchor),
            extraText.leadingAnchor.constraint(equalTo: extra.leadingAnchor, constant: 20),
            extraText.trailingAnchor.constraint(equalTo: extra.trailingAnchor, constant: -20),
        ])
        more.onTap = { [weak self] in self?.act("d", what: "more") }
        moreIcon.translatesAutoresizingMaskIntoConstraints = false
        more.addSubview(moreIcon)
        moreIcon.centerIn(more)
        moreIcon.sized(w: 20, h: 20)
        more.sized(w: 48, h: 48)
        let actions = PassthroughStack(axis: .horizontal, spacing: 12, alignment: .center, views: [play, extra, more])
        let actionsLine = PassthroughView()
        actionsLine.translatesAutoresizingMaskIntoConstraints = false
        actionsLine.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: actionsLine.topAnchor),
            actions.bottomAnchor.constraint(equalTo: actionsLine.bottomAnchor),
            actions.leadingAnchor.constraint(equalTo: actionsLine.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: actionsLine.trailingAnchor),
        ])
        content.add(actionsLine, gap: 30)
        col.addArrangedSubview(frameView)

        synopsis.isUserInteractionEnabled = true
        synopsis.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleSynopsis)))
        synopsisWrap = padded(synopsis, top: 20, leading: 20, trailing: 20)
        col.addArrangedSubview(synopsisWrap)
        synopsisToggle.pressScale = 1
        synopsisToggle.onTap = { [weak self] in self?.toggleSynopsis() }
        synopsisToggleText.isUserInteractionEnabled = false
        synopsisToggle.addSubview(synopsisToggleText)
        synopsisToggleText.pinEdges(to: synopsisToggle, insets: UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 8))
        toggleWrap = startAligned(synopsisToggle, leading: 20)
        col.addArrangedSubview(toggleWrap)
        synopsisGap.translatesAutoresizingMaskIntoConstraints = false
        synopsisGap.heightAnchor.constraint(equalToConstant: 28).isActive = true
        col.addArrangedSubview(synopsisGap)
    }

    @objc private func taglineTapped() {
        if model?.detail?.taglineLink == true { act("pill", what: "tagline") }
    }

    @objc private func toggleSynopsis() {
        guard let screen, let m = model, let d = m.detail else { return }
        if screen.memory.synopsisOpen.contains(key) {
            screen.memory.synopsisOpen.remove(key)
        } else {
            screen.memory.synopsisOpen.insert(key)
        }
        paintSynopsis(d, m)
        screen.refreshHeights()
    }

    private func showWords() {
        reveal?.cancel()
        UIView.animate(withDuration: 0.22) {
            self.words.alpha = 1
            self.synopsis.alpha = 1
            self.synopsisToggle.alpha = 1
        }
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let d = m.detail else { return }
        let rtl = m.rtl
        let met = metrics
        key = d.title
        frameH.constant = met.hero
        frameView.backgroundColor = colors.canvas
        let ident = String(m.top)
        ImageLoader.shared.load(backdrop, urls: d.backdrop, size: CGSize(width: met.width, height: met.hero), keep: shownFor == ident)
        shadeUp.fromBottom([colors.canvas, colors.canvas.alpha(0.55), .clear])
        shadeSide.fromStart([colors.canvas.alpha(0.85), colors.canvas.alpha(0.35), .clear], rtl: rtl)

        tagline.textColor = d.taglineLink ? colors.muted : colors.subtle
        tagline.setCaps(d.tagline ?? "", spacing: 0.2, rtl: rtl)
        tagline.isHidden = (d.tagline ?? "").trimmingCharacters(in: .whitespaces).isEmpty

        title.text = d.title
        title.textColor = colors.ink
        nameFallback?.cancel()
        if let l = d.logo {
            // The logo takes the name's place: the name doesn't show first and then swap.
            logo.setBox(floor(met.width * 0.72), 96)
            logo.superview?.isHidden = false
            if logo.image == nil {
                title.isHidden = true
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.logo.image == nil else { return }
                    self.title.isHidden = false
                }
                nameFallback = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
            }
            logo.load([l]) { [weak self] ok in
                self?.nameFallback?.cancel()
                self?.logo.superview?.isHidden = !ok
                self?.title.isHidden = ok
            }
        } else {
            ImageLoader.shared.clear(logo)
            logo.superview?.isHidden = true
            title.isHidden = false
        }
        // While the details load (another title, its name only): its words wait, then fade in
        // together, instead of the year, genres, text and logo changing one after another.
        if ident != shownFor {
            shownFor = ident
            reveal?.cancel()
            if d.pending {
                words.layer.removeAllAnimations()
                words.alpha = 0
                synopsis.alpha = 0
                synopsisToggle.alpha = 0
                let work = DispatchWorkItem { [weak self] in self?.showWords() }
                reveal = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
            } else {
                words.alpha = 1
                synopsis.alpha = 1
                synopsisToggle.alpha = 1
            }
        } else if !d.pending && words.alpha < 1 {
            showWords()
        }

        pills.maxWidth = met.width - 40
        pills.set(d.pills.map { pill($0) })
        pills.isHidden = d.pills.isEmpty
        awards.text = d.awards
        awards.isHidden = (d.awards ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        awards.textColor = colors.accent

        play.isHidden = d.play == nil
        play.rounded(colors.ink, radius: 24)
        playIcon.image = Icons.image("play", size: 18)
        playIcon.tintColor = colors.canvas
        playText.text = d.play
        playText.textColor = colors.canvas
        extra.isHidden = (d.extra ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        extraText.text = d.extra
        extraText.textColor = colors.muted
        extra.rounded(colors.canvas.alpha(0.8), radius: 24, stroke: 1, strokeColor: colors.ink.alpha(0.18))
        more.isHidden = !d.more
        more.rounded(colors.canvas.alpha(0.8), radius: 24, stroke: 1, strokeColor: colors.ink.alpha(0.18))
        more.accessibilityLabel = m.label("moreActions", "More actions")
        moreIcon.image = Icons.image("ellipsis", size: 20)
        moreIcon.tintColor = colors.ink
        paintSynopsis(d, m)
    }

    private func paintSynopsis(_ d: HomeDetail, _ m: HomeModel) {
        let text = d.synopsis ?? ""
        let has = !text.trimmingCharacters(in: .whitespaces).isEmpty
        synopsisWrap.isHidden = !has
        synopsisGap.isHidden = !has
        let open = screen?.memory.synopsisOpen.contains(key) == true
        synopsis.numberOfLines = open ? 0 : 4
        synopsis.textColor = colors.muted
        synopsis.setStyled(text, lineHeight: 1.4)
        synopsis.setDirection(rtl: m.rtl)
        synopsisToggleText.text = open ? m.label("less", "Show less") : m.label("more", "Read more")
        synopsisToggleText.textColor = colors.ink
        // "Read more" only when four lines don't hold it all.
        var cut = false
        if has {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.4
            let w = metrics.width - 40
            let full = (text as NSString).boundingRect(
                with: CGSize(width: w, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: synopsis.font as Any, .paragraphStyle: p],
                context: nil
            ).height
            cut = full > ceil(synopsis.font.lineHeight * 1.4 * 4) + 2
        }
        toggleWrap.isHidden = !(has && (open || cut))
    }

    /// Year / runtime / genre (a tap opens that list), the IMDb tag with its score, other scores.
    private func pill(_ p: DetailPill) -> UIView {
        if p.kind == "imdb" { return Paint.ratingBadge(p.label, size: 13, colors: colors) }
        let l = PadLabel(p.label, size: 13, color: colors.muted, weight: p.kind == "score" ? .bold : .regular, insets: UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12))
        l.textAlignment = .center
        l.rounded(colors.canvas.alpha(0.5), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.14))
        l.clipsToBounds = true
        if p.kind == "pill" {
            let b = TapButton { [weak self] in self?.act("pill", what: p.id) }
            l.isUserInteractionEnabled = false
            b.addSubview(l)
            l.pinEdges(to: b)
            b.accessibilityLabel = p.label
            return b
        }
        return l
    }
}

/**
 * One episode as the page's list shows it (Android: EpisodeHolder): the still (number, watched
 * check, rating, how far in) and beside it the name, the line under it and the overview; then its
 * info and download buttons. Tap: play; long press: the page's menu.
 */
final class EpisodeCell: LineCell {
    private let thumb = UIView()
    private let still = NetImageView()
    private let number = PadLabel(size: 11, weight: .bold, insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
    private let check = UIView()
    private let checkIcon = UIImageView()
    private let rating = UIView()
    private let track = UIView()
    private let bar = UIView()
    private var barW: NSLayoutConstraint!
    private let title = makeLabel(size: 14, weight: .bold)
    private let badge = PadLabel(size: 10, weight: .bold, insets: UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6))
    private let sub = makeLabel(size: 12, lines: 2)
    private let desc = makeLabel(size: 13.5, lines: 2)
    private let info = TapButton()
    private let infoIcon = UIImageView()
    private let download = TapButton()
    private let downloadIcon = UIImageView()

    private static let thumbW: CGFloat = 132
    private static var thumbH: CGFloat { floor(thumbW * 9 / 16) }

    override func build() {
        tap.pinInCell(contentView)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.layer.cornerRadius = 8
        thumb.clipsToBounds = true
        thumb.sized(w: EpisodeCell.thumbW, h: EpisodeCell.thumbH)
        thumb.addSubview(still)
        still.pinEdges(to: thumb)
        number.clipsToBounds = true
        thumb.addSubview(number)
        check.translatesAutoresizingMaskIntoConstraints = false
        check.layer.cornerRadius = 11
        check.layer.borderWidth = 1
        checkIcon.translatesAutoresizingMaskIntoConstraints = false
        check.addSubview(checkIcon)
        checkIcon.centerIn(check)
        checkIcon.sized(w: 12, h: 12)
        thumb.addSubview(check)
        rating.translatesAutoresizingMaskIntoConstraints = false
        thumb.addSubview(rating)
        track.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(bar)
        thumb.addSubview(track)
        barW = bar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 6),
            number.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 6),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22),
            check.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -6),
            check.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 6),
            rating.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 6),
            rating.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -7),
            track.leadingAnchor.constraint(equalTo: thumb.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: thumb.trailingAnchor),
            track.bottomAnchor.constraint(equalTo: thumb.bottomAnchor),
            track.heightAnchor.constraint(equalToConstant: 3),
            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor),
            bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            barW,
        ])

        badge.clipsToBounds = true
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleLine = UIStackView(axis: .horizontal, spacing: 6, alignment: .center, views: [title, badge])
        let texts = UIStackView(axis: .vertical, spacing: 4, views: [titleLine, sub, desc])
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (b, ic, what) in [(info, infoIcon, "info"), (download, downloadIcon, "dl")] {
            ic.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(ic)
            ic.centerIn(b)
            ic.sized(w: 18, h: 18)
            b.sized(w: 40, h: 40)
            b.layer.cornerRadius = 20
            b.onTap = { [weak self] in
                guard let self else { return }
                self.act(what, row: self.rowKey, i: self.index)
            }
        }
        thumb.isUserInteractionEnabled = false
        texts.isUserInteractionEnabled = false
        let line = PassthroughStack(axis: .horizontal, spacing: 12, alignment: .center, views: [thumb, texts, info, download])
        line.setCustomSpacing(0, after: texts)
        line.setCustomSpacing(0, after: info)
        tap.addSubview(line)
        line.pinEdges(to: tap, insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 8))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImageLoader.shared.clear(still)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = item.card, let r = item.row else { return }
        remember(item)
        tap.accessibilityLabel = c.title
        thumb.backgroundColor = Paint.plate(c.title)
        ImageLoader.shared.load(still, urls: c.images, size: CGSize(width: EpisodeCell.thumbW, height: EpisodeCell.thumbH))
        number.text = c.rank > 0 ? String(c.rank) : nil
        number.isHidden = c.rank <= 0
        number.textColor = colors.ink
        number.rounded(colors.canvas.alpha(0.95), radius: 6)
        check.isHidden = !c.watched
        if c.watched {
            check.backgroundColor = Palette.emerald.alpha(0.22)
            check.layer.borderColor = Palette.emerald.alpha(0.4).cgColor
            checkIcon.image = Icons.image("check", size: 12, weight: 3)
            checkIcon.tintColor = Palette.mint
        }
        rating.removeAllSubviews()
        if let v = c.rating {
            let b = Paint.ratingBadge(v, size: 9.5, colors: colors)
            rating.addSubview(b)
            b.pinEdges(to: rating)
        }
        rating.isHidden = c.rating == nil
        track.isHidden = c.progress <= 0.01
        track.backgroundColor = UIColor.black.alpha(0.55)
        bar.backgroundColor = colors.accent
        barW.constant = floor(EpisodeCell.thumbW * Swift.min(Swift.max(c.progress, 0.02), 1))

        title.text = c.title
        title.textColor = colors.ink
        badge.text = c.kicker
        badge.isHidden = (c.kicker ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        badge.textColor = colors.canvas
        badge.rounded(colors.accent, radius: 6)
        sub.text = c.sub
        sub.isHidden = (c.sub ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        sub.textColor = colors.subtle
        desc.textColor = colors.muted
        desc.setStyled(c.desc ?? "", lineHeight: 1.2)
        desc.isHidden = (c.desc ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        info.isHidden = r.noInfo
        info.accessibilityLabel = m.label("episodeInfo", "Episode details")
        infoIcon.image = Icons.image("eye", size: 18)
        infoIcon.tintColor = colors.subtle
        download.isHidden = !c.play
        download.accessibilityLabel = m.label("download", "Download")
        downloadIcon.image = Icons.image("download", size: 18)
        downloadIcon.tintColor = colors.subtle
    }
}
