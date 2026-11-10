import UIKit

/**
 * What a screen shows over its list (Android: NativeHome's dialogs and stage): the page's menu
 * sliding up from the bottom, a toast, a question with a text field, a full-screen step (the play
 * picker's connecting / peer-to-peer…), and pictures full screen.
 */
final class ScreenOverlays {
    private unowned let screen: NativeScreen

    private var sheet: SheetView?
    private var sheetKey = ""
    private var toastShown = -1
    private var promptAlert: UIAlertController?
    private var promptKey: String?
    private let stage = UIView()
    private var stageKey: String?

    init(screen: NativeScreen) {
        self.screen = screen
        stage.isHidden = true
        stage.backgroundColor = .black
        screen.addSubview(stage)
        stage.pinEdges(to: screen)
    }

    private var colors: HomeColors { screen.colors }
    private var rtl: Bool { screen.rtl }

    private func act(_ a: String, row: String? = nil, i: Int? = nil, what: String? = nil, text: String? = nil) {
        screen.act(a, row: row, i: i, what: what, text: text)
    }

    /// A new model: its menu, step, toast and question.
    func apply(_ m: HomeModel) {
        bindSheet(m.sheet)
        bindStage(m.stage)
        bindToast(m.toast)
        bindPrompt(m.prompt)
    }

    /// The screen came on (its menu, waiting for that, opens now).
    func shown() {
        bindSheet(screen.model?.sheet)
    }

    /// The screen stepped aside: its menu and question close (and the page hears so).
    func hidden() {
        screen.endEditing(true)
        if let s = sheet {
            sheet = nil
            sheetKey = ""
            s.close(animated: false)
            act("sheet", what: "")
        }
        if let a = promptAlert, let key = promptKey {
            promptAlert = nil
            promptKey = nil
            a.dismiss(animated: false)
            act("prompt", what: key)
        }
    }

    /// The list moved.
    func scrolled() {}

    // MARK: - The "…" menu

    /**
     * The page's menu sliding up from the bottom over a dimmed screen: it scrolls when it's long,
     * a tap outside closes it, the page keeps its place.
     */
    private func bindSheet(_ s: HomeSheet?) {
        guard let s else {
            // Closed because the page said so: the page isn't told back.
            sheet?.close(animated: true)
            sheet = nil
            sheetKey = ""
            return
        }
        // Opened once the screen is up.
        guard !screen.isHidden, let host = screen.window else { return }
        if sheet == nil || s.key != sheetKey {
            sheet?.close(animated: false)
            sheetKey = s.key
            let v = SheetView(colors: colors) { [weak self] in
                // Closed by a tap outside.
                guard let self else { return }
                self.sheet = nil
                self.sheetKey = ""
                self.act("sheet", what: "")
            }
            sheet = v
            v.open(in: host)
        }
        sheet?.fill(s, colors: colors, rtl: rtl) { [weak self] id in self?.act("sheet", what: id) }
    }

    // MARK: - Toast and question

    private func bindToast(_ t: HomeToast?) {
        guard let t, t.id != toastShown else { return }
        toastShown = t.id
        guard screen.isShowing else { return }
        showToast(t.text)
    }

