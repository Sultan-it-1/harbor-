import UIKit

/**
 * The search field (Android: NativeHome's searchBar): under the heading, then held at the top while
 * the page scrolls. Typing sends {a:"query", text} once it pauses; the keyboard's Search sends what
 * is typed, then {a:"submit"} (the page opens its top match).
 */
final class ScreenSearch: NSObject, UITextFieldDelegate {
    private unowned let screen: NativeScreen
    let bar = UIView()
    private let box = UIView()
    private var boxH: NSLayoutConstraint!
    private let icon = UIImageView()
    private var iconW: NSLayoutConstraint!
    private var iconH: NSLayoutConstraint!
    private let field = UITextField()
    private let busy = UIActivityIndicatorView(style: .medium)
    private let clear = TapButton()
    private let clearIcon = UIImageView()
    private var top: NSLayoutConstraint!
    private var key: String?
    /// What the field last told the page: other text from the page was set by the page itself.
    private var sent = ""
    private var quiet = false
    private var pending: DispatchWorkItem?

    init(screen: NativeScreen) {
        self.screen = screen
        super.init()
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(bar)
        top = bar.topAnchor.constraint(equalTo: screen.topAnchor)
        NSLayoutConstraint.activate([
            top,
            bar.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        box.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(box)
        box.pinEdges(to: bar, insets: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))
        boxH = box.heightAnchor.constraint(equalToConstant: 44)
        boxH.isActive = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        iconW = icon.widthAnchor.constraint(equalToConstant: 16)
        iconH = icon.heightAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([iconW, iconH])
        field.borderStyle = .none
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.delegate = self
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        busy.hidesWhenStopped = true
        clearIcon.translatesAutoresizingMaskIntoConstraints = false
        clear.addSubview(clearIcon)
        clearIcon.centerIn(clear)
        clearIcon.sized(w: 18, h: 18)
        clear.sized(w: 30, h: 30)
        clear.isHidden = true
        clear.onTap = { [weak self] in
            guard let self else { return }
            self.field.text = ""
            self.changed()
        }
        let row = UIStackView(axis: .horizontal, spacing: 10, alignment: .center, views: [icon, field, busy, clear])
        row.setCustomSpacing(6, after: field)
        row.setCustomSpacing(2, after: busy)
        box.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }

    var isOn: Bool { !bar.isHidden }

    func bind(_ m: HomeModel) {
        guard let q = m.search else {
            bar.isHidden = true
            key = nil
            if field.isFirstResponder { field.resignFirstResponder() }
            return
        }
        let colors = m.colors
        bar.isHidden = false
        screen.bringSubviewToFront(bar)
        bar.backgroundColor = colors.canvas.alpha(0.9)
        // The search screen's field: bigger, rounder (like the page's).
        boxH.constant = q.big ? 56 : 44
        field.font = Fonts.body(q.big ? 18 : 14.5)
        iconW.constant = q.big ? 20 : 16
        iconH.constant = q.big ? 20 : 16
        box.rounded(q.big ? colors.surface.alpha(0.85) : colors.surface, radius: q.big ? 16 : 12, stroke: 1, strokeColor: colors.ink.alpha(0.1))
        icon.image = Icons.image("search", size: q.big ? 20 : 16)
        icon.tintColor = q.big ? colors.muted : colors.subtle
        clearIcon.image = Icons.image("x", size: 18)
        clearIcon.tintColor = colors.subtle
        clear.accessibilityLabel = m.label("clear", "Clear")
        field.textColor = colors.ink
        field.tintColor = colors.accent
        field.attributedPlaceholder = NSAttributedString(string: q.hint, attributes: [.foregroundColor: colors.subtle])
        if q.busy { busy.startAnimating() } else { busy.stopAnimating() }
        busy.color = colors.muted
        bar.setDirection(rtl: m.rtl)
        // Another list: its own text. The same one: what's typed stays (the page answers late).
        if q.key != key {
            key = q.key
            pending?.cancel()
            sent = q.text
            setText(q.text)
            if q.focus {
                let k = q.key
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.screen.isShowing || !self.screen.isHidden, self.key == k else { return }
                    self.field.becomeFirstResponder()
                }
            }
        } else if q.text != sent && q.text != (field.text ?? "") {
            // The page set the text itself (a recent search, Clear): show it. An old echo of what
            // was typed matches what was sent and leaves the field alone.
            pending?.cancel()
            sent = q.text
            setText(q.text)
        }
    }

    private func setText(_ t: String) {
        quiet = true
        field.text = t
        clear.isHidden = t.isEmpty
        quiet = false
    }

    @objc private func changed() {
        clear.isHidden = (field.text ?? "").isEmpty
        if quiet { return }
        // Sent once typing pauses (the page filters the whole list each time).
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendQuery() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func sendQuery() {
        let text = field.text ?? ""
        sent = text
        screen.act("query", text: text)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Search on the keyboard: what's typed now, then the page's Enter (its top match).
        pending?.cancel()
        sendQuery()
        screen.act("submit")
        textField.resignFirstResponder()
        return true
    }

    func endEditing() {
        if field.isFirstResponder { field.resignFirstResponder() }
    }

    /// Under the heading, or held at the top once the heading has scrolled away.
    func place(table: UITableView, items: [ScreenItem], model m: HomeModel?) {
        guard isOn, let pos = items.firstIndex(where: { $0.kind == .search }) else { return }
        let pinned: CGFloat = (m != nil && m?.back == nil && m?.showTogether == false) ? 4 : 60
        let rect = table.rectForRow(at: IndexPath(row: pos, section: 0))
        let y = rect.minY - table.contentOffset.y
        top.constant = Swift.max(pinned, y)
    }
}
