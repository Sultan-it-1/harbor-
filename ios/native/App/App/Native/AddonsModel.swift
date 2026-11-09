import UIKit

// The Addons page (src/views/addons.tsx) and an addon's page, as the page describes them for the
// native screen: a row of kind "ad" carries one AdBlock. Buttons are PkButtons (PickerModel).
// Taps send {a:"ad", row, what, i}. The same fields as Android's AddonsModel.kt.

/// An addon's logo: its pictures (best first), else its initial on the from→to gradient.
struct AdLogo {
    let images: [String]
    let initial: String
    let from: UIColor?
    let to: UIColor?
}

/// A small pill. tone: star, rise, new, good, warn, neutral. icon: star, trend, sparkles.
struct AdPill {
    let text: String
    let tone: String
    let icon: String?
}

enum AdBlock {
    case card(AdCard)
    case tiles(AdTiles)
    case hero(AdHero)
    case community(AdCommunity)
    case categories(AdCategories)
    case head(AdHead)
    case installed(AdInstalled)
    case detail(AdDetail)
    case info(AdInfo)
    case doc(AdDoc)
}

/// An addon as a card down the page. variant: list, feature, browse, community.
struct AdCard {
    let variant: String
    let logo: AdLogo
    let name: String
    let pills: [AdPill]
    let desc: String?
    let tags: [AdPill]
    let button: PkButton?
    let chevron: Bool
    let art: String?
    let dim: Bool
    /// The last card of a list that loads more: shown, it sends what "more".
    let more: Bool
}

/// Addons as tiles: two across, or a sideways strip.
struct AdTiles {
    let strip: Bool
    let items: [AdTile]
}

struct AdTile {
    let logo: AdLogo
    let name: String
    let pills: [AdPill]
    let desc: String?
    let button: PkButton
    let art: String?
}

/// The featured addon.
struct AdHero {
    let eyebrow: String
    let pills: [AdPill]
    let title: String
    let subtitle: String?
    let button: PkButton
    let link: String
    let from: UIColor?
    let to: UIColor?
}

/// "Top on stremio-addons.net".
struct AdCommunity {
    let logo: String?
    let kicker: String
    let title: String
    let site: String
    let sub: String
    let tabs: [PkPill]
    let browse: String
    /// loading, error, empty, ok.
    let state: String
    let message: String?
    let cards: [AdCommunityCard]
}

struct AdCommunityCard {
    let background: String?
    let stars: String?
    let logo: String?
    let name: String
    let desc: String?
    let types: [String]
    let installed: String?
    let install: String?
    let busy: Bool
}

/// "Browse by category": tiles, each its gradient, icon, name and line.
struct AdCategories {
    let title: String
    let blurb: String
    let tiles: [AdCategory]
}

struct AdCategory {
    let title: String
    let blurb: String
    let from: UIColor?
    let to: UIColor?
    let icon: String?
}

/// A section's heading, its line, and "See all (n)" / "Show less".
struct AdHead {
    let title: String
    let blurb: String?
    let action: String?
    let open: Bool
    let size: CGFloat
}

/// An installed addon: logo, name and line, its switch, Manage, Installed / Tap again to remove.
struct AdInstalled {
    let logo: AdLogo
    let name: String
    let sub: String
    let enabled: Bool
    let manage: String?
    let pill: PkButton
    let dim: Bool
}

/// An addon's page, its top.
struct AdDetail {
    let background: String?
    let glow: String?
    let logo: AdLogo
    let stars: String?
    let eyebrow: String
    let name: String
    let rising: AdPill?
    let desc: String?
    let descOpen: Bool
    let more: String
    let less: String
    let buttons: [PkButton]
    let tags: [AdPill]
}

/// "Project information".
struct AdInfo {
    let title: String
    let note: String
    let stats: [(label: String, value: String)]
    let urlLabel: String
    let url: String
    let reveal: String
    let copy: String?
    let hint: String?
    let foot: String
    let credit: String
}

/// "Documentation": headings, paragraphs and list lines; folded until "View more".
struct AdDoc {
    let title: String
    let note: String
    let parts: [(kind: String, text: String)]
    let open: Bool
    let more: String
    let less: String
}

