import UIKit

/// A one-line text that shows [short] in place of [full] when [full] does not fit its width
/// ("+2 more", or "+2" in a narrow box).
final class FitLabel: UILabel {
    var full = "" { didSet { setNeedsLayout() } }
    var short = "" { didSet { setNeedsLayout() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let w = (full as NSString).size(withAttributes: [.font: font as Any]).width
        let want = w <= bounds.width ? full : short
        if text != want { text = want }
    }

    override var intrinsicContentSize: CGSize {
        let s = (short as NSString).size(withAttributes: [.font: font as Any])
        return CGSize(width: ceil(s.width), height: ceil(font.lineHeight))
    }
}

// MARK: - The release calendar

/// Previous month, Today, the month's name, next month (the page's bar under its title).
final class CalendarBarCell: SectionCell {
    private let prevButton = TapButton()
    private let nextButton = TapButton()
    private let today = TapButton()
    private let todayText = makeLabel(size: 13, weight: .bold)
    private let month = UIView()
    private let monthIcon = UIImageView()
    private let monthText = makeLabel(size: 14, weight: .bold)

    override func setUp() {
        for (b, what) in [(prevButton, "prev"), (nextButton, "next")] {
            let ic = UIImageView()
            ic.translatesAutoresizingMaskIntoConstraints = false
            ic.tag = 1
            b.addSubview(ic)
            ic.centerIn(b)
            ic.sized(w: 16, h: 16)
            b.sized(w: 40, h: 40)
            b.onTap = { [weak self] in self?.act("cal", what: what) }
        }
        today.onTap = { [weak self] in self?.act("cal", what: "today") }
        todayText.isUserInteractionEnabled = false
        today.addSubview(todayText)
        todayText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            today.heightAnchor.constraint(equalToConstant: 40),
            todayText.centerYAnchor.constraint(equalTo: today.centerYAnchor),
            todayText.leadingAnchor.constraint(equalTo: today.leadingAnchor, constant: 16),
            todayText.trailingAnchor.constraint(equalTo: today.trailingAnchor, constant: -16),
        ])
        monthIcon.translatesAutoresizingMaskIntoConstraints = false
        monthIcon.sized(w: 14, h: 14)
        let mrow = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [monthIcon, monthText])
        month.translatesAutoresizingMaskIntoConstraints = false
        month.addSubview(mrow)
        NSLayoutConstraint.activate([
            month.heightAnchor.constraint(equalToConstant: 40),
            mrow.centerYAnchor.constraint(equalTo: month.centerYAnchor),
            mrow.leadingAnchor.constraint(equalTo: month.leadingAnchor, constant: 12),
            mrow.trailingAnchor.constraint(equalTo: month.trailingAnchor, constant: -12),
        ])
        let bar = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [prevButton, today, month, nextButton])
        contentView.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let b = bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        b.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            b,
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = m.calendar else { return }
        let edge = colors.ink.alpha(0.1)
        for b in [prevButton, nextButton] {
            b.rounded(.clear, radius: 20, stroke: 1, strokeColor: edge)
            let left = (b === prevButton) != m.rtl
            b.accessibilityLabel = b === prevButton ? c.label("prev", "Previous month") : c.label("next", "Next month")
            let ic = b.viewWithTag(1) as? UIImageView
            ic?.image = Icons.image(left ? "chevron_left" : "chevron_right", size: 16)
            ic?.tintColor = colors.muted
        }
        todayText.text = c.label("today", "Today")
        todayText.textColor = colors.muted
        today.rounded(.clear, radius: 20, stroke: 1, strokeColor: edge)
        month.rounded(.clear, radius: 20, stroke: 1, strokeColor: edge)
        monthIcon.image = Icons.image("calendar", size: 14)
        monthIcon.tintColor = colors.subtle
        monthText.text = c.month
        monthText.textColor = colors.ink
    }
}

/**
 * The month as the page draws it: the weekdays, then a week a line, each day a box with its
 * number, how many titles, the first three (a small poster and the name; a tap opens it) and
 * "+2 more" (all of that day's). Today is outlined; the neighbouring months' days are faded.
 */
