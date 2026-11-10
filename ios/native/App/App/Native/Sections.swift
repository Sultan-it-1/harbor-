import UIKit

/// One line of a native screen's list (Android: NativeHome.Section): what it shows, from which row,
/// from which card on.
struct ScreenItem {
    enum Kind: String, CaseIterable {
        case top, detail, header, calbar, match, search, hero, tools, gap, chips, note, cwEmpty
        case guideRuler, guideRow, row, versus, pitch
        case pkStream, pkPick, pkTiers, pkDrawer, pkDiag, pkPanel, pkLoader
        case adCard, adTiles, adHero, adComm, adHead, adCats, adInst, adDetail, adInfo, adDoc
        case source, action, winner, listItem, episode, liveHero
        case gridTitle, gridPoster, gridTile, gridChannel
        case queue, calendar, dlTop, dlGroup, message, empty, end
    }

    let kind: Kind
    var row: HomeRow?
    /// The first card (a grid line), the card (a line per card), the chips group, the channel or
    /// the downloads group.
    var index = 0
    /// Spacers: how tall.
    var height: CGFloat = 0

    init(_ kind: Kind, row: HomeRow? = nil, index: Int = 0, height: CGFloat = 0) {
        self.kind = kind
        self.row = row
        self.index = index
        self.height = height
    }

    /// Stays the same while the same thing is shown (heights are remembered by it).
    var id: String { "\(kind.rawValue)|\(row?.key ?? "")|\(index)" }

    /// The card this line is about (a line per card).
    var card: HomeCard? {
        guard let items = row?.items, index >= 0, index < items.count else { return nil }
        return items[index]
    }
}

/**
 * The screen's list: which sections, in which order (Android: SectionsAdapter.submit), and the cell
 * that draws each. Parts not written yet (later phases) take no room.
 */
enum Sections {
    static func cellClass(_ k: ScreenItem.Kind) -> SectionCell.Type {
        switch k {
        case .top, .gap, .search, .end: return SpacerCell.self
        case .hero: return HeroCell.self
        case .tools: return ToolsCell.self
        case .cwEmpty, .empty: return EmptyBoxCell.self
        case .header: return HeaderCell.self
        case .chips: return ChipsCell.self
        case .row: return RowCell.self
        case .note, .gridTitle: return NoteCell.self
        case .message: return MessageCell.self
        case .gridPoster, .gridTile, .gridChannel: return GridLineCell.self
        case .queue: return QueueCell.self
        case .winner: return WinnerCell.self
        case .listItem: return ListItemCell.self
        case .action: return ActionCell.self
        case .source: return SourceCell.self
        case .detail: return DetailCell.self
        case .episode: return EpisodeCell.self
        default: return PendingCell.self
        }
    }

    static func register(in table: UITableView) {
        for k in ScreenItem.Kind.allCases {
            table.register(cellClass(k), forCellReuseIdentifier: k.rawValue)
        }
    }

