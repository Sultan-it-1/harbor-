import UIKit

/// A cell that is one tappable line (a tap opens, a long press asks for the menu).
class LineCell: SectionCell {
    let tap = TapButton()
    var rowKey = ""
    var index = -1

    override func setUp() {
        tap.pressScale = 0.98
        tap.onTap = { [weak self] in self?.tapped() }
        tap.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        contentView.addSubview(tap)
        build()
    }

    /// Builds the line inside [tap] (and places [tap] in the cell).
    func build() {}

    func tapped() { act("open", row: rowKey, i: index) }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { act("hold", row: rowKey, i: index) }
    }

    func remember(_ item: ScreenItem) {
        rowKey = item.row?.key ?? ""
        index = item.index
    }
}

/// A title in a list (search results): its small poster, the name, the line under it.
final class ListItemCell: LineCell {
    private let thumb = NetImageView()
    private let title = makeLabel(size: 16, weight: .bold)
    private let sub = makeLabel(size: 12.5)

    override func build() {
        tap.pinInCell(contentView)
        thumb.layer.cornerRadius = 12
        thumb.sized(w: 64, h: 96)
        let texts = UIStackView(axis: .vertical, spacing: 4, views: [title, sub])
        let line = UIStackView(axis: .horizontal, spacing: 16, alignment: .center, views: [thumb, texts])
        line.isUserInteractionEnabled = false
        tap.addSubview(line)
        line.pinEdges(to: tap, insets: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImageLoader.shared.clear(thumb)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = item.card else { return }
        remember(item)
        tap.accessibilityLabel = c.title
        thumb.backgroundColor = Paint.plate(c.title)
        ImageLoader.shared.load(thumb, urls: c.images, size: CGSize(width: 64, height: 96))
        title.text = c.title
        title.textColor = colors.ink
        sub.text = c.sub
        sub.isHidden = (c.sub ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        sub.textColor = colors.muted
    }
}

/// A winner in an award's category: the year in the award's colour, the title (a tap opens it),
/// who won it, a faint line under it.
final class WinnerCell: LineCell {
    private let year = makeLabel(size: 14, weight: .bold)
    private let title = makeLabel(size: 14, lines: 2)
    private let desc = makeLabel(size: 13, lines: 2)
    private let rule = UIView()

    override func build() {
        tap.pinInCell(contentView, leading: 20, trailing: 20)
        year.font = Fonts.digits(14, .bold)
        year.sized(w: 56)
        let texts = UIStackView(axis: .vertical, spacing: 3, views: [title, desc])
        let line = UIStackView(axis: .horizontal, spacing: 16, alignment: .center, views: [year, texts])
        line.isUserInteractionEnabled = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.isUserInteractionEnabled = false
        tap.addSubview(line)
        tap.addSubview(rule)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: tap.topAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: tap.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: tap.trailingAnchor),
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            rule.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 10),
            rule.leadingAnchor.constraint(equalTo: tap.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: tap.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: tap.bottomAnchor),
        ])
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = item.card else { return }
        remember(item)
        tap.accessibilityLabel = [c.sub, c.title].compactMap { $0 }.joined(separator: " ")
        rule.backgroundColor = colors.ink.alpha(0.06)
        year.text = c.sub
        year.textColor = c.tint ?? colors.accent
        title.text = c.title
        title.textColor = colors.ink
        desc.text = c.desc
        desc.isHidden = (c.desc ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        desc.textColor = colors.muted
    }
}

/**
 * A card that does one thing, as the search page draws them: a round icon, a small label in the
 * accent colour, the title, a line under it, and a button at the end (Play) or a spinner. A tap on
 * the card sends {a:"open"}, on its button {a:"play"}.
 */
final class ActionCell: LineCell {
    private let iconBox = UIView()
    private let iconView = UIImageView()
    private let kicker = makeLabel(size: 11, weight: .bold)
    private let title = makeLabel(size: 15, weight: .bold)
    private let sub = makeLabel(size: 12.5, lines: 2)
    private let button = TapButton()
    private let buttonIcon = UIImageView()
    private let buttonText = makeLabel(size: 15, weight: .bold)
    private let spinner = Paint.spinner(.gray)