    /// A short message near the bottom, gone after a moment.
    func showToast(_ text: String) {
        let l = PadLabel(text, size: 14, color: colors.ink, insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16), lines: 3)
        l.textAlignment = .center
        l.rounded(colors.surface.alpha(0.96), radius: 18, stroke: 1, strokeColor: colors.ink.alpha(0.1))
        l.clipsToBounds = true
        l.alpha = 0
        screen.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: screen.bottomAnchor, constant: -24),
            l.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -48),
        ])
        UIView.animate(withDuration: 0.18, animations: { l.alpha = 1 }, completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 2.2, options: [], animations: { l.alpha = 0 }, completion: { _ in l.removeFromSuperview() })
        })
    }

    private func bindPrompt(_ p: HomePrompt?) {
        guard let p else {
            promptKey = nil
            if let a = promptAlert {
                promptAlert = nil
                a.dismiss(animated: true)
            }
            return
        }
        if p.key == promptKey, promptAlert?.presentingViewController != nil { return }
        promptAlert?.dismiss(animated: false)
        promptKey = p.key
        let a = UIAlertController(title: p.title, message: nil, preferredStyle: .alert)
        a.addTextField { f in
            f.text = p.text
            f.placeholder = p.hint
            f.keyboardType = .URL
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: p.cancel, style: .cancel) { [weak self, weak a] _ in
            guard let self, self.promptAlert === a else { return }
            self.promptAlert = nil
            self.act("prompt", what: p.key)
        })
        a.addAction(UIAlertAction(title: p.ok, style: .default) { [weak self, weak a] _ in
            guard let self, self.promptAlert === a else { return }
            let text = a?.textFields?.first?.text ?? ""
            self.promptAlert = nil
            self.act("prompt", what: p.key, text: text)
        })
        promptAlert = a
        topController(from: screen)?.present(a, animated: true)
    }

    /// A row's new name; empty (or "Reset name") = its own name again.
    func renameRow(_ m: HomeModel, _ row: HomeRow, _ ed: RowEdit) {
        let a = UIAlertController(title: m.label("rename", "Rename row"), message: nil, preferredStyle: .alert)
        a.addTextField { f in
            f.text = row.title
            f.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: m.label("cancel", "Cancel"), style: .cancel))
        if ed.renamed {
            a.addAction(UIAlertAction(title: m.label("resetName", "Reset name"), style: .destructive) { [weak self] _ in
                self?.act("edit", row: row.key, what: "rename", text: "")
            })
        }
        a.addAction(UIAlertAction(title: m.label("save", "Save"), style: .default) { [weak self, weak a] _ in
            let text = (a?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            self?.act("edit", row: row.key, what: "rename", text: text)
        })
        topController(from: screen)?.present(a, animated: true)
    }

    // MARK: - Pictures full screen

    /// Pictures full screen, swiped through; a tap closes them.
    func showStills(_ urls: [String], start: Int) {
        guard !urls.isEmpty, let host = screen.window else { return }
        StillsView(urls: urls, start: Swift.min(Swift.max(start, 0), urls.count - 1)).open(in: host)
    }

    // MARK: - A full-screen step

    private func bindStage(_ s: PkStage?) {
        stage.removeAllSubviews()
        guard let s else {
            stage.isHidden = true
            stageKey = nil
            return
        }
        stage.isHidden = false
        screen.bringSubviewToFront(stage)
        let width = screen.metrics.width
        let art = s.look == "art"
        let white = UIColor.white
        if art && !s.backdrop.isEmpty {
            // The page's blur: a small picture, blurred and darkened.
            let bg = NetImageView()
            bg.alpha = 0.35
            stage.addSubview(bg)
            bg.pinEdges(to: stage)
            ImageLoader.shared.load(bg, urls: s.backdrop, size: CGSize(width: 96, height: 54))
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
            stage.addSubview(blur)
            blur.pinEdges(to: stage)
            let shade = ShadeView([UIColor.black.alpha(0.68), UIColor.black.alpha(0.58), UIColor.black.alpha(0.85)])
            stage.addSubview(shade)
            shade.pinEdges(to: stage)
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        stage.addSubview(scroll)
        scroll.pinEdges(to: stage)

        func text(_ t: String, _ size: CGFloat, _ color: UIColor, bold: Bool = false) -> UILabel {
            let l = makeLabel(size: size, color: color, weight: bold ? .bold : .regular, lines: 0)
            l.setStyled(t, lineHeight: 1.3)
            if art { l.textAlignment = .center }
            return l
        }
        func capsText(_ t: String, _ size: CGFloat, _ color: UIColor, spacing: CGFloat) -> UILabel {
            let l = makeLabel(size: size, color: color, weight: .bold, lines: 0)
            l.setCaps(t, spacing: spacing, rtl: rtl)
            if art { l.textAlignment = .center }
            return l
        }

        if art {
            let col = UIStackView(axis: .vertical, spacing: 0, alignment: .center)
            func add(_ v: UIView, _ top: CGFloat, full: Bool = true) {
                col.add(v, gap: top)
                if full { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
            }
            if let p = s.pill {
                let l = PadLabel(size: 11, color: Palette.danger, weight: .bold, insets: UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))
                l.setCaps(p.text, spacing: 0.24, rtl: rtl)
                l.rounded(Palette.danger.alpha(0.2), radius: 13, stroke: 1, strokeColor: Palette.danger.alpha(0.4))
                l.clipsToBounds = true
                add(l, 28, full: false)
            }
            if s.check {
                let ring = UIView()
                ring.translatesAutoresizingMaskIntoConstraints = false
                ring.rounded(Palette.green.alpha(0.12), radius: 40, stroke: 1, strokeColor: Palette.green.alpha(0.35))
                ring.sized(w: 80, h: 80)
                let disc = UIView()
                disc.translatesAutoresizingMaskIntoConstraints = false
                disc.rounded(Palette.emerald.alpha(0.9), radius: 28)
                disc.sized(w: 56, h: 56)
                ring.addSubview(disc)
                disc.centerIn(ring)
                let ic = Icons.view("check", size: 30, tint: .black)
                disc.addSubview(ic)
                ic.centerIn(disc)
                add(ring, 0, full: false)
            }
            if !s.logo.isEmpty || s.logoText != nil {
                let lw = floor(width * 0.72)
                let lh: CGFloat = 150
                let box = UIView()
                box.translatesAutoresizingMaskIntoConstraints = false
                let name = text(s.logoText ?? "", 36, white)
                name.font = Fonts.display(36)
                box.addSubview(name)
                name.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    name.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                    name.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                    name.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                    box.heightAnchor.constraint(greaterThanOrEqualTo: name.heightAnchor),
                ])
                if !s.logo.isEmpty {
                    let img = NetImageView()
                    img.contentMode = .scaleAspectFit
                    box.addSubview(img)
                    img.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        img.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                        img.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                        img.widthAnchor.constraint(equalToConstant: lw),
                        img.heightAnchor.constraint(equalToConstant: lh),
                        box.heightAnchor.constraint(greaterThanOrEqualToConstant: lh),
                    ])
                    name.alpha = 0
                    ImageLoader.shared.load(img, urls: s.logo, size: CGSize(width: lw, height: lh)) { ok in
                        img.isHidden = !ok
                        name.alpha = ok ? 0 : 1
                    }
                }
                add(box, 28)
                // A slow pulse while it waits.
                UIView.animate(withDuration: 1.1, delay: 0, options: [.autoreverse, .repeat, .allowUserInteraction], animations: { box.alpha = 0.55 })
            }
            if let line = s.line { add(capsText(line, 12.5, white.alpha(0.7), spacing: 0.32), 24) }
            if let t = s.title {
                let l = text(t, s.titleSize, white)
                l.font = Fonts.display(s.titleSize)
                l.setStyled(t, lineHeight: 1.06)
                l.textAlignment = .center
                add(l, 24)
            }
            if let b = s.body { add(text(b, 14.5, white.alpha(0.75)), 20) }
            if let b = s.box {
                let inner = UIStackView(axis: .vertical, spacing: 8, alignment: .fill)
                let t = text(b.title, 13, white.alpha(0.9))
                t.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                t.numberOfLines = 2
                t.lineBreakMode = .byTruncatingTail
                t.textAlignment = .center
                inner.addArrangedSubview(t)
                var metaViews: [UIView] = []
                if let sd = b.seeders {
                    metaViews.append(UIStackView(axis: .horizontal, spacing: 5, alignment: .center, views: [
                        Icons.view("users", size: 12, tint: white.alpha(0.8)),
                        makeLabel(sd, size: 12, color: white.alpha(0.8)),
                    ]))
                }
                for m in b.meta { metaViews.append(makeLabel(m, size: 12, color: white.alpha(0.6))) }
                if !metaViews.isEmpty {
                    let meta = FlowView(gapX: 12, gapY: 4)
                    meta.centerLines = true
                    meta.middle = true
                    meta.maxWidth = Swift.min(width, 640) - 56 - 36
                    meta.set(metaViews)
                    inner.addArrangedSubview(meta)
                }
                add(Paint.boxed(inner, insets: UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18), color: white.alpha(0.06), radius: 16, stroke: 1, strokeColor: white.alpha(0.1)), 24)
            }
            if let tg = s.toggle {
                let b = TapButton { [weak self] in self?.act("stage", what: "toggle") }
                let box = UIView()
                box.translatesAutoresizingMaskIntoConstraints = false
                box.sized(w: 17, h: 17)
                if tg.on {
                    box.rounded(colors.accent, radius: 4)
                    let ic = Icons.view("check", size: 12, tint: colors.canvas)
                    box.addSubview(ic)
                    ic.centerIn(box)
                } else {
                    box.rounded(.clear, radius: 4, stroke: 2, strokeColor: white.alpha(0.5))
                }
                let row = UIStackView(axis: .horizontal, spacing: 10, alignment: .center, views: [box, makeLabel(tg.label, size: 13, color: white.alpha(0.7))])
                row.isUserInteractionEnabled = false
                b.addSubview(row)
                row.pinEdges(to: b, insets: UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 10))
                b.accessibilityLabel = tg.label
                add(b, 20, full: false)
            }
            if let cap = s.spinner {
                let sp = UIActivityIndicatorView(style: .large)
                sp.color = white.alpha(0.85)
                sp.startAnimating()
                sp.translatesAutoresizingMaskIntoConstraints = false
                add(sp, 28, full: false)
                add(capsText(cap, 12.5, white.alpha(0.7), spacing: 0.18), 10)
            }
            if let n = s.notice { add(text(n, 13, Palette.amber200.alpha(0.8)), 20) }
            if let sub = s.sub { add(text(sub, 14, white.alpha(0.75)), 10) }
            if let l = s.label { add(capsText(l, 12, white.alpha(0.45), spacing: 0.2), 8) }
            if let f = s.foot { add(text(f, 13, white.alpha(0.55)), 24) }
            if !s.buttons.isEmpty {
                let row = FlowView(gapX: 12, gapY: 12)
                row.centerLines = true
                row.middle = true
                row.maxWidth = Swift.min(width, 640) - 56
                row.set(s.buttons.map { b in
                    Paint.pkButton(b, height: 48, radius: 12, colors: colors, rtl: rtl) { [weak self] in self?.act("stage", what: b.id) }
                })
                add(row, 28)
            }
            col.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(col)
            let colW = Swift.min(width, 640) - 56
            NSLayoutConstraint.activate([
                col.widthAnchor.constraint(equalToConstant: colW),
                col.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
                col.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor, constant: 56),
                col.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.bottomAnchor, constant: s.cancel != nil ? -120 : -56),
                scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                // Centred when it fits.
                scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            ])
            let mid = col.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor)
            mid.priority = .defaultHigh
            mid.isActive = true
            let fit = scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: col.heightAnchor, constant: s.cancel != nil ? 176 : 112)
            fit.priority = .defaultLow
            fit.isActive = true
            if let c = s.cancel {
                let b = Paint.pkButton(PkButton(id: c.id, label: c.label, style: "glass", icon: "x"), height: 44, radius: 22, colors: colors, rtl: rtl) { [weak self] in
                    self?.act("stage", what: c.id)
                }
                b.rounded(UIColor.black.alpha(0.45), radius: 22, stroke: 1, strokeColor: white.alpha(0.15))
                stage.addSubview(b)
                NSLayoutConstraint.activate([
                    b.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
                    b.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -40),
                ])
            }
        } else {
            // A card on black: "Harbor", the heading, the text, the reasons, then the buttons.
            let card = UIStackView(axis: .vertical, spacing: 0, alignment: .fill)
            card.isLayoutMarginsRelativeArrangement = true
            card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 28, leading: 28, bottom: 24, trailing: 28)
            card.rounded(colors.surface, radius: 16, stroke: 1, strokeColor: colors.ink.alpha(0.08))
            if let k = s.kicker {
                let l = makeLabel(size: 11, color: colors.subtle, weight: .bold)
                l.setCaps(k, spacing: 0.28, rtl: rtl)
                card.add(l)
            }
            if let t = s.title {
                let l = makeLabel(size: s.titleSize, color: colors.ink, weight: .bold, lines: 0)
                l.setStyled(t, lineHeight: 1.15)
                card.add(l, gap: 12)
            }
            if let b = s.body {
                let l = makeLabel(size: 14, color: colors.muted, lines: 0)
                l.setStyled(b, lineHeight: 1.35)
                card.add(l, gap: 12)
            }
            for (i, b) in s.bullets.enumerated() {
                let l = makeLabel(size: 13.5, color: colors.muted, lines: 0)
                l.setStyled(b, lineHeight: 1.3)
                card.add(l, gap: i == 0 ? 12 : 6)
            }
            for (i, b) in s.buttons.enumerated() {
                let v = Paint.pkButton(b, height: b.style == "link" ? 40 : 44, radius: 22, colors: colors, rtl: rtl) { [weak self] in
                    self?.act("stage", what: b.id)
                }
                card.add(v, gap: i == 0 ? 28 : b.style == "link" ? 4 : 10)
            }
            scroll.addSubview(card)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: Swift.min(width - 48, 448)),
                card.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
                card.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor, constant: 32),
                card.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
                scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            ])
            let mid = card.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor)
            mid.priority = .defaultHigh
            mid.isActive = true
            let fit = scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: card.heightAnchor, constant: 64)
            fit.priority = .defaultLow
            fit.isActive = true
        }
        stage.setDirection(rtl: rtl)
        stageKey = (s.title ?? "") + "|" + (s.spinner ?? "")
    }
}