    static func build(_ m: HomeModel, screen: NativeScreen) -> [ScreenItem] {
        var out: [ScreenItem] = []
        // Text at the top (no hero, or a heading above it): clear of the floating Watch together
        // and Back buttons. A heading with a picture behind it starts at the very top itself.
        let top: CGFloat
        if m.detail != nil {
            top = 0
        } else if m.search?.big == true && m.back == nil && !m.showTogether && m.header == nil {
            // Nothing floats at the top (the search screen): its field starts right there.
            top = 4
        } else if let h = m.header, !h.backdrop.isEmpty {
            top = 0
        } else if m.hero.isEmpty || m.header != nil {
            top = 64
        } else {
            top = 0
        }
        if top > 0 { out.append(ScreenItem(.top, height: top)) }
        if m.detail != nil { out.append(ScreenItem(.detail)) }
        if m.header != nil { out.append(ScreenItem(.header)) }
        if m.calendar != nil { out.append(ScreenItem(.calbar)) }
        if m.match != nil { out.append(ScreenItem(.match)) }
        if m.search != nil { out.append(ScreenItem(.search, height: 60)) }
        if !m.hero.isEmpty { out.append(ScreenItem(.hero)) }
        if m.showCustomize || m.edit {
            out.append(ScreenItem(.tools))
        } else if !m.hero.isEmpty {
            out.append(ScreenItem(.gap, height: 28))
        }
        for i in m.chips.indices { out.append(ScreenItem(.chips, index: i)) }
        if m.note != nil { out.append(ScreenItem(.note)) }
        if m.cwEmpty != nil { out.append(ScreenItem(.cwEmpty)) }
        // Live TV's guide: under the page's bar.
        if let g = m.guide {
            out.append(ScreenItem(.guideRuler))
            for i in g.channels.indices { out.append(ScreenItem(.guideRow, index: i)) }
        }
        let met = screen.metrics
        for r in m.rows {
            switch r.kind {
            case .versus:
                // Two sides' figures, a line each, in a card (the match's stats).
                if !r.title.trimmingCharacters(in: .whitespaces).isEmpty { out.append(ScreenItem(.row, row: r)) }
                for i in r.items.indices { out.append(ScreenItem(.versus, row: r, index: i)) }
            case .pitch:
                if !r.items.isEmpty { out.append(ScreenItem(.pitch, row: r)) }
            case .pk:
                // The play picker's blocks: one each, the sources' box a line per source.
                switch r.pk {
                case .streams(let s)?: for i in s.items.indices { out.append(ScreenItem(.pkStream, row: r, index: i)) }
                case .pick?: out.append(ScreenItem(.pkPick, row: r))
                case .tiers?: out.append(ScreenItem(.pkTiers, row: r))
                case .drawer?: out.append(ScreenItem(.pkDrawer, row: r))
                case .diag?: out.append(ScreenItem(.pkDiag, row: r))
                case .panel?: out.append(ScreenItem(.pkPanel, row: r))
                case .loader?: out.append(ScreenItem(.pkLoader, row: r))
                case nil: break
                }
            case .ad:
                // The Addons page's blocks: one each.
                let kind: ScreenItem.Kind?
                switch r.ad {
                case .card?: kind = .adCard
                case .tiles?: kind = .adTiles
                case .hero?: kind = .adHero
                case .community?: kind = .adComm
                case .head?: kind = .adHead
                case .categories?: kind = .adCats
                case .installed?: kind = .adInst
                case .detail?: kind = .adDetail
                case .info?: kind = .adInfo
                case .doc?: kind = .adDoc
                case nil: kind = nil
                }
                if let kind { out.append(ScreenItem(kind, row: r)) }
            case .sources:
                // A title's sources to play: a card each, down the page.
                for i in r.items.indices { out.append(ScreenItem(.source, row: r, index: i)) }
            case .action:
                // Cards that do one thing (Browse a genre, Ask AI, play a link), no heading.
                for i in r.items.indices { out.append(ScreenItem(.action, row: r, index: i)) }
            case .winners:
                // An award's category: its heading, then a line for each winner.
                out.append(ScreenItem(.row, row: r))
                for i in r.items.indices { out.append(ScreenItem(.winner, row: r, index: i)) }
            case .list:
                // Titles listed down the page (search results): the heading, then one a line.
                out.append(ScreenItem(.row, row: r))
                for i in r.items.indices { out.append(ScreenItem(.listItem, row: r, index: i)) }
            case .episodes:
                // A series' episodes: the heading (seasons, tools), then one episode a line.
                out.append(ScreenItem(.row, row: r))
                if r.edit?.hidden != true {
                    for i in r.items.indices { out.append(ScreenItem(.episode, row: r, index: i)) }
                }
            case .livehero:
                // Live TV's spotlight: one big card at a time.
                if !r.items.isEmpty { out.append(ScreenItem(.liveHero, row: r)) }
            default:
                guard r.grid else {
                    out.append(ScreenItem(.row, row: r))
                    continue
                }
                // A grid: its title, then one line of cards after another.
                let hasNote = !(r.note ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                if !r.title.trimmingCharacters(in: .whitespaces).isEmpty || hasNote { out.append(ScreenItem(.gridTitle, row: r)) }
                let cols = met.gridCols(r)
                let kind: ScreenItem.Kind = r.kind == .tile ? .gridTile : r.kind == .channel ? .gridChannel : .gridPoster
                var start = 0
                while start < r.items.count {
                    out.append(ScreenItem(kind, row: r, index: start))
                    start += cols
                }
            }
        }
        if m.queue != nil { out.append(ScreenItem(.queue)) }
        if let c = m.calendar, !c.cells.isEmpty { out.append(ScreenItem(.calendar)) }
        if let d = m.downloads {
            if d.storage != nil || !d.notices.isEmpty || !d.jobs.isEmpty { out.append(ScreenItem(.dlTop)) }
            for i in d.groups.indices { out.append(ScreenItem(.dlGroup, index: i)) }
        }
        if m.message != nil { out.append(ScreenItem(.message)) }
        if m.rows.isEmpty && m.message == nil && m.empty != nil { out.append(ScreenItem(.empty)) }
        out.append(ScreenItem(.end, height: 28))
        return out
    }

    static func cell(for item: ScreenItem, in table: UITableView, at indexPath: IndexPath, screen: NativeScreen) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: item.kind.rawValue, for: indexPath)
        if let c = cell as? SectionCell, let m = screen.model {
            c.screen = screen
            c.item = item
            c.bind(item, m)
        }
        return cell
    }

    static func willDisplay(_ item: ScreenItem, cell: UITableViewCell, screen: NativeScreen) {
        (cell as? SectionCell)?.willShow()
    }
}

