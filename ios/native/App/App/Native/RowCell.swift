import UIKit

/// [v] inside a plain view with room around it (a stack's part with its own margins).
func padded(_ v: UIView, top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0, passthrough: Bool = false) -> UIView {
    let w: UIView = passthrough ? PassthroughView() : UIView()
    w.translatesAutoresizingMaskIntoConstraints = false
    w.addSubview(v)
    v.pinEdges(to: w, insets: UIEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing))
    return w
}

/// [v] at the start of a full-width line, as wide as it wants.
func startAligned(_ v: UIView, top: CGFloat = 0, bottom: CGFloat = 0, leading: CGFloat = 0) -> UIView {
    let w = UIView()
    w.translatesAutoresizingMaskIntoConstraints = false
    v.translatesAutoresizingMaskIntoConstraints = false
    w.addSubview(v)
    NSLayoutConstraint.activate([
        v.topAnchor.constraint(equalTo: w.topAnchor, constant: top),
        v.bottomAnchor.constraint(equalTo: w.bottomAnchor, constant: -bottom),
        v.leadingAnchor.constraint(equalTo: w.leadingAnchor, constant: leading),
        v.trailingAnchor.constraint(lessThanOrEqualTo: w.trailingAnchor),
    ])
    return w
}

/// A sideways strip of views with room at both ends (chips, people, buttons).
final class SideScroll: UIView {
    let scroll = UIScrollView()
    let strip: UIStackView

    init(spacing: CGFloat, inset: CGFloat = 20, alignment: UIStackView.Alignment = .center) {
        strip = UIStackView(axis: .horizontal, spacing: spacing, alignment: alignment)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        addSubview(scroll)
        scroll.pinEdges(to: self)
        scroll.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            strip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: inset),
            strip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -inset),
            strip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            // As tall as what's in it.
            heightAnchor.constraint(equalTo: strip.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ views: [UIView]) {
        strip.removeAllArranged()
        for v in views { strip.addArrangedSubview(v) }
    }

    /// Back to the start (the reading side) once laid out.
    func toStart(rtl: Bool) {
        DispatchQueue.main.async {
            self.layoutIfNeeded()
            let maxX = Swift.max(0, self.scroll.contentSize.width - self.scroll.bounds.width)
            self.scroll.contentOffset = CGPoint(x: rtl ? maxX : 0, y: 0)
        }
    }
}

extension Paint {
    /// A person: a round photo (their initial until it comes), the name, what they're known for.
    static func personChip(name: String, image: String?, sub: String?, colors: HomeColors, onTap: @escaping () -> Void) -> UIView {
        let b = TapButton(onTap: onTap)
        b.accessibilityLabel = name
        let face = Paint.face(name: name, image: image, size: 84, initialSize: 18, colors: colors)
        let nameLabel = makeLabel(name, size: 13, color: colors.ink, weight: .bold, lines: 2)
        nameLabel.textAlignment = .center
        let col = UIStackView(axis: .vertical, spacing: 8, alignment: .center, views: [face, nameLabel])
        if let sub, !sub.trimmingCharacters(in: .whitespaces).isEmpty {
            let s = makeLabel(sub, size: 11.5, color: colors.subtle)
            s.textAlignment = .center
            col.setCustomSpacing(2, after: nameLabel)
            col.addArrangedSubview(s)
            s.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }
        nameLabel.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        col.isUserInteractionEnabled = false
        b.addSubview(col)
        col.pinEdges(to: b)
        b.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return b
    }
}

/**
 * A row (Android: RowHolder): its title line ("See all", a small note), then sideways cards; or,
 * by its kind, Critics' Pick, a title's credits, people. In the editor: its controls (up, down,
 * hide, Top 10 look, hero, rename, delete). The row's own choices (seasons) and buttons sit under
 * its title.
 */
final class RowCell: SectionCell, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UITextViewDelegate {
    private let col = UIStackView(axis: .vertical)
    private let header = TapButton()
    private let title = makeLabel(size: 17, weight: .bold)
    /// The small line under the title (a genre page's "TRENDING NOW").
    private let subLabel = makeLabel(size: 11, weight: .bold)
    private let seeAll = makeLabel(size: 12.5)
    private let controls = UIStackView(axis: .horizontal, alignment: .center)
    private var controlsWrap: UIView!
    private let rowChips = SideScroll(spacing: 8)
    private var rowChipsWrap: UIView!
    private let rowTools = SideScroll(spacing: 8)
    private var rowToolsWrap: UIView!
    private var strip: UICollectionView!
    private var stripH: NSLayoutConstraint!
    private let people = SideScroll(spacing: 10, alignment: .top)
    private let credits = UIStackView(axis: .vertical, spacing: 20)
    private var creditsWrap: UIView!
    /// Critics' Pick: its own card instead of the strip (made the first time one is shown).
    private var critic: CriticCard?