enum AdParse {
    static func block(_ o: JObj?) -> AdBlock? {
        guard let o else { return nil }
        switch o.str("type") {
        case "card":
            return .card(AdCard(
                variant: o.str("variant") ?? "list",
                logo: logo(o.obj("logo")),
                name: o.str("name") ?? "",
                pills: pills(o.objs("pills")),
                desc: o.str("desc"),
                tags: pills(o.objs("tags")),
                button: PkParse.button(o.obj("button"), fallbackId: "btn"),
                chevron: o.bool("chevron"),
                art: o.str("art"),
                dim: o.bool("dim"),
                more: o.bool("more")
            ))
        case "tiles":
            return .tiles(AdTiles(strip: o.bool("strip"), items: o.objs("items").map { t in
                AdTile(
                    logo: logo(t.obj("logo")),
                    name: t.str("name") ?? "",
                    pills: pills(t.objs("pills")),
                    desc: t.str("desc"),
                    button: PkParse.button(t.obj("button"), fallbackId: "btn") ?? PkButton(id: "btn", label: "", style: "ink", icon: nil),
                    art: t.str("art")
                )
            }))
        case "hero":
            return .hero(AdHero(
                eyebrow: o.str("eyebrow") ?? "",
                pills: pills(o.objs("pills")),
                title: o.str("title") ?? "",
                subtitle: o.str("subtitle"),
                button: PkParse.button(o.obj("button"), fallbackId: "btn") ?? PkButton(id: "btn", label: "", style: "ink", icon: nil),
                link: o.str("link") ?? "",
                from: o.color("from"),
                to: o.color("to")
            ))
        case "community":
            return .community(AdCommunity(
                logo: o.str("logo"),
                kicker: o.str("kicker") ?? "",
                title: o.str("title") ?? "",
                site: o.str("site") ?? "",
                sub: o.str("sub") ?? "",
                tabs: o.objs("tabs").compactMap { p in
                    guard let id = p.str("id") else { return nil }
                    return PkPill(id: id, label: p.str("label") ?? id, on: p.bool("on"))
                },
                browse: o.str("browse") ?? "",
                state: o.str("state") ?? "loading",
                message: o.str("message"),
                cards: o.objs("cards").map { c in
                    AdCommunityCard(
                        background: c.str("bg"),
                        stars: c.str("stars"),
                        logo: c.str("logo"),
                        name: c.str("name") ?? "",
                        desc: c.str("desc"),
                        types: c.strs("types"),
                        installed: c.str("installed"),
                        install: c.str("install"),
                        busy: c.bool("busy")
                    )
                }
            ))
        case "cats":
            return .categories(AdCategories(
                title: o.str("title") ?? "",
                blurb: o.str("blurb") ?? "",
                tiles: o.objs("tiles").map { t in
                    AdCategory(title: t.str("title") ?? "", blurb: t.str("blurb") ?? "", from: t.color("from"), to: t.color("to"), icon: t.str("icon"))
                }
            ))
        case "head":
            return .head(AdHead(title: o.str("title") ?? "", blurb: o.str("blurb"), action: o.str("action"), open: o.bool("open"), size: CGFloat(o.double("size", 26))))
        case "installed":
            return .installed(AdInstalled(
                logo: logo(o.obj("logo")),
                name: o.str("name") ?? "",
                sub: o.str("sub") ?? "",
                enabled: o.bool("enabled", true),
                manage: o.str("manage"),
                pill: PkParse.button(o.obj("pill"), fallbackId: "btn") ?? PkButton(id: "remove", label: "", style: "installed", icon: nil),
                dim: o.bool("dim")
            ))
        case "detail":
            return .detail(AdDetail(
                background: o.str("bg"),
                glow: o.str("glow"),
                logo: logo(o.obj("logo")),
                stars: o.str("stars"),
                eyebrow: o.str("eyebrow") ?? "",
                name: o.str("name") ?? "",
                rising: o.obj("rising").flatMap { pill($0) },
                desc: o.str("desc"),
                descOpen: o.bool("descOpen"),
                more: o.str("more") ?? "View more",
                less: o.str("less") ?? "Show less",
                buttons: o.objs("buttons").compactMap { PkParse.button($0, fallbackId: "btn") },
                tags: pills(o.objs("tags"))
            ))
        case "info":
            return .info(AdInfo(
                title: o.str("title") ?? "",
                note: o.str("note") ?? "",
                stats: o.objs("stats").map { (label: $0.str("label") ?? "", value: $0.str("value") ?? "") },
                urlLabel: o.str("urlLabel") ?? "",
                url: o.str("url") ?? "",
                reveal: o.str("reveal") ?? "",
                copy: o.str("copy"),
                hint: o.str("hint"),
                foot: o.str("foot") ?? "",
                credit: o.str("credit") ?? ""
            ))
        case "doc":
            return .doc(AdDoc(
                title: o.str("title") ?? "",
                note: o.str("note") ?? "",
                parts: o.objs("parts").map { (kind: $0.str("k") ?? "p", text: $0.str("text") ?? "") },
                open: o.bool("open"),
                more: o.str("more") ?? "View more",
                less: o.str("less") ?? "Show less"
            ))
        default:
            return nil
        }
    }

    static func logo(_ o: JObj?) -> AdLogo {
        AdLogo(images: o?.strs("img") ?? [], initial: o?.str("initial") ?? "?", from: o?.color("from"), to: o?.color("to"))
    }

    static func pill(_ o: JObj) -> AdPill? {
        guard let text = o.str("text") else { return nil }
        return AdPill(text: text, tone: o.str("tone") ?? "neutral", icon: o.str("icon"))
    }

    static func pills(_ a: [JObj]) -> [AdPill] { a.compactMap { pill($0) } }
}