final class CalendarCell: SectionCell {
    private let head = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)
    private let weeks = UIStackView(axis: .vertical, spacing: 8)

    override func setUp() {
        head.distribution = .fillEqually
        let col = UIStackView(axis: .vertical, spacing: 8, views: [head, weeks])
        contentView.addSubview(col)
        col.pinInCell(contentView, top: 4, leading: 12, bottom: 24, trailing: 12)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let c = m.calendar else { return }
        // The weekdays.
        head.removeAllArranged()
        for d in c.weekdays {
            let l = PadLabel(size: 11, color: colors.subtle, weight: .bold, insets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0))
            l.setCaps(d, spacing: 0.16, rtl: m.rtl)
            head.addArrangedSubview(l)
        }
        // A box for each day, seven to a line.
        weeks.removeAllArranged()
        var line: UIStackView?
        for (i, cell) in c.cells.enumerated() {
            if i % 7 == 0 {
                let l = UIStackView(axis: .horizontal, spacing: 8, alignment: .fill)
                l.distribution = .fillEqually
                weeks.addArrangedSubview(l)
                line = l
            }
            line?.addArrangedSubview(day(cell, index: i, m))
        }
        // An unfinished last week keeps its days the same width.
        if let l = line {
            while l.arrangedSubviews.count < 7 && !c.cells.isEmpty {
                let v = UIView()
                v.translatesAutoresizingMaskIntoConstraints = false
                l.addArrangedSubview(v)
            }
        }
    }

    private func day(_ d: CalCell, index: Int, _ m: HomeModel) -> UIView {
        let box = UIStackView(axis: .vertical, spacing: 6, alignment: .fill)
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 3)
        box.alpha = d.inMonth ? 1 : 0.5
        if !d.inMonth {
            box.rounded(colors.canvas.alpha(0.3), radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.04))
        } else if d.today {
            box.rounded(colors.surface.alpha(0.4), radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.6))
        } else {
            box.rounded(colors.surface.alpha(0.15), radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        }
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        // The day's number whole, then how many.
        let num = makeLabel(String(d.day), size: 12.5, color: d.today ? colors.ink : d.inMonth ? colors.muted : colors.subtle, weight: .bold)
        num.font = Fonts.digits(12.5, .bold)
        num.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = UIStackView(axis: .horizontal, spacing: 2, alignment: .lastBaseline, views: [num, flexSpace()])
        if d.count > 0 { top.addArrangedSubview(makeLabel(String(d.count), size: 10.5, color: colors.subtle, weight: .bold)) }
        box.addArrangedSubview(top)
        for (k, it) in d.items.enumerated() {
            let chip = TapButton { [weak self] in self?.act("cal", i: index, what: "item", text: String(k)) }
            chip.rounded(colors.canvas.alpha(0.5), radius: 6)
            chip.accessibilityLabel = it.title
            let pic = NetImageView()
            pic.layer.cornerRadius = 3
            pic.backgroundColor = colors.surface.alpha(0.5)
            pic.sized(w: 20, h: 28)
            if !it.images.isEmpty { ImageLoader.shared.load(pic, urls: it.images, size: CGSize(width: 20, height: 28)) }
            let name = makeLabel(it.title, size: 11.5, color: colors.ink)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [pic, name])
            row.isUserInteractionEnabled = false
            chip.addSubview(row)
            row.pinEdges(to: chip, insets: UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 8))
            box.addArrangedSubview(chip)
        }
        if let more = d.more {
            // "+2 more", or "+2" when the box is too narrow for the words.
            let b = TapButton { [weak self] in self?.act("cal", i: index, what: "day") }
            let l = FitLabel()
            l.translatesAutoresizingMaskIntoConstraints = false
            l.font = Fonts.body(11)
            l.textColor = colors.subtle
            l.full = more
            l.short = String(more.split(separator: " ").first ?? Substring(more))
            l.text = l.short
            l.isUserInteractionEnabled = false
            b.addSubview(l)
            l.pinEdges(to: b, insets: UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4))
            box.addArrangedSubview(startAligned(b))
        }
        box.addArrangedSubview(flexSpace())
        return box
    }
}

// MARK: - Downloads

/// Where files are kept and how much is free, the Wi-Fi / battery cards, the season searches.
final class DownloadsTopCell: SectionCell {
    private let col = UIStackView(axis: .vertical, spacing: 0)

