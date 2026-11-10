import UIKit

/// The match page's top: the league, each side's logo, name and cards, the score, the state.
final class MatchCell: SectionCell {
    private let glow = ShadeView()
    private let col = UIStackView(axis: .vertical, spacing: 28, alignment: .center)

    override func setUp() {
        glow.isUserInteractionEnabled = false
        contentView.addSubview(glow)
        glow.pinEdges(to: contentView)
        contentView.addSubview(col)
        col.pinInCell(contentView, top: 72, leading: 16, bottom: 24, trailing: 16)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let mt = m.match else { return }
        col.removeAllArranged()
        glow.colors = [colors.accent.alpha(0.1), colors.accent.alpha(0.04), .clear]
        let pill = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)
        if mt.live {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = colors.accent
            dot.layer.cornerRadius = 4
            dot.sized(w: 8, h: 8)
            pill.addArrangedSubview(dot)
        }
        let league = makeLabel(size: 12, color: colors.accent, weight: .bold)
        league.setStyled(mt.league.uppercased(), spacing: 0.2)
        pill.addArrangedSubview(league)
        col.addArrangedSubview(Paint.boxed(pill, insets: UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16), color: colors.accent.alpha(0.1), radius: 16, stroke: 1, strokeColor: colors.accent.alpha(0.2)))

        let score = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [
            digits(mt.home.score, 44, colors.ink),
            makeLabel("-", size: 28, color: colors.subtle, weight: .bold),
            digits(mt.away.score, 44, colors.ink),
        ])
        let scoreBox = Paint.boxed(score, insets: UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20), color: colors.surface.alpha(0.5), radius: 28, stroke: 1, strokeColor: colors.ink.alpha(0.06))
        let status = PadLabel(mt.status, size: 13, color: colors.canvas, weight: .bold, insets: UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16))
        status.rounded(colors.ink, radius: 16)
        status.clipsToBounds = true
        let mid = UIStackView(axis: .vertical, spacing: 16, alignment: .center, views: [scoreBox, status])
        mid.setContentCompressionResistancePriority(.required, for: .horizontal)
        let home = side(mt.home)
        let away = side(mt.away)
        // Home on the left, away on the right, in Arabic too (as the page and scoreboards do).
        let line = LTRStack(axis: .horizontal, spacing: 8, alignment: .center, views: [home, mid, away])
        home.widthAnchor.constraint(equalTo: away.widthAnchor).isActive = true
        col.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        col.setDirection(rtl: m.rtl)
    }

    private func digits(_ s: String, _ size: CGFloat, _ color: UIColor) -> UILabel {
        let l = makeLabel(s, size: size, color: color, weight: .bold)
        l.font = Fonts.digits(size, .bold)
        return l
    }

    private func side(_ s: MatchSide) -> UIView {
        let img = NetImageView()
        img.contentMode = .scaleAspectFit
        img.sized(w: 64, h: 64)
        if let l = s.logo { ImageLoader.shared.load(img, urls: [l], size: CGSize(width: 72, height: 72)) }
        let box = Paint.boxed(img, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12), color: colors.surface.alpha(0.4), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.06))
        let name = makeLabel(s.name, size: 17, color: colors.ink, weight: .bold, lines: 2)
        name.textAlignment = .center
        let col = UIStackView(axis: .vertical, spacing: 14, alignment: .center, views: [box, name])
        if s.yellow > 0 || s.red > 0 {
            let cards = UIStackView(axis: .horizontal, spacing: 4, alignment: .center)
            func card(_ c: UIColor) {
                let v = UIView()
                v.translatesAutoresizingMaskIntoConstraints = false
                v.backgroundColor = c
                v.layer.cornerRadius = 2
                v.sized(w: 10, h: 14)
                cards.addArrangedSubview(v)
            }
            for _ in 0..<s.yellow { card(UIColor(argb: 0xFFFACC15)) }
            for _ in 0..<s.red { card(UIColor(argb: 0xFFEF4444)) }
            col.setCustomSpacing(8, after: name)
            col.addArrangedSubview(cards)
        }
        name.widthAnchor.constraint(lessThanOrEqualTo: col.widthAnchor).isActive = true
        return col
    }
}

/**
 * Two sides' figures on a line (a match's stats, a fight's tale of the tape): the home side's
 * figure, the label, the away side's; the larger one bold (green with tone "accent").
 * Card: title = label, sub = home, desc = away, rank 1 = home larger, 2 = away larger.
 */
final class VersusCell: SectionCell {
    private let box = UIView()
    private let home = makeLabel(size: 14, weight: .bold)
    private let what = makeLabel(size: 12, lines: 2)
    private let away = makeLabel(size: 14, weight: .bold)