/// A section's cell: told its screen (colours, sizes, where taps go) and what to show.
class SectionCell: UITableViewCell {
    weak var screen: NativeScreen?
    var item: ScreenItem?

    var colors: HomeColors { screen?.colors ?? .standard }
    var rtl: Bool { screen?.rtl ?? false }
    var metrics: Metrics { screen?.metrics ?? Metrics(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height) }
    var model: HomeModel? { screen?.model }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Builds the cell's views (once).
    func setUp() {}

    /// Shows [item] of [m].
    func bind(_ item: ScreenItem, _ m: HomeModel) {}

    /// Coming on screen.
    func willShow() {}

    func act(_ a: String, row: String? = nil, i: Int? = nil, what: String? = nil, text: String? = nil) {
        screen?.act(a, row: row, i: i, what: what, text: text)
    }
}

/// Empty room of a given height (the top, under the hero, under the search field, the end).
final class SpacerCell: SectionCell {
    private var hc: NSLayoutConstraint?

    override func setUp() {
        let v = UIView()
        contentView.addSubview(v)
        v.pinInCell(contentView)
        hc = v.heightAnchor.constraint(equalToConstant: 0)
        hc?.isActive = true
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        hc?.constant = item.height
    }
}

/// A part written in a later phase: no room for now.
final class PendingCell: SectionCell {
    override func setUp() {
        let v = UIView()
        contentView.addSubview(v)
        v.pinInCell(contentView)
        v.heightAnchor.constraint(equalToConstant: 0).isActive = true
    }
}

/// "Customize" under the hero; while the editor is open: Done, Reset (and Add source on Home).
final class ToolsCell: SectionCell {
    private let bar = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)

    override func setUp() {
        contentView.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let b = bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        b.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            b,
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
        ])
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        bar.removeAllArranged()
        if !m.edit {
            bar.addArrangedSubview(pill(m.label("customize", "Customize home"), "pencil", primary: false) { [weak self] in self?.act("customize") })
            return
        }
        if m.addSource {
            bar.addArrangedSubview(pill(m.label("addSource", "Add Source"), "plus", primary: false) { [weak self] in self?.act("addsource") })
        }
        bar.addArrangedSubview(pill(m.label("reset", "Reset"), "rotate_ccw", primary: false) { [weak self] in self?.act("reset") })
        bar.addArrangedSubview(pill(m.label("done", "Done editing"), "check", primary: true) { [weak self] in self?.act("done") })
    }

    private func pill(_ text: String, _ icon: String, primary: Bool, onTap: @escaping () -> Void) -> UIView {
        let fg = primary ? colors.canvas : colors.muted
        let b = TapButton(onTap: onTap)
        if primary {
            b.rounded(colors.ink, radius: 10)
        } else {
            b.rounded(colors.surface.alpha(0.9), radius: 10, stroke: 1, strokeColor: colors.ink.alpha(0.08))
        }
        let row = UIStackView(axis: .horizontal, spacing: 8, alignment: .center, views: [
            Icons.view(icon, size: 15, tint: fg),
            makeLabel(text, size: 13, color: fg, weight: primary ? .bold : .regular),
        ])
        row.isUserInteractionEnabled = false
        b.addSubview(row)
        NSLayoutConstraint.activate([
            b.heightAnchor.constraint(equalToConstant: 36),
            row.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -14),
        ])
        b.accessibilityLabel = text
        return b
    }
}

/// A box with a dashed outline.
final class DashedBox: UIView {
    private let dash = CAShapeLayer()

    var dashColor: UIColor = .gray {
        didSet { dash.strokeColor = dashColor.cgColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        dash.fillColor = UIColor.clear.cgColor
        dash.lineWidth = 1
        dash.lineDashPattern = [5, 4]
        layer.addSublayer(dash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 16).cgPath
    }
}

/// Continue Watching with nothing in it, or a page with nothing to show: a title and a dashed box.
final class EmptyBoxCell: SectionCell {
    private let title = makeLabel(size: 17, weight: .bold, lines: 0)
    private let box = DashedBox()
    private let bodyLabel = makeLabel(size: 15, lines: 0)

