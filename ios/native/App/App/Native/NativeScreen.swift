import UIKit

/// What a screen remembers between models (Android: NativeHome's maps and sets).
final class ScreenMemory {
    /// How far along each row was scrolled (from its start).
    var rowScroll: [String: CGFloat] = [:]
    /// The row lengths the page was already asked to load more for.
    var askedMore: [String: Int] = [:]
    /// Which review each Critics' Pick shows.
    var criticReview: [String: Int] = [:]
    /// Which titles' synopses / headings' paragraphs are open in full.
    var synopsisOpen = Set<String>()
    var headerBodyOpen = Set<String>()
    /// The hero's slide.
    var heroPage = 0
    /// Each line's height once drawn (the list's guesses, so it doesn't jump on a new model).
    var heights: [String: CGFloat] = [:]
    /// Live TV's guide: how far its hours are scrolled (shared by the ruler and every row), for
    /// which window, and the channel count more were asked for at.
    var guideX: CGFloat = -1
    var guideKey: Int64 = 0
    var guideAskedMore = -1
    let guideStrips = NSHashTable<GuideStripView>.weakObjects()
    /// The play picker's quality note is open.
    var pkInfoOpen = false
}

/**
 * One native screen (Android: NativeHome): the page's model drawn as a list of sections (the hero,
 * rows of cards, a title's page…), with Back and Watch together at the top. Each section type is
 * a cell (Sections.swift); the overlays (menus, toasts, full-screen steps) sit over the list.
 */
final class NativeScreen: UIView, UITableViewDataSource, UITableViewDelegate {
    let page: String
    private let onAction: (JObj) -> Void
    /// Told once this screen, coming in, is fully on screen (the one it replaced can go).
    var onRevealed: (() -> Void)?

    private(set) var model: HomeModel?
    var colors: HomeColors { model?.colors ?? .standard }
    var rtl: Bool { model?.rtl ?? false }
    let memory = ScreenMemory()

    /// Sizes that follow this screen's size.
    var metrics: Metrics {
        let b = bounds.size
        let s = UIScreen.main.bounds.size
        return Metrics(width: b.width > 0 ? b.width : s.width, height: b.height > 0 ? b.height : s.height)
    }

    let table = UITableView(frame: .zero, style: .plain)
    private(set) var items: [ScreenItem] = []
    private let backButton = TapButton()
    private let backIcon = UIImageView()
    private let backLabel = makeLabel(size: 13.5, weight: .medium)
    private let togetherButton = TapButton()
    /// Fades in at the top once the page scrolls, so what scrolls under Back and Watch together
    /// doesn't show through them.
    private let topScrim = ShadeView()
    /// The overlays: menus, toasts, prompts, full-screen steps (Overlays.swift).
    lazy var overlays = ScreenOverlays(screen: self)
    /// The search field held at the top (Search.swift).
    lazy var search = ScreenSearch(screen: self)

    private var lastJson: String?
    private var lastTop = Int.min
    private var lastWidth: CGFloat = 0
    private var wanted = false
    private var lingering = false
    private var hideWork: DispatchWorkItem?

    var isShowing: Bool { !isHidden && alpha > 0.01 }