    override func setUp() {
        contentView.addSubview(box)
        box.pinInCell(contentView, leading: 16, trailing: 16)
        box.layer.cornerRadius = 16
        home.font = Fonts.digits(14, .bold)
        away.font = Fonts.digits(14, .bold)
        away.textAlignment = .right
        what.textAlignment = .center
        home.sized(w: 64)
        away.sized(w: 64)
        let line = LTRStack(axis: .horizontal, spacing: 0, alignment: .center, views: [home, what, away])
        box.addSubview(line)
        line.pinEdges(to: box, insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = item.card, let r = item.row else { return }
        let first = item.index == 0
        let last = item.index == r.items.count - 1
        box.backgroundColor = colors.surface.alpha(0.2)
        var corners: CACornerMask = []
        if first { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if last { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        box.layer.maskedCorners = corners
        let green = c.tone == "accent"
        let win = UIColor(argb: 0xFF22C55E)
        home.text = c.sub ?? "-"
        away.text = c.desc ?? "-"
        what.text = c.title
        what.textColor = colors.subtle
        home.textColor = c.rank == 1 ? (green ? win : colors.ink) : (green ? colors.ink : colors.subtle)
        away.textColor = c.rank == 2 ? (green ? win : colors.ink) : (green ? colors.ink : colors.subtle)
        home.font = Fonts.digits(14, c.rank == 1 || green ? .bold : .regular)
        away.font = Fonts.digits(14, c.rank == 2 || green ? .bold : .regular)
    }
}

/**
 * A team's starting eleven on a half pitch, as the page draws it: the forwards at the top, the
 * keeper at the bottom, each player's photo or shirt number in a circle with their surname under
 * it, the team's short name in the corner. Row: title = team, sub = short name; cards: title =
 * surname, sub = number, images = photo, rank = the line, tint = the team's colour.
 */
final class PitchCell: SectionCell {
    private let holder = UIView()

    override func setUp() {
        contentView.addSubview(holder)
        holder.pinInCell(contentView, leading: 16, bottom: 24, trailing: 16)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row else { return }
        holder.removeAllSubviews()
        let w = Swift.min(metrics.width - 32, 384)
        let h = floor(w * 4 / 3)
        let pitch = UIView()
        pitch.translatesAutoresizingMaskIntoConstraints = false
        pitch.rounded(UIColor(argb: 0xFF2B4C30), radius: 24, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        pitch.clipsToBounds = true
        holder.addSubview(pitch)
        NSLayoutConstraint.activate([
            pitch.topAnchor.constraint(equalTo: holder.topAnchor),
            pitch.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            pitch.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            pitch.widthAnchor.constraint(equalToConstant: w),
            pitch.heightAnchor.constraint(equalToConstant: h),
        ])
        let lineColor = UIColor.white.alpha(0.2)
        func outline(_ radius: CGFloat) -> UIView {
            let v = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.rounded(.clear, radius: radius, stroke: 2, strokeColor: lineColor)
            v.isUserInteractionEnabled = false
            pitch.addSubview(v)
            return v
        }
        // The pitch's lines: its edge, the box at the top, the box and goal at the bottom.
        outline(12).pinEdges(to: pitch, insets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        let topBox = outline(12)
        let bottomBox = outline(12)
        let goal = outline(8)
        NSLayoutConstraint.activate([
            topBox.topAnchor.constraint(equalTo: pitch.topAnchor, constant: 4),
            topBox.centerXAnchor.constraint(equalTo: pitch.centerXAnchor),
            topBox.widthAnchor.constraint(equalToConstant: 192),
            topBox.heightAnchor.constraint(equalToConstant: 96),
            bottomBox.bottomAnchor.constraint(equalTo: pitch.bottomAnchor, constant: -4),
            bottomBox.centerXAnchor.constraint(equalTo: pitch.centerXAnchor),
            bottomBox.widthAnchor.constraint(equalToConstant: Swift.min(256, w - 64)),
            bottomBox.heightAnchor.constraint(equalToConstant: 128),
            goal.bottomAnchor.constraint(equalTo: pitch.bottomAnchor, constant: -4),
            goal.centerXAnchor.constraint(equalTo: pitch.centerXAnchor),
            goal.widthAnchor.constraint(equalToConstant: 96),
            goal.heightAnchor.constraint(equalToConstant: 48),
        ])
        let team = PadLabel((r.sub ?? "").uppercased(), size: 10, color: UIColor.white.alpha(0.8), weight: .bold, insets: UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
        team.rounded(UIColor.black.alpha(0.4), radius: 4)
        team.clipsToBounds = true
        pitch.addSubview(team)
        NSLayoutConstraint.activate([
            team.leadingAnchor.constraint(equalTo: pitch.leadingAnchor, constant: 8),
            team.topAnchor.constraint(equalTo: pitch.topAnchor, constant: 8),
        ])
        // A line of players per rank, the forwards first.
        let ranks = Array(Set(r.items.map { $0.rank })).sorted()
        let col = UIStackView(axis: .vertical, spacing: 4, alignment: .fill)
        col.distribution = .fillEqually
        for rank in ranks {
            let line = UIStackView(axis: .horizontal, spacing: 0, alignment: .center)
            line.distribution = .fillEqually
            for p in r.items where p.rank == rank { line.addArrangedSubview(player(p)) }
            col.addArrangedSubview(line)
        }
        pitch.addSubview(col)
        col.pinEdges(to: pitch, insets: UIEdgeInsets(top: 28, left: 8, bottom: 28, right: 8))
        holder.setDirection(rtl: m.rtl)
    }

    private func player(_ p: HomeCard) -> UIView {
        let tint = p.tint ?? colors.accent
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        let white = r > 0.95 && g > 0.95 && b > 0.95
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = tint
        dot.layer.cornerRadius = 18
        dot.layer.borderWidth = 2
        dot.layer.borderColor = colors.canvas.alpha(0.8).cgColor
        dot.clipsToBounds = true
        dot.sized(w: 36, h: 36)
        let num = makeLabel(p.sub ?? "-", size: 12, color: white ? .black : colors.canvas, weight: .bold)
        dot.addSubview(num)
        num.centerIn(dot)
        if !p.images.isEmpty {
            let img = NetImageView()
            dot.addSubview(img)
            img.pinEdges(to: dot)
            ImageLoader.shared.load(img, urls: p.images, size: CGSize(width: 36, height: 36))
        }
        let name = PadLabel(p.title, size: 10, color: .white, weight: .bold, insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        name.rounded(UIColor.black.alpha(0.4), radius: 4)
        name.clipsToBounds = true
        name.textAlignment = .center
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 72).isActive = true
        return UIStackView(axis: .vertical, spacing: 4, alignment: .center, views: [dot, name])
    }
}