    override func setUp() {
        contentView.addSubview(col)
        col.pinInCell(contentView, leading: 20, bottom: 4, trailing: 20)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let d = m.downloads else { return }
        col.removeAllArranged()
        if let s = d.storage {
            col.addArrangedSubview(padded(makeLabel(s, size: 12.5, color: colors.subtle, lines: 0), bottom: 20))
        }
        for n in d.notices {
            let icon = Icons.view(n.icon == "battery" ? "battery_charging" : "wifi", size: 19, tint: colors.accent)
            let text = makeLabel(size: 12.5, color: colors.muted, lines: 0)
            text.setStyled(n.text, lineHeight: 1.15)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [icon, text])
            if let a = n.action {
                let id = n.id
                let b = TapButton { [weak self] in self?.act("dl", what: "notice", text: id) }
                b.rounded(n.actionOn ? colors.accent : colors.ink.alpha(0.1), radius: 8)
                let l = makeLabel(a, size: 12.5, color: n.actionOn ? colors.canvas : colors.ink, weight: .bold)
                l.isUserInteractionEnabled = false
                b.addSubview(l)
                NSLayoutConstraint.activate([
                    b.heightAnchor.constraint(equalToConstant: 36),
                    l.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                    l.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 12),
                    l.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -12),
                ])
                b.accessibilityLabel = a
                row.addArrangedSubview(b)
            }
            let card = n.accent
                ? Paint.boxed(row, insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16), color: colors.accent.alpha(0.1), radius: 16, stroke: 1, strokeColor: colors.accent.alpha(0.25))
                : Paint.boxed(row, insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16), color: colors.surface.alpha(0.3), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            col.addArrangedSubview(padded(card, bottom: 20))
        }
        for j in d.jobs {
            let spin = Paint.spinner(colors.subtle)
            spin.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            let text = makeLabel(j.text, size: 12.5, color: colors.muted)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let key = j.key
            let stop = Paint.iconButton("x", size: 36, iconSize: 16, tint: colors.subtle, label: j.stop) { [weak self] in
                self?.act("dl", what: "stopjob", text: key)
            }
            let row = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [spin, text, stop])
            row.setCustomSpacing(0, after: text)
            let card = Paint.boxed(row, insets: UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 8), color: colors.surface.alpha(0.4), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            col.addArrangedSubview(padded(card, bottom: 16))
        }
        col.setDirection(rtl: m.rtl)
    }
}

/// A film's download, or a show's card: its poster, name and count over its episodes' rows.
final class DownloadGroupCell: SectionCell {
    private let col = UIStackView(axis: .vertical, spacing: 0)
    private static let amber = Palette.amber300.alpha(0.85)

