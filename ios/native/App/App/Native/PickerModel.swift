import UIKit

// The play picker's other layout (the big card, the qualities, every source) and its full-screen
// steps, as the page (src/views/play-picker.tsx) describes them: a row of kind "pk" carries one
// PkBlock; the page's "stage" is a PkStage. The same fields as Android's PickerModel.kt.

/// A format badge (4K, HDR, Atmos…): its picture (a data: URL) at w points wide, else its label.
struct PkBadge {
    let src: String?
    let label: String
    let w: CGFloat
}

/// An audio language: its flag (an emoji), or its name ("Multi" is a pill).
struct PkFlag {
    let emoji: String?
    let label: String
    let multi: Bool
}

/// A coloured line with an icon. tone: accent, muted, green, subtle, danger.
/// icon: zap (filled), zap-line, check, download, external.
struct PkStatus {
    let text: String
    let tone: String
    let icon: String?
    let upper: Bool
}

/// A small pill. style: accent, plain, remux, group, danger.
struct PkTag {
    let text: String
    let style: String
}

/// A button. style: ink, accent, outline, green, off, link, white, glass, secondary, amber.
/// icon: play, download, check, external, radio, x, arrow. copy: text put on the clipboard by the tap.
struct PkButton {
    let id: String
    let label: String
    let style: String
    let icon: String?
    var busy = false
    var copy: String?
}

/// A choice that toggles (Cached only, a language, an addon). icon: zap, lang.
struct PkPill {
    let id: String
    let label: String
    let on: Bool
    var icon: String?
    var count: String?
}

/// An addon's round logo, or its initial.
struct PkLogo {
    let images: [String]
    let initial: String
}

enum PkBlock {
    case pick(PkPick)
    case tiers(PkTiers)
    case streams(PkStreams)
    case drawer(PkDrawer)
    case diag(PkDiag)
    case panel(PkPanel)
    case loader(PkLoader)
}

/// The source the page picked, as its big card.
struct PkPick {
    let images: [String]
    let wide: Bool
    let logo: String?
    let badges: [PkBadge]
    let flags: [PkFlag]
    let moreFlags: String?
    let noAudio: String?
    let confirm: String?
    let match: PkTag?
    let title: String
    let file: String?
    let summary: [String]
    let status: PkStatus?
    let chips: [PkTag]
    let button: PkButton
    let via: PkVia?
    let copy: String?
}

/// Where the source plays from.
struct PkVia {
    let top: String?
    let tone: String
    let zap: Bool
    let by: String
    let addon: String
    let logo: [String]
}

/// "Switch quality", the Cached / language pills and the best source of each quality.
struct PkTiers {
    let title: String
    let infoTitle: String
    let infoBody: String
    let pills: [PkPill]
    let tiers: [PkTier]
}

struct PkTier {
    let badge: PkBadge
    let label: String
    let status: String
    let zap: String?
    let on: Bool
    let dim: Bool
}

/// Every source, one line each, in one box.
struct PkStreams {
    let items: [PkStream]
}

struct PkStream {
    let badges: [PkBadge]
    let title: String
    let edition: String?
    let file: String?
    let logo: PkLogo
    let addon: String
    let summary: String?
    let flags: [PkFlag]
    let moreFlags: Int
    let match: PkTag?
    let status: PkStatus?
    /// play, external, busy.
    let end: String
    let copy: String?
}

/// The drawer's button ("All sources 42", the addons' logos) and, open, the addons to pick from.
struct PkDrawer {
    let label: String
    let count: String
    let logos: [PkLogo]
    let addons: String?
    let open: Bool
    let pills: [PkPill]
}

/// "12 cached · 40 found across 3 sources" and, open, what each source found.
struct PkDiag {
    let lead: String
    let text: String
    let open: Bool
    let more: [String]
}

/// A message in a box. look: dashed, card, art, warn.
struct PkPanel {
    let look: String
    let kicker: String?
    let title: String?
    let titleSize: CGFloat
    let body: String?
    let pills: [String]
    let mono: String?
    let button: PkButton?
    let note: String?
    let art: [String]
}

/// Searching: the title's logo (or name) breathing, then the caption.
struct PkLoader {
    let logo: [String]
    let text: String
    let caption: String
}

/// A full-screen step. look: dialog (a card on black) or art (over the title's blurred picture).
/// Buttons send {a:"stage", what:id}; the box's checkbox sends what "toggle".
struct PkStage {
    let look: String
    let backdrop: [String]
    let kicker: String?
    let pill: PkTag?
    let logo: [String]
    let logoText: String?
    let line: String?
    let check: Bool
    let title: String?
    let titleSize: CGFloat
    let body: String?
    let bullets: [String]
    let box: PkBox?
    let toggle: PkToggle?
    let spinner: String?
    let notice: String?
    let sub: String?
    let label: String?
    let foot: String?
    let buttons: [PkButton]
    let cancel: PkButton?
}

/// The source a step is about: its name, seeders and facts.
struct PkBox {
    let title: String
    let seeders: String?
    let meta: [String]
}

struct PkToggle {
    let label: String
    let on: Bool
}