    private var row: HomeRow?
    private var boundKey: String?
    private var cardKind: CardKind = .poster
    private var cardW: CGFloat = 100
    private var itemH: CGFloat = 150

    override func setUp() {
        col.isLayoutMarginsRelativeArrangement = false
        contentView.addSubview(col)
        col.pinInCell(contentView, bottom: 26)

        // The title line: a tap opens "See all".
        header.pressScale = 1
        header.onTap = { [weak self] in
            guard let k = self?.boundKey else { return }
            self?.act("all", row: k)
        }
        let titles = UIStackView(axis: .vertical, spacing: 2, alignment: .leading, views: [title, subLabel])
        subLabel.isHidden = true
        let line = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [titles, seeAll])
        seeAll.setContentHuggingPriority(.required, for: .horizontal)
        seeAll.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.isUserInteractionEnabled = false
        header.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: header.topAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        col.addArrangedSubview(header)

        // The editor's controls.
        controls.isLayoutMarginsRelativeArrangement = true
        controls.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        let cbox = UIView()
        cbox.translatesAutoresizingMaskIntoConstraints = false
        cbox.addSubview(controls)
        controls.pinEdges(to: cbox)
        cbox.heightAnchor.constraint(equalToConstant: 44).isActive = true
        controlsWrap = UIView()
        controlsWrap.translatesAutoresizingMaskIntoConstraints = false
        controlsWrap.addSubview(cbox)
        NSLayoutConstraint.activate([
            cbox.topAnchor.constraint(equalTo: controlsWrap.topAnchor),
            cbox.bottomAnchor.constraint(equalTo: controlsWrap.bottomAnchor, constant: -10),
            cbox.leadingAnchor.constraint(equalTo: controlsWrap.leadingAnchor, constant: 20),
            cbox.trailingAnchor.constraint(lessThanOrEqualTo: controlsWrap.trailingAnchor, constant: -20),
        ])
        controlsWrap.isHidden = true
        col.addArrangedSubview(controlsWrap)

        rowChipsWrap = padded(rowChips, bottom: 12)
        rowToolsWrap = padded(rowTools, bottom: 12)
        rowChipsWrap.isHidden = true
        rowToolsWrap.isHidden = true
        col.addArrangedSubview(rowChipsWrap)
        col.addArrangedSubview(rowToolsWrap)

        // The cards.
        let layout = FlipFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 10_000
        layout.sectionInset = UIEdgeInsets(top: 4, left: 20, bottom: 4, right: 20)
        strip = UICollectionView(frame: .zero, collectionViewLayout: layout)
        strip.backgroundColor = .clear
        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceVertical = false
        strip.decelerationRate = .fast
        strip.dataSource = self
        strip.delegate = self
        for k in CardKind.allCases { strip.register(CardCell.self, forCellWithReuseIdentifier: k.rawValue) }
        strip.translatesAutoresizingMaskIntoConstraints = false
        stripH = strip.heightAnchor.constraint(equalToConstant: 200)
        stripH.isActive = true
        col.addArrangedSubview(strip)

        people.isHidden = true
        col.addArrangedSubview(people)
        creditsWrap = padded(credits, leading: 20, bottom: 8, trailing: 20)
        creditsWrap.isHidden = true
        col.addArrangedSubview(creditsWrap)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        saveScroll()
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let r = item.row else { return }
        let fresh = boundKey != r.key
        if fresh { saveScroll() }
        row = r
        boundKey = r.key
        cardKind = CardKind(r.kind)
        cardW = cardKind.width(metrics)
        var h = cardKind.boxHeight(cardW, row: r) + cardKind.extraHeight(cardW, row: r)
        if r.lead != nil { h = Swift.max(h, CardKind.lead.boxHeight(280, row: r)) }
        itemH = h
        stripH.constant = h + 8
        strip.reloadData()
        if fresh { restoreScroll() }