    override func build() {
        tap.pinInCell(contentView, leading: 20, bottom: 20, trailing: 20)
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconView)
        iconView.centerIn(iconBox)
        iconView.sized(w: 18, h: 18)
        iconBox.sized(w: 40, h: 40)
        iconBox.layer.cornerRadius = 20
        let texts = UIStackView(axis: .vertical, spacing: 2, views: [kicker, title, sub])
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttonIcon.translatesAutoresizingMaskIntoConstraints = false
        buttonIcon.sized(w: 17, h: 17)
        let br = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [buttonIcon, buttonText])
        br.isUserInteractionEnabled = false
        button.addSubview(br)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 44),
            br.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            br.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 20),
            br.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -22),
        ])
        button.onTap = { [weak self] in
            guard let self else { return }
            self.act("play", row: self.rowKey, i: self.index)
        }
        let line = PassthroughStack(axis: .horizontal, spacing: 14, alignment: .center, views: [iconBox, texts, button, spinner])
        line.setCustomSpacing(12, after: texts)
        for v in [iconBox, texts, spinner] as [UIView] { v.isUserInteractionEnabled = false }
        tap.addSubview(line)
        line.pinEdges(to: tap, insets: UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 16))
        line.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = item.card else { return }
        remember(item)
        let tone = c.tone ?? "accent"
        let toneColor: UIColor = tone == "danger" ? Palette.danger : tone == "plain" ? colors.ink : colors.accent
        if tone == "plain" {
            tap.rounded(colors.surface.alpha(0.4), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        } else {
            tap.rounded(toneColor.alpha(0.1), radius: 16, stroke: 1, strokeColor: toneColor.alpha(0.4))
        }
        tap.accessibilityLabel = [c.kicker, c.title].compactMap { $0 }.joined(separator: " ")
        let icon: String?
        switch c.icon {
        case "magnet": icon = "magnet"
        case "link": icon = "link_2"
        case "alert": icon = "circle_alert"
        case "sparkles": icon = "sparkles"
        case "calendar": icon = "calendar"
        case "tag": icon = "tag"
        case "crown": icon = "crown"
        case "download": icon = "download"
        default: icon = nil
        }
        iconBox.isHidden = icon == nil
        if let icon {
            iconView.image = Icons.image(icon, size: 18)
            iconView.tintColor = tone == "plain" ? colors.subtle : toneColor
            iconBox.backgroundColor = tone == "plain" ? colors.ink.alpha(0.06) : toneColor.alpha(0.2)
        }
        kicker.textColor = tone == "danger" ? colors.ink : colors.accent
        kicker.setCaps(c.kicker ?? "", spacing: 0.18, rtl: m.rtl)
        kicker.isHidden = (c.kicker ?? "").isEmpty
        let plainTitle = (c.kicker ?? "").isEmpty && tone == "plain"
        title.font = plainTitle ? Fonts.body(14) : Fonts.bold(15)
        title.text = c.title
        title.isHidden = c.title.trimmingCharacters(in: .whitespaces).isEmpty
        title.textColor = colors.ink
        sub.text = c.sub
        sub.isHidden = (c.sub ?? "").isEmpty
        sub.textColor = tone == "danger" ? colors.muted : colors.subtle
        button.isHidden = c.button == nil
        button.isEnabled = !c.busy
        button.alpha = c.busy ? 0.6 : 1
        button.rounded(colors.ink, radius: 22)
        buttonIcon.image = Icons.image("play", size: 17)
        buttonIcon.tintColor = colors.canvas
        buttonIcon.isHidden = c.busy
        buttonText.text = c.button
        buttonText.textColor = colors.canvas
        spinner.isHidden = !(c.busy && c.button == nil)
        spinner.color = colors.muted
    }
}

/**
 * A source to play, as the page lists them: the addon's round logo (or its initial), the source's
 * name, its description, its format labels, the failure line, and the round Play button. A tap
 * anywhere plays it.
 */
final class SourceCell: LineCell {
    private let logoBox = UIView()
    private let logo = NetImageView()
    private let initial = makeLabel(size: 13, weight: .bold)
    private let title = makeLabel(size: 14.5, weight: .bold, lines: 3)
    private let desc = makeLabel(size: 12.5, lines: 4)
    private let tags = FlowView(gapX: 6, gapY: 6)
    private let failed = makeLabel(size: 13, lines: 2)
    private let play = TapButton()
    private let playIcon = UIImageView()