enum PkParse {
    static func block(_ o: JObj?) -> PkBlock? {
        guard let o else { return nil }
        switch o.str("type") {
        case "pick":
            return .pick(PkPick(
                images: o.strs("img"),
                wide: o.bool("wide"),
                logo: o.str("logo"),
                badges: badges(o.objs("badges")),
                flags: flags(o.objs("flags")),
                moreFlags: o.str("moreFlags"),
                noAudio: o.str("noAudio"),
                confirm: o.str("confirm"),
                match: tag(o.obj("match")),
                title: o.str("title") ?? "",
                file: o.str("file"),
                summary: o.strs("summary"),
                status: status(o.obj("status")),
                chips: o.objs("chips").compactMap { tag($0) },
                button: button(o.obj("button")) ?? PkButton(id: "primary", label: "", style: "off", icon: nil),
                via: o.obj("via").map { v in
                    PkVia(top: v.str("top"), tone: v.str("tone") ?? "muted", zap: v.bool("zap"), by: v.str("by") ?? "", addon: v.str("addon") ?? "", logo: v.strs("logo"))
                },
                copy: o.str("copy")
            ))
        case "tiers":
            return .tiers(PkTiers(
                title: o.str("title") ?? "",
                infoTitle: o.str("infoTitle") ?? "",
                infoBody: o.str("infoBody") ?? "",
                pills: pills(o.objs("pills")),
                tiers: o.objs("tiers").map { t in
                    PkTier(
                        badge: badge(t.obj("badge")) ?? PkBadge(src: nil, label: "", w: 60),
                        label: t.str("label") ?? "",
                        status: t.str("status") ?? "",
                        zap: t.str("zap"),
                        on: t.bool("on"),
                        dim: t.bool("dim")
                    )
                }
            ))
        case "streams":
            return .streams(PkStreams(items: o.objs("items").map { s in
                PkStream(
                    badges: badges(s.objs("badges")),
                    title: s.str("title") ?? "",
                    edition: s.str("edition"),
                    file: s.str("file"),
                    logo: logo(s.obj("logo")),
                    addon: s.str("addon") ?? "",
                    summary: s.str("summary"),
                    flags: flags(s.objs("flags")),
                    moreFlags: s.int("moreFlags"),
                    match: tag(s.obj("match")),
                    status: status(s.obj("status")),
                    end: s.str("end") ?? "play",
                    copy: s.str("copy")
                )
            }))
        case "drawer":
            return .drawer(PkDrawer(
                label: o.str("label") ?? "",
                count: o.str("count") ?? "",
                logos: o.objs("logos").map { logo($0) },
                addons: o.str("addons"),
                open: o.bool("open"),
                pills: pills(o.objs("pills"))
            ))
        case "diag":
            return .diag(PkDiag(lead: o.str("lead") ?? "", text: o.str("text") ?? "", open: o.bool("open"), more: o.strs("more")))
        case "panel":
            return .panel(PkPanel(
                look: o.str("look") ?? "card",
                kicker: o.str("kicker"),
                title: o.str("title"),
                titleSize: CGFloat(o.double("titleSize", 28)),
                body: o.str("body"),
                pills: o.strs("pills"),
                mono: o.str("mono"),
                button: button(o.obj("button")),
                note: o.str("note"),
                art: o.strs("art")
            ))
        case "loader":
            return .loader(PkLoader(logo: o.strs("logo"), text: o.str("text") ?? "", caption: o.str("caption") ?? ""))
        default:
            return nil
        }
    }

    static func stage(_ o: JObj?) -> PkStage? {
        guard let o else { return nil }
        return PkStage(
            look: o.str("look") ?? "art",
            backdrop: o.strs("backdrop"),
            kicker: o.str("kicker"),
            pill: tag(o.obj("pill")),
            logo: o.strs("logo"),
            logoText: o.str("logoText"),
            line: o.str("line"),
            check: o.bool("check"),
            title: o.str("title"),
            titleSize: CGFloat(o.double("titleSize", 24)),
            body: o.str("body"),
            bullets: o.strs("bullets"),
            box: o.obj("box").map { b in PkBox(title: b.str("title") ?? "", seeders: b.str("seeders"), meta: b.strs("meta")) },
            toggle: o.obj("toggle").map { t in PkToggle(label: t.str("label") ?? "", on: t.bool("on")) },
            spinner: o.str("spinner"),
            notice: o.str("notice"),
            sub: o.str("sub"),
            label: o.str("label"),
            foot: o.str("foot"),
            buttons: o.objs("buttons").compactMap { button($0) },
            cancel: button(o.obj("cancel"))
        )
    }

    static func badge(_ o: JObj?) -> PkBadge? {
        guard let o else { return nil }
        return PkBadge(src: o.str("src"), label: o.str("label") ?? "", w: CGFloat(o.double("w", 42)))
    }

    static func badges(_ a: [JObj]) -> [PkBadge] { a.compactMap { badge($0) } }

    static func flags(_ a: [JObj]) -> [PkFlag] { a.map { PkFlag(emoji: $0.str("emoji"), label: $0.str("label") ?? "", multi: $0.bool("multi")) } }

    static func tag(_ o: JObj?) -> PkTag? {
        guard let o, let text = o.str("text") else { return nil }
        return PkTag(text: text, style: o.str("style") ?? "plain")
    }

    static func status(_ o: JObj?) -> PkStatus? {
        guard let o, let text = o.str("text") else { return nil }
        return PkStatus(text: text, tone: o.str("tone") ?? "muted", icon: o.str("icon"), upper: o.bool("upper", true))
    }

    static func button(_ o: JObj?, fallbackId: String = "") -> PkButton? {
        guard let o else { return nil }
        return PkButton(id: o.str("id") ?? fallbackId, label: o.str("label") ?? "", style: o.str("style") ?? "ink", icon: o.str("icon"), busy: o.bool("busy"), copy: o.str("copy"))
    }

    static func pills(_ a: [JObj]) -> [PkPill] {
        a.compactMap { p in
            guard let id = p.str("id") else { return nil }
            return PkPill(id: id, label: p.str("label") ?? id, on: p.bool("on"), icon: p.str("icon"), count: p.str("count"))
        }
    }

    static func logo(_ o: JObj?) -> PkLogo { PkLogo(images: o?.strs("img") ?? [], initial: o?.str("initial") ?? "") }
}