        title.text = r.title
        title.textColor = colors.ink
        subLabel.textColor = colors.subtle
        subLabel.setCaps(r.sub ?? "", spacing: 0.18, rtl: m.rtl)
        subLabel.isHidden = (r.sub ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let ed = m.edit ? r.edit : nil
        let hidden = ed?.hidden == true
        // The end of the title line: "See all", or the row's small note (Critics' Pick).
        seeAll.textColor = colors.subtle
        if r.seeAll && ed == nil {
            seeAll.font = Fonts.body(12.5)
            seeAll.setStyled(m.label("seeAll", "See all") + " ›")
            seeAll.isHidden = false
        } else if let note = r.note, ed == nil {
            seeAll.font = Fonts.body(10.5)
            seeAll.setCaps(note, spacing: 0.14, rtl: m.rtl)
            seeAll.isHidden = false
        } else {
            seeAll.isHidden = true
        }
        header.isEnabled = r.seeAll && ed == nil
        // A hidden row in the editor: its name dimmed and its controls, no cards.
        title.alpha = hidden ? 0.45 : 1
        bindRowChips(m, r, shown: ed == nil)
        let isCritic = r.kind == .critic
        let isCredits = r.kind == .credits
        let isLines = r.kind == .episodes || r.kind == .list || r.kind == .winners
        let isPeople = r.kind == .people
        strip.isHidden = hidden || isCritic || isCredits || isLines || isPeople || r.items.isEmpty
        if isPeople && !hidden {
            people.isHidden = false
            people.set(r.items.enumerated().map { i, c in
                Paint.personChip(name: c.title, image: c.images.first, sub: c.sub, colors: colors) { [weak self] in self?.act("open", row: r.key, i: i) }
            })
            if fresh { people.toStart(rtl: m.rtl) }
        } else {
            people.isHidden = true
        }
        // A row without a title (a title's credits): no heading line at all.
        header.isHidden = r.title.trimmingCharacters(in: .whitespaces).isEmpty && !r.seeAll && r.note == nil && ed == nil
        if isCredits && !hidden {
            creditsWrap.isHidden = false
            fillCredits(m, r)
        } else {
            creditsWrap.isHidden = true
        }
        if isCritic, let info = r.critic, !hidden, let screen {
            let card: CriticCard
            if let c = critic {
                card = c
            } else {
                card = CriticCard()
                critic = card
                col.addArrangedSubview(card)
            }
            card.isHidden = false
            card.bind(m, key: r.key, info: info, screen: screen)
        } else {
            critic?.isHidden = true
        }
        bindControls(m, r, ed)
        DispatchQueue.main.async { [weak self] in self?.maybeAskMore() }
    }