    override func setUp() {
        bodyLabel.textAlignment = .center
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(bodyLabel)
        bodyLabel.pinEdges(to: box, insets: UIEdgeInsets(top: 36, left: 20, bottom: 36, right: 20))
        let col = UIStackView(axis: .vertical, spacing: 12, views: [title, box])
        contentView.addSubview(col)
        col.pinInCell(contentView, top: 8, leading: 20, bottom: 24, trailing: 20)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        let t: String?
        let body: String
        if item.kind == .empty {
            t = m.empty?.title
            body = m.empty?.text ?? ""
        } else {
            t = m.cwEmpty?.title
            body = m.cwEmpty?.text ?? ""
        }
        title.text = t
        title.isHidden = (t ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        title.textColor = colors.ink
        bodyLabel.text = body
        bodyLabel.textColor = colors.muted
        box.dashColor = colors.ink.alpha(0.22)
    }
}

/// A row of choices (Library tab, type, sort); the chosen one is filled. Scrolls sideways.
final class ChipsCell: SectionCell {
    private let scroller = UIScrollView()
    private let strip = UIStackView(axis: .horizontal, spacing: 8, alignment: .center)

    override func setUp() {
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        contentView.addSubview(scroller)
        scroller.pinInCell(contentView, top: 2, bottom: 12)
        scroller.addSubview(strip)
        NSLayoutConstraint.activate([
            scroller.heightAnchor.constraint(equalToConstant: 36),
            strip.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            strip.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: 20),
            strip.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -20),
            strip.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
        ])
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        strip.removeAllArranged()
        guard item.index < m.chips.count else { return }
        let g = m.chips[item.index]
        for c in g.items {
            strip.addArrangedSubview(Paint.chip(c, colors: colors) { [weak self] in self?.act("chip", row: g.key, what: c.id) })
        }
    }
}

/// A line of small text (a note over the rows), or a grid's title in small capitals.
final class NoteCell: SectionCell {
    private let bodyLabel = makeLabel(size: 13, lines: 0)
    private var top: NSLayoutConstraint?
    private var bottom: NSLayoutConstraint?

    override func setUp() {
        contentView.addSubview(bodyLabel)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        let b = bodyLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        b.priority = UILayoutPriority(999)
        let t = bodyLabel.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            t, b,
            bodyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bodyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
        top = t
        bottom = b
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        if item.kind == .note {
            note(m.note ?? "")
            return
        }
        guard let r = item.row else { return }
        if let n = r.note, !n.trimmingCharacters(in: .whitespaces).isEmpty {
            note(n)
        } else {
            bodyLabel.font = Fonts.bold(13)
            bodyLabel.textColor = colors.subtle
            bodyLabel.setCaps(r.title, spacing: 0.2, rtl: m.rtl)
            top?.constant = 4
            bottom?.constant = -14
        }
    }

    private func note(_ s: String) {
        bodyLabel.font = Fonts.body(13)
        bodyLabel.textColor = colors.muted
        bodyLabel.setStyled(s)
        top?.constant = 0
        bottom?.constant = -16
    }
}

/// A centred message (no search results…) with an optional button.
final class MessageCell: SectionCell {
    private let title = makeLabel(size: 15, weight: .bold, lines: 0)
    private let bodyLabel = makeLabel(size: 13, lines: 0)
    private let button = TapButton()
    private let buttonText = makeLabel(size: 13.5, weight: .bold)

    override func setUp() {
        title.textAlignment = .center
        bodyLabel.textAlignment = .center
        button.onTap = { [weak self] in self?.act("message") }
        button.addSubview(buttonText)
        buttonText.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 40),
            buttonText.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            buttonText.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            buttonText.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
        ])
        let col = UIStackView(axis: .vertical, spacing: 10, alignment: .center, views: [title, bodyLabel, button])
        col.setCustomSpacing(16, after: bodyLabel)
        contentView.addSubview(col)
        col.pinInCell(contentView, top: 48, leading: 24, bottom: 48, trailing: 24)
    }

    override func bind(_ item: ScreenItem, _ m: HomeModel) {
        guard let g = m.message else { return }
        title.text = g.title
        title.isHidden = (g.title ?? "").isEmpty
        title.textColor = colors.ink
        bodyLabel.text = g.text
        bodyLabel.isHidden = (g.text ?? "").isEmpty
        bodyLabel.textColor = colors.subtle
        buttonText.text = g.action
        buttonText.textColor = colors.ink
        button.isHidden = (g.action ?? "").isEmpty
        button.rounded(colors.surface, radius: 20, stroke: 1, strokeColor: colors.ink.alpha(0.1))
        button.accessibilityLabel = g.action
    }
}