/// The page's menu: a panel sliding up over a dimmed window.
final class SheetView: UIView {
    private let panel = UIView()
    private let scroll = UIScrollView()
    private let list = UIStackView(axis: .vertical, alignment: .fill)
    private var scrollH: NSLayoutConstraint!
    private let onOutside: () -> Void
    private var closing = false

    init(colors: HomeColors, onOutside: @escaping () -> Void) {
        self.onOutside = onOutside
        super.init(frame: .zero)
        backgroundColor = UIColor.black.alpha(0.6)
        let shadeTap = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        shadeTap.cancelsTouchesInView = false
        addGestureRecognizer(shadeTap)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = colors.surface
        panel.layer.cornerRadius = 22
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(panel)
        let handle = UIView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.rounded(colors.ink.alpha(0.25), radius: 2)
        panel.addSubview(handle)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        panel.addSubview(scroll)
        scroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        scrollH = scroll.heightAnchor.constraint(equalTo: list.heightAnchor)
        scrollH.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.75),
            handle.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            handle.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            handle.widthAnchor.constraint(equalToConstant: 36),
            handle.heightAnchor.constraint(equalToConstant: 4),
            scroll.topAnchor.constraint(equalTo: handle.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            scrollH,
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Only taps outside the panel close it (its buttons keep theirs).
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UITapGestureRecognizer { return !panel.frame.contains(g.location(in: self)) }
        return true
    }