    // MARK: - The cards

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let r = row else { return 0 }
        return r.items.count + (r.lead != nil ? 1 : 0)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let isLead = row?.lead != nil && indexPath.item == 0
        let kind: CardKind = isLead ? .lead : cardKind
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: kind.rawValue, for: indexPath)
        guard let cc = cell as? CardCell, let r = row, let screen else { return cell }
        let v = cc.cardView(kind)
        if isLead, let lead = r.lead {
            v.bind(row: r, card: lead, index: -1, width: 280, screen: screen)
        } else {
            let i = indexPath.item - (r.lead != nil ? 1 : 0)
            if i >= 0 && i < r.items.count { v.bind(row: r, card: r.items[i], index: i, width: cardW, screen: screen) }
        }
        cc.setDirection(rtl: rtl)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let isLead = row?.lead != nil && indexPath.item == 0
        return CGSize(width: isLead ? 280 : cardW, height: itemH)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === strip { maybeAskMore() }
    }

    /// Near the row's end: the page loads more (once per length).
    private func maybeAskMore() {
        guard let r = row, r.more, !strip.isHidden, let screen else { return }
        let lead = r.lead != nil ? 1 : 0
        guard let last = strip.indexPathsForVisibleItems.map({ $0.item - lead }).max() else { return }
        if last < r.items.count - 6 { return }
        if screen.memory.askedMore[r.key] == r.items.count { return }
        screen.memory.askedMore[r.key] = r.items.count
        act("more", row: r.key)
    }

    /// How far along the row is (from its start, whichever side that is).
    private func saveScroll() {
        guard let k = boundKey, let screen, strip != nil else { return }
        let maxX = Swift.max(0, strip.contentSize.width - strip.bounds.width)
        let x = strip.contentOffset.x
        screen.memory.rowScroll[k] = rtl ? maxX - x : x
    }

    private func restoreScroll() {
        let saved = boundKey.flatMap { screen?.memory.rowScroll[$0] } ?? 0
        let r = rtl
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.strip.layoutIfNeeded()
            let maxX = Swift.max(0, self.strip.contentSize.width - self.strip.bounds.width)
            let fromStart = Swift.min(saved, maxX)
            self.strip.contentOffset = CGPoint(x: r ? maxX - fromStart : fromStart, y: 0)
        }
    }

    // MARK: - Editor, choices, credits

    private func bindControls(_ m: HomeModel, _ r: HomeRow, _ ed: RowEdit?) {
        controls.removeAllArranged()
        guard let ed else {
            controlsWrap.isHidden = true
            return
        }
        controlsWrap.isHidden = false
        controls.superview?.rounded(colors.surface.alpha(0.9), radius: 12, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        func button(_ icon: String, _ desc: String, enabled: Bool = true, on: Bool = false, what: String, extra: (() -> Void)? = nil) {
            let b = Paint.iconButton(icon, tint: on ? colors.accent : colors.muted, label: desc) { [weak self] in
                if let extra { extra() } else { self?.act("edit", row: r.key, what: what) }
            }
            b.isEnabled = enabled
            b.alpha = enabled ? 1 : 0.3
            if on { b.rounded(colors.accent.alpha(0.22), radius: 10) }
            controls.addArrangedSubview(b)
        }
        if !ed.pinned {
            button("arrow_up", m.label("up", "Move up"), enabled: ed.up, what: "up")
            button("arrow_down", m.label("down", "Move down"), enabled: ed.down, what: "down")
        }
        button(ed.hidden ? "eye_off" : "eye", ed.hidden ? m.label("show", "Show row") : m.label("hide", "Hide row"), on: ed.hidden, what: "hide")
        if !ed.pinned {
            if ed.numerals >= 0 { button("list_ordered", m.label("numerals", "Top 10 look"), on: ed.numerals == 1, what: "num") }
            if ed.hero >= 0 { button("sparkles", m.label("heroSource", "Feature in the hero"), on: ed.hero == 1, what: "hero") }
            button("pencil", m.label("rename", "Rename row"), on: ed.renamed, what: "rename") { [weak self] in
                self?.screen?.overlays.renameRow(m, r, ed)
            }
            if ed.delete { button("trash_2", m.label("delete", "Delete"), what: "del") }
        }
    }

    private func bindRowChips(_ m: HomeModel, _ r: HomeRow, shown: Bool) {
        let chips = shown ? r.chips : nil
        rowChipsWrap.isHidden = chips == nil
        rowChips.set((chips?.items ?? []).map { c in
            Paint.chip(c, colors: colors) { [weak self] in self?.act("rowchip", row: r.key, what: c.id) }
        })
        let tools = shown ? r.tools : []
        rowToolsWrap.isHidden = tools.isEmpty
        rowTools.set(tools.map { tl in
            let icon: String?
            switch tl.id {
            case "random": icon = "shuffle"
            case "download": icon = "download"
            case "watched": icon = "check"
            case "unwatched": icon = "rotate_ccw"
            default: icon = nil
            }
            let b = TapButton { [weak self] in self?.act("tool", row: r.key, what: tl.id) }
            b.rounded(colors.surface.alpha(0.9), radius: 18, stroke: 1, strokeColor: colors.ink.alpha(0.1))
            let line = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)
            if let icon { line.addArrangedSubview(Icons.view(icon, size: 15, tint: colors.muted)) }
            line.addArrangedSubview(makeLabel(tl.label, size: 13, color: colors.muted))
            line.isUserInteractionEnabled = false
            b.addSubview(line)
            NSLayoutConstraint.activate([
                b.heightAnchor.constraint(equalToConstant: 36),
                line.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                line.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 12),
                line.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -14),
            ])
            b.accessibilityLabel = tl.label
            return b
        })
    }

    /// A title's credits as the page writes them: a small label, then the names (a tap opens one).
    private func fillCredits(_ m: HomeModel, _ r: HomeRow) {
        credits.removeAllArranged()
        for g in r.credits {
            let label = makeLabel(size: 12, color: colors.subtle)
            label.setCaps(g.label, spacing: 0.18, rtl: m.rtl)
            let names = UITextView()
            names.isEditable = false
            names.isScrollEnabled = false
            names.backgroundColor = .clear
            names.textContainerInset = .zero
            names.textContainer.lineFragmentPadding = 0
            names.delegate = self
            names.linkTextAttributes = [.foregroundColor: colors.ink]
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.2
            p.alignment = m.rtl ? .right : .left
            let base: [NSAttributedString.Key: Any] = [.font: Fonts.body(15), .foregroundColor: colors.ink, .paragraphStyle: p]
            let text = NSMutableAttributedString()
            if !g.people.isEmpty {
                for (i, person) in g.people.enumerated() {
                    var attrs = base
                    if person.id > 0, let url = URL(string: "harbor-person://\(person.id)?row=\(r.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")") {
                        attrs[.link] = url
                    }
                    text.append(NSAttributedString(string: person.name, attributes: attrs))
                    if i < g.people.count - 1 { text.append(NSAttributedString(string: ", ", attributes: base)) }
                }
            } else {
                text.append(NSAttributedString(string: g.value ?? "", attributes: base))
            }
            names.attributedText = text
            names.translatesAutoresizingMaskIntoConstraints = false
            credits.addArrangedSubview(UIStackView(axis: .vertical, spacing: 4, views: [label, names]))
        }
    }

    func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if url.scheme == "harbor-person", let id = url.host {
            act("person", row: boundKey, what: id)
        }
        return false
    }
}