    override func setUp() {
        contentView.addSubview(col)
        col.pinInCell(contentView, leading: 20, bottom: 10, trailing: 20)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let d = m.downloads, item.index < d.groups.count else { return }
        let g = d.groups[item.index]
        col.removeAllArranged()
        guard let title = g.title else {
            col.rounded(nil, radius: 0)
            col.clipsToBounds = false
            if let first = g.items.first { col.addArrangedSubview(row(first)) }
            col.setDirection(rtl: m.rtl)
            return
        }
        col.rounded(colors.surface.alpha(0.25), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        col.clipsToBounds = true
        let texts = UIStackView(axis: .vertical, spacing: 0, views: [makeLabel(title, size: 14, color: colors.ink, weight: .bold)])
        if let s = g.sub { texts.addArrangedSubview(makeLabel(s, size: 11.5, color: colors.subtle)) }
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let head = UIStackView(axis: .horizontal, spacing: 12, alignment: .center, views: [poster(g.images, title, 36, 52, 6), texts])
        col.addArrangedSubview(padded(head, top: 10, leading: 12, bottom: 10, trailing: 12))
        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = colors.ink.alpha(0.05)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        col.addArrangedSubview(rule)
        let list = UIStackView(axis: .vertical, spacing: 6)
        for it in g.items { list.addArrangedSubview(row(it)) }
        col.addArrangedSubview(padded(list, top: 8, leading: 8, bottom: 8, trailing: 8))
        col.setDirection(rtl: m.rtl)
    }

    private func poster(_ urls: [String], _ seed: String, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> UIView {
        let v = NetImageView()
        v.layer.cornerRadius = r
        v.backgroundColor = Paint.plate(seed)
        v.sized(w: w, h: h)
        if !urls.isEmpty { ImageLoader.shared.load(v, urls: urls, size: CGSize(width: w, height: h)) }
        return v
    }

    private func row(_ d: DlItem) -> UIView {
        let mid = UIStackView(axis: .vertical, spacing: 0)
        let name = makeLabel(d.title, size: 14.5, color: colors.ink, weight: .bold)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = UIStackView(axis: .horizontal, spacing: 8, alignment: .lastBaseline, views: [name])
        if let s = d.side { top.addArrangedSubview(makeLabel(s, size: 12, color: colors.subtle)) }
        mid.addArrangedSubview(top)
        var info: [UIView] = []
        if d.progress >= 0 {
            // The bar: the done part (at least a sliver) and the rest.
            let bar = BarView(color: d.paused ? colors.ink.alpha(0.35) : colors.accent, track: colors.ink.alpha(0.1), radius: 3)
            bar.minimum = 0.02
            bar.progress = d.progress
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            mid.add(bar, gap: 8)
            if let s = d.stats {
                let l = makeLabel(s, size: 11.5, color: colors.muted)
                l.font = Fonts.digits(11.5, .regular)
                info.append(l)
            }
            if let n = d.note { info.append(makeLabel("· " + n, size: 11.5, color: DownloadGroupCell.amber)) }
        } else {
            if d.status == "done" { info.append(Icons.view("check", size: 13, tint: colors.accent)) }
            if let t = d.statusText {
                let c: UIColor
                switch d.status {
                case "error": c = Palette.danger
                case "canceled": c = colors.subtle
                case "interrupted": c = DownloadGroupCell.amber
                default: c = colors.muted
                }
                info.append(makeLabel(t, size: 12, color: c, lines: 0))
            }
        }
        if let s = d.subs { info.append(makeLabel("· " + s, size: 11.5, color: colors.subtle)) }
        if let a = d.subsAction {
            let id = d.id
            let b = TapButton { [weak self] in self?.act("dl", what: "subs", text: id) }
            let l = PadLabel(a, size: 11.5, color: colors.accent, weight: .bold, insets: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
            l.isUserInteractionEnabled = false
            b.addSubview(l)
            l.pinEdges(to: b)
            b.rounded(colors.accent.alpha(0.15), radius: 6)
            b.accessibilityLabel = a
            info.append(b)
        }
        if !info.isEmpty {
            let flow = FlowView(gapX: 6, gapY: 2)
            flow.middle = true
            flow.maxWidth = metrics.width - 40 - 16 - 24 - 46 - 16 - 8 - CGFloat(d.buttons.count) * 36
            flow.set(info)
            mid.add(flow, gap: 6)
        }
        mid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mid.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = UIStackView(axis: .horizontal, spacing: 16, alignment: .center, views: [
            d.compact ? poster(d.images, d.title, 30, 44, 8) : poster(d.images, d.title, 46, 68, 8),
            mid,
        ])
        line.setCustomSpacing(8, after: mid)
        for b in d.buttons {
            let id = d.id
            let what = b.id
            if b.id == "confirm" {
                let c = TapButton { [weak self] in self?.act("dl", what: "confirm", text: id) }
                c.rounded(Palette.danger.alpha(0.9), radius: 8)
                let l = makeLabel(b.label, size: 12.5, color: .white, weight: .bold)
                l.isUserInteractionEnabled = false
                c.addSubview(l)
                NSLayoutConstraint.activate([
                    c.heightAnchor.constraint(equalToConstant: 36),
                    l.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                    l.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
                ])
                c.accessibilityLabel = b.label
                line.addArrangedSubview(c)
                continue
            }
            let icon: String
            switch b.id {
            case "pause": icon = "pause"
            case "resume", "play": icon = "play"
            case "cancel": icon = "x"
            case "retry": icon = "rotate_cw"
            default: icon = "trash_2"
            }
            line.addArrangedSubview(Paint.iconButton(icon, size: 36, iconSize: 16, tint: colors.subtle, label: b.label) { [weak self] in
                self?.act("dl", what: what, text: id)
            })
        }
        return Paint.boxed(line, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12), color: colors.surface.alpha(0.4), radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
    }
}