    init(page: String, onAction: @escaping (JObj) -> Void) {
        self.page = page
        self.onAction = onAction
        super.init(frame: .zero)
        isHidden = true
        alpha = 0
        clipsToBounds = true

        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.showsVerticalScrollIndicator = false
        table.contentInsetAdjustmentBehavior = .never
        table.estimatedRowHeight = 240
        table.rowHeight = UITableView.automaticDimension
        table.keyboardDismissMode = .onDrag
        table.delaysContentTouches = false
        if #available(iOS 15.0, *) { table.sectionHeaderTopPadding = 0 }
        Sections.register(in: table)
        addSubview(table)
        table.pinEdges(to: self)

        topScrim.alpha = 0
        addSubview(topScrim)
        topScrim.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topScrim.topAnchor.constraint(equalTo: topAnchor),
            topScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            topScrim.heightAnchor.constraint(equalToConstant: 104),
        ])

        // Back: a pill at the top's start.
        backButton.isHidden = true
        backButton.onTap = { [weak self] in self?.act("back") }
        backIcon.translatesAutoresizingMaskIntoConstraints = false
        backIcon.contentMode = .center
        let backStack = UIStackView(arrangedSubviews: [backIcon, backLabel])
        backStack.axis = .horizontal
        backStack.alignment = .center
        backStack.spacing = 8
        backStack.isUserInteractionEnabled = false
        backStack.translatesAutoresizingMaskIntoConstraints = false
        backButton.addSubview(backStack)
        addSubview(backButton)
        NSLayoutConstraint.activate([
            backIcon.widthAnchor.constraint(equalToConstant: 15),
            backIcon.heightAnchor.constraint(equalToConstant: 15),
            backStack.leadingAnchor.constraint(equalTo: backButton.leadingAnchor, constant: 12),
            backStack.trailingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: -20),
            backStack.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            backButton.heightAnchor.constraint(equalToConstant: 40),
            backButton.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        ])

        // Watch together: a round button at the top's end.
        togetherButton.isHidden = true
        togetherButton.onTap = { [weak self] in self?.act("together") }
        let users = Icons.view("users", size: 20, tint: .white)
        users.isUserInteractionEnabled = false
        togetherButton.addSubview(users)
        addSubview(togetherButton)
        NSLayoutConstraint.activate([
            users.centerXAnchor.constraint(equalTo: togetherButton.centerXAnchor),
            users.centerYAnchor.constraint(equalTo: togetherButton.centerYAnchor),
            togetherButton.widthAnchor.constraint(equalToConstant: 44),
            togetherButton.heightAnchor.constraint(equalToConstant: 44),
            togetherButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            togetherButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new width (rotation, split view): card sizes follow it.
        if bounds.width > 0 && abs(bounds.width - lastWidth) > 1 {
            let first = lastWidth == 0
            lastWidth = bounds.width
            if !first && model != nil {
                memory.heights.removeAll()
                table.reloadData()
            }
        }
    }

    // MARK: - The page's model

    /// A new description from the page. Nothing changed = nothing redrawn.
    func setModel(_ m: HomeModel, json: String) {
        if json == lastJson { return }
        lastJson = json
        model = m
        backgroundColor = m.colors.canvas
        topScrim.colors = [m.colors.canvas, m.colors.canvas, m.colors.canvas.alpha(0.9), m.colors.canvas.alpha(0)]
        togetherButton.rounded(m.colors.canvas.alpha(0.72), radius: 22)
        togetherButton.accessibilityLabel = m.label("together", "Watch together")
        togetherButton.isHidden = !m.showTogether
        backButton.isHidden = m.back == nil
        if let back = m.back {
            backLabel.text = back
            backLabel.textColor = m.colors.muted
            backIcon.image = Icons.image("arrow_left", size: 15)
            backIcon.tintColor = m.colors.muted
            backIcon.transform = m.rtl ? CGAffineTransform(scaleX: -1, y: 1) : .identity
            backButton.accessibilityLabel = back
            backButton.rounded(m.colors.canvas.alpha(0.85), radius: 20, stroke: 1, strokeColor: m.colors.ink.alpha(0.1))
        }
        setDirection(rtl: m.rtl)

        search.bind(m)
        items = Sections.build(m, screen: self)
        table.reloadData()
        if lastTop != Int.min && m.top != lastTop {
            table.setContentOffset(.zero, animated: false)
        }
        lastTop = m.top
        overlays.apply(m)
        // What floats at the top stays over the list.
        bringSubviewToFront(topScrim)
        bringSubviewToFront(search.bar)
        bringSubviewToFront(backButton)
        bringSubviewToFront(togetherButton)
        applyVisibility()
        DispatchQueue.main.async {
            self.placeScrim()
            self.search.place(table: self.table, items: self.items, model: self.model)
        }
    }

    /// A line changed its height in place (a paragraph opened): the list makes room.
    func refreshHeights() {
        UIView.performWithoutAnimation {
            table.beginUpdates()
            table.endUpdates()
        }
    }

    // MARK: - On screen or not

    func show(_ on: Bool, linger: Bool = false) {
        wanted = on
        applyVisibility(linger: linger)
    }

    /// A screen leaving under another: it goes now (the other is fully in).
    func dropLinger() {
        guard lingering else { return }
        hideWork?.cancel()
        hideNow()
    }

    private func hideNow() {
        lingering = false
        if !(wanted && model != nil) {
            isHidden = true
            alpha = 0
        }
    }

    private func applyVisibility(linger: Bool = false) {
        let want = wanted && model != nil
        if lingering {
            if !want { return } // on its way out already
            // Back before it left (a quick Back): on top again.
            hideWork?.cancel()
            lingering = false
            alpha = 1
            superview?.bringSubviewToFront(self)
            return
        }
        if want {
            guard isHidden || alpha < 1 else { return }
            isHidden = false
            overlays.shown()
            UIView.animate(withDuration: 0.14, animations: { self.alpha = 1 }, completion: { _ in self.onRevealed?() })
        } else if !isHidden {
            // The screen stepping aside closes its menu and keyboard (and the page hears it).
            search.endEditing()
            overlays.hidden()
            if linger {
                // Stays under the one coming in until that one is fully in (or a moment).
                lingering = true
                let work = DispatchWorkItem { [weak self] in self?.hideNow() }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
            } else {
                hideNow()
            }
        }
    }

    // MARK: - Taps to the page

    func act(_ a: String, row: String? = nil, i: Int? = nil, what: String? = nil, text: String? = nil) {
        var o: JObj = ["p": page, "a": a]
        if let row { o["row"] = row }
        if let i { o["i"] = i }
        if let what { o["what"] = what }
        if let text { o["text"] = text }
        onAction(o)
    }

    // MARK: - The list

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = Sections.cell(for: items[indexPath.row], in: tableView, at: indexPath, screen: self)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.setDirection(rtl: rtl)
        return cell
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < items.count else { return 240 }
        let item = items[indexPath.row]
        if let h = memory.heights[item.id] { return h }
        switch item.kind {
        case .top, .gap, .search, .end: return Swift.max(item.height, 1)
        case .hero, .detail: return metrics.hero
        default: return 240
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < items.count else { return }
        Sections.willDisplay(items[indexPath.row], cell: cell, screen: self)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < items.count, cell.bounds.height > 0 else { return }
        memory.heights[items[indexPath.row].id] = cell.bounds.height
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === table else { return }
        placeScrim()
        search.place(table: table, items: items, model: model)
        overlays.scrolled()
    }

    /// The top shade: none at the top of the page, full once it has scrolled a little.
    private func placeScrim() {
        topScrim.alpha = Swift.min(1, Swift.max(0, table.contentOffset.y / 64))
    }
}