    @objc private func outside(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if panel.frame.contains(p) { return }
        close(animated: true)
        onOutside()
    }

    func open(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        pinEdges(to: host)
        host.layoutIfNeeded()
        alpha = 0
        panel.transform = CGAffineTransform(translationX: 0, y: 320)
        UIView.animate(withDuration: 0.16) { self.alpha = 1 }
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut, animations: { self.panel.transform = .identity })
    }

    func close(animated: Bool) {
        guard !closing else { return }
        closing = true
        guard animated else {
            removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 0
            self.panel.transform = CGAffineTransform(translationX: 0, y: 200)
        }, completion: { _ in self.removeFromSuperview() })
    }

    func fill(_ s: HomeSheet, colors: HomeColors, rtl: Bool, onTap: @escaping (String) -> Void) {
        list.removeAllArranged()
        for it in s.items {
            if it.divider {
                let line = UIView()
                line.translatesAutoresizingMaskIntoConstraints = false
                line.backgroundColor = colors.ink.alpha(0.08)
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                list.addArrangedSubview(padded(line, top: 6, leading: 16, bottom: 6, trailing: 16))
                continue
            }
            let fg: UIColor = it.danger ? Palette.danger : it.active ? colors.accent : it.indent ? colors.muted : colors.ink
            let icon: String?
            switch it.icon {
            case "bookmark": icon = "bookmark"
            case "bookmark-check": icon = "bookmark_check"
            case "info": icon = "info"
            case "list-checks": icon = "list_checks"
            case "list-plus": icon = "list_plus"
            case "users": icon = "users"
            case "pencil": icon = "pencil"
            case "calendar": icon = "calendar"
            case "plus": icon = "plus"
            case "eye": icon = "eye"
            case "eye-off": icon = "eye_off"
            case "check": icon = "check"
            case "star": icon = "star"
            case "play": icon = "play"
            case "x": icon = "x"
            case "retry": icon = "rotate_cw"
            case "download": icon = "download"
            default: icon = it.danger ? "trash_2" : nil
            }
            let id = it.id
            let b = TapButton { onTap(id) }
            b.pressScale = 0.99
            b.accessibilityLabel = it.label
            let row = UIStackView(axis: .horizontal, spacing: 18, alignment: .center)
            row.isUserInteractionEnabled = false
            if let icon { row.addArrangedSubview(Icons.view(icon, size: 20, tint: it.active || it.danger ? fg : colors.muted)) }
            let label = makeLabel(it.label, size: it.indent ? 14 : 16, color: fg)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)
            if it.group {
                let chev = Icons.view("chevron_down", size: 18, tint: colors.muted)
                if it.open { chev.transform = CGAffineTransform(rotationAngle: .pi) }
                row.addArrangedSubview(chev)
            } else if it.active && (it.indent || icon == nil) {
                row.addArrangedSubview(Icons.view("check", size: 16, tint: colors.ink))
            }
            b.addSubview(row)
            row.pinEdges(to: b, insets: UIEdgeInsets(top: 0, left: it.indent ? 58 : 24, bottom: 0, right: 20))
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: it.indent ? 46 : 54).isActive = true
            list.addArrangedSubview(b)
        }
        panel.setDirection(rtl: rtl)
    }
}