    override func build() {
        tap.pinInCell(contentView, leading: 16, bottom: 8, trailing: 16)
        logoBox.translatesAutoresizingMaskIntoConstraints = false
        logoBox.layer.cornerRadius = 18
        logoBox.clipsToBounds = true
        logoBox.addSubview(initial)
        initial.centerIn(logoBox)
        logoBox.addSubview(logo)
        logo.pinEdges(to: logoBox)
        logoBox.sized(w: 36, h: 36)
        let mid = UIStackView(axis: .vertical, spacing: 4, views: [title, desc])
        mid.add(tags, gap: 6)
        mid.add(failed, gap: 4)
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        play.addSubview(playIcon)
        playIcon.centerIn(play)
        playIcon.sized(w: 19, h: 19)
        play.sized(w: 44, h: 44)
        play.layer.cornerRadius = 22
        play.onTap = { [weak self] in self?.tapped() }
        let topAligned = UIView()
        topAligned.translatesAutoresizingMaskIntoConstraints = false
        topAligned.addSubview(logoBox)
        NSLayoutConstraint.activate([
            logoBox.topAnchor.constraint(equalTo: topAligned.topAnchor),
            logoBox.leadingAnchor.constraint(equalTo: topAligned.leadingAnchor),
            logoBox.trailingAnchor.constraint(equalTo: topAligned.trailingAnchor),
            logoBox.bottomAnchor.constraint(lessThanOrEqualTo: topAligned.bottomAnchor),
        ])
        // Play in the middle of the card's height.
        let playBox = PassthroughView()
        playBox.translatesAutoresizingMaskIntoConstraints = false
        playBox.addSubview(play)
        NSLayoutConstraint.activate([
            play.centerYAnchor.constraint(equalTo: playBox.centerYAnchor),
            play.leadingAnchor.constraint(equalTo: playBox.leadingAnchor),
            play.trailingAnchor.constraint(equalTo: playBox.trailingAnchor),
            play.topAnchor.constraint(greaterThanOrEqualTo: playBox.topAnchor),
        ])
        let line = PassthroughStack(axis: .horizontal, spacing: 12, alignment: .fill, views: [topAligned, mid, playBox])
        tap.addSubview(line)
        line.pinEdges(to: tap, insets: UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        topAligned.isUserInteractionEnabled = false
        mid.isUserInteractionEnabled = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImageLoader.shared.clear(logo)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = item.card else { return }
        remember(item)
        let bad = c.tone == "danger"
        tap.accessibilityLabel = c.title
        tap.rounded(bad ? Palette.danger.alpha(0.05) : colors.surface.alpha(0.4), radius: 16, stroke: 1,
                    strokeColor: bad ? Palette.danger.alpha(0.4) : colors.ink.alpha(0.08))
        logoBox.backgroundColor = colors.surface
        logoBox.layer.borderWidth = 1
        logoBox.layer.borderColor = colors.ink.alpha(0.08).cgColor
        initial.text = String((c.kicker ?? c.title).trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        initial.textColor = colors.muted
        if c.images.isEmpty {
            ImageLoader.shared.clear(logo)
            logo.isHidden = true
        } else {
            logo.isHidden = false
            ImageLoader.shared.load(logo, urls: c.images, size: CGSize(width: 36, height: 36)) { [weak self] ok in self?.logo.isHidden = !ok }
        }
        title.text = c.title
        title.textColor = colors.ink
        desc.textColor = colors.muted
        desc.setStyled(c.desc ?? "", lineHeight: 1.2)
        desc.isHidden = (c.desc ?? "").isEmpty
        tags.maxWidth = metrics.width - 32 - 28 - 36 - 44 - 24
        tags.set(c.tags.map { tg in
            let l = PadLabel(tg, size: 10.5, color: colors.ink, weight: .bold, insets: UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7))
            l.rounded(colors.canvas.alpha(0.6), radius: 5, stroke: 1, strokeColor: colors.ink.alpha(0.14))
            l.clipsToBounds = true
            return l
        })
        tags.isHidden = c.tags.isEmpty
        failed.text = c.sub
        failed.isHidden = !(bad && !(c.sub ?? "").isEmpty)
        failed.textColor = Palette.danger
        play.backgroundColor = colors.accent
        play.accessibilityLabel = m.label("play", "Play")
        playIcon.image = Icons.image("play", size: 19)
        playIcon.tintColor = colors.canvas
    }
}