/// Pictures full screen, swiped through; a tap closes them.
final class StillsView: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let urls: [String]
    private let start: Int
    private var pages: [NetImageView] = []

    init(urls: [String], start: Int) {
        self.urls = urls
        self.start = start
        super.init(frame: .zero)
        backgroundColor = .black
        scroll.isPagingEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = self
        addSubview(scroll)
        scroll.pinEdges(to: self)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func open(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        pinEdges(to: host)
        host.layoutIfNeeded()
        let size = host.bounds.size
        scroll.contentSize = CGSize(width: size.width * CGFloat(urls.count), height: size.height)
        for i in urls.indices {
            let v = NetImageView()
            v.contentMode = .scaleAspectFit
            v.frame = CGRect(x: size.width * CGFloat(i), y: 0, width: size.width, height: size.height)
            scroll.addSubview(v)
            pages.append(v)
        }
        scroll.contentOffset = CGPoint(x: size.width * CGFloat(start), y: 0)
        loadAround(start)
        alpha = 0
        UIView.animate(withDuration: 0.18) { self.alpha = 1 }
    }

    /// The picture on screen and its neighbours.
    private func loadAround(_ i: Int) {
        for j in Swift.max(0, i - 1)...Swift.min(urls.count - 1, i + 1) where pages[j].image == nil {
            ImageLoader.shared.load(pages[j], urls: [urls[j]], size: bounds.size)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard bounds.width > 0 else { return }
        loadAround(Int(round(scroll.contentOffset.x / bounds.width)))
    }

    @objc private func close() {
        UIView.animate(withDuration: 0.16, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }
}
