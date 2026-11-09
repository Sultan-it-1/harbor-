import UIKit

/// What a native screen shows, as the page describes it (src/views/native/native-screens.ts and
/// the pages build the JSON). The same fields as Android's HomeModel.kt.
struct HomeModel {
    /// Which screen this is ("home", "discover", "movies", "shows", "library", …).
    var page = "home"
    var rtl = false
    /// Changes when the page wants the screen back at the top (its tab tapped again).
    var top = 0
    var colors = HomeColors.standard
    var labels: [String: String] = [:]
    var hero: [HomeSlide] = []
    /// Continue Watching first (kind cw) when there is anything in it, then the catalog rows.
    var rows: [HomeRow] = []
    /// Continue Watching when it is empty: its title and the text in its box.
    var cwEmpty: (title: String, text: String)?
    var showCustomize = false
    var showTogether = false
    /// Rating badges at the top of the poster instead of the bottom.
    var badgesTop = false
    var header: HomeHeader?
    var chips: [HomeChips] = []
    /// Shown when there are no rows: optional title, then the text.
    var empty: (title: String?, text: String)?
    var edit = false
    var addSource = false
    /// A page opened over another: the Back pill's label.
    var back: String?
    var search: HomeSearch?
    var note: String?
    var message: HomeMessage?
    var detail: HomeDetail?
    var queue: HomeQueue?
    var calendar: HomeCalendar?
    var downloads: HomeDownloads?
    var sheet: HomeSheet?
    var match: HomeMatch?
    var guide: HomeGuide?
    var stage: PkStage?
    var toast: HomeToast?
    var prompt: HomePrompt?

    func label(_ key: String, _ fallback: String) -> String {
        if let v = labels[key], !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        return fallback
    }

    static func parse(_ json: String) -> HomeModel? {
        guard let o = parseObject(json) else { return nil }
        var m = HomeModel()
        m.page = o.str("page") ?? "home"
        m.rtl = o.bool("rtl")
        m.top = o.int("top")
        m.colors = HomeColors.parse(o.obj("colors"))
        m.labels = o.labels("labels")
        m.hero = o.objs("hero").map { s in
            HomeSlide(
                title: s.str("title") ?? "",
                description: s.str("desc"),
                year: s.str("year"),
                rating: s.str("rating"),
                runtime: s.str("runtime"),
                images: s.strs("img"),
                logo: s.str("logo"),
                rank: s.str("rank"),
                inList: s.bool("inList")
            )
        }
        m.rows = o.objs("rows").compactMap(parseRow)
        if let cw = o.obj("cwEmpty") { m.cwEmpty = (cw.str("title") ?? "", cw.str("text") ?? "") }
        m.showCustomize = o.bool("customize")
        m.showTogether = o.bool("together")
        m.badgesTop = o.bool("badgesTop")
        if let h = o.obj("header") {
            let head = HomeHeader(
                kicker: h.str("kicker"),
                title: h.str("title") ?? "",
                subtitle: h.str("subtitle"),
                logo: h.str("logo"),
                tint: h.color("tint"),
                count: h.str("count"),
                icon: h.str("icon"),
                size: { () -> CGFloat? in let v = h.double("size"); return v > 0 ? CGFloat(v) : nil }(),
                body: h.str("body"),
                backdrop: h.strs("backdrop"),
                switchChips: chipList(h.objs("switch")),
                photo: h.str("photo"),
                badge: h.str("badge"),
                bodyLines: h.int("bodyLines", 3)
            )
            if !head.title.isEmpty || head.kicker != nil || head.subtitle != nil || head.logo != nil { m.header = head }
        }
        m.chips = o.objs("chips").compactMap { g in
            guard let key = g.str("key") else { return nil }
            let items = chipList(g.objs("items"))
            return items.isEmpty ? nil : HomeChips(key: key, items: items)
        }
        if let e = o.obj("empty"), let text = e.str("text") { m.empty = (e.str("title"), text) }
        m.edit = o.bool("edit")
        m.addSource = o.bool("addSource")
        m.back = o.str("back")
        if let q = o.obj("search") {
            m.search = HomeSearch(key: q.str("key") ?? "", hint: q.str("hint") ?? "", text: q.str("text") ?? "", busy: q.bool("busy"), big: q.bool("big"), focus: q.bool("focus"))
        }
        m.note = o.str("note")
        if let d = o.obj("detail") {
            m.detail = HomeDetail(
                backdrop: d.strs("backdrop"),
                logo: d.str("logo"),
                title: d.str("title") ?? "",
                tagline: d.str("tagline"),
                pills: d.objs("pills").compactMap { p in
                    guard let id = p.str("id") else { return nil }
                    return DetailPill(id: id, label: p.str("label") ?? "", kind: p.str("kind") ?? "pill")
                },
                awards: d.str("awards"),
                play: d.str("play"),
                more: d.bool("more"),
                synopsis: d.str("synopsis"),
                taglineLink: d.bool("taglineLink"),
                extra: d.str("extra"),
                pending: d.bool("pending")
            )
        }
        if let q = o.obj("queue") {
            m.queue = HomeQueue(
                position: q.str("position") ?? "",
                tag: q.str("tag"),
                series: q.str("series"),
                title: q.str("title") ?? "",
                facts: q.strs("facts"),
                rating: q.str("rating"),
                genres: q.str("genres"),
                desc: q.str("desc"),
                backdrop: q.strs("backdrop"),
                saved: q.bool("saved"),
                canPrev: q.bool("canPrev"),
                canNext: q.bool("canNext"),
                labels: q.labels("labels"),
                strip: q.objs("strip").map { QueueTile(img: $0.strs("img"), tag: $0.str("tag") ?? "") },
                active: q.int("active"),
                message: q.str("message")
            )
        }
        if let c = o.obj("calendar") {
            m.calendar = HomeCalendar(
                month: c.str("month") ?? "",
                weekdays: c.strs("weekdays"),
                cells: c.objs("cells").map { x in
                    CalCell(
                        day: x.int("day"),
                        inMonth: x.bool("inMonth", true),
                        today: x.bool("today"),
                        count: x.int("count"),
                        items: x.objs("items").map { CalItem(title: $0.str("title") ?? "", images: $0.strs("img")) },
                        more: x.str("more")
                    )
                },
                labels: c.labels("labels")
            )
        }
        if let d = o.obj("downloads") {
            m.downloads = HomeDownloads(
                storage: d.str("storage"),
                notices: d.objs("notices").map { n in
                    DlNotice(id: n.str("id") ?? "", icon: n.str("icon") ?? "", text: n.str("text") ?? "", action: n.str("action"), accent: n.bool("accent"), actionOn: n.bool("actionOn"))
                },
                jobs: d.objs("jobs").map { DlJob(key: $0.str("key") ?? "", text: $0.str("text") ?? "", stop: $0.str("stop") ?? "Stop") },
                groups: d.objs("groups").map { g in
                    DlGroup(
                        key: g.str("key") ?? "",
                        title: g.str("title"),
                        sub: g.str("sub"),
                        images: g.strs("img"),
                        items: g.objs("items").map { x in
                            DlItem(
                                id: x.str("id") ?? "",
                                title: x.str("title") ?? "",
                                side: x.str("side"),
                                images: x.strs("img"),
                                compact: x.bool("compact"),
                                progress: CGFloat(x.double("progress", -1)),
                                paused: x.bool("paused"),
                                stats: x.str("stats"),
                                note: x.str("note"),
                                status: x.str("status") ?? "",
                                statusText: x.str("statusText"),
                                subs: x.str("subs"),
                                subsAction: x.str("subsAction"),
                                buttons: x.objs("buttons").map { DlButton(id: $0.str("id") ?? "", label: $0.str("label") ?? "") }
                            )
                        }
                    )
                }
            )
        }
        if let g = o.obj("guide") {
            m.guide = HomeGuide(
                start: g.long("start"),
                end: g.long("end"),
                now: g.long("now"),
                day: g.str("day") ?? "",
                ticks: g.objs("ticks").map { GuideTick(at: $0.long("at"), label: $0.str("label") ?? "") },
                channels: g.objs("channels").map { c in
                    GuideChannel(
                        name: c.str("name") ?? "",
                        number: c.str("number"),
                        logo: c.str("logo"),
                        programs: c.objs("programs").map { p in
                            GuideProgram(s: p.long("s"), e: p.long("e"), title: p.str("title") ?? "", from: p.str("from") ?? "", to: p.str("to") ?? "", replay: p.bool("replay"))
                        }
                    )
                },
                more: g.bool("more"),
                labels: g.labels("labels")
            )
        }
        m.stage = PkParse.stage(o.obj("stage"))
        if let t = o.obj("toast"), let text = t.str("text") { m.toast = HomeToast(id: t.int("id"), text: text) }
        if let q = o.obj("prompt") {
            m.prompt = HomePrompt(key: q.str("key") ?? "prompt", title: q.str("title") ?? "", hint: q.str("hint") ?? "", text: q.str("text") ?? "", ok: q.str("ok") ?? "OK", cancel: q.str("cancel") ?? "Cancel")
        }
        if let mt = o.obj("match") {
            func side(_ k: String) -> MatchSide {
                guard let s = mt.obj(k) else { return MatchSide(name: "", logo: nil, score: "0", yellow: 0, red: 0) }
                return MatchSide(name: s.str("name") ?? "", logo: s.str("logo"), score: s.str("score") ?? "0", yellow: s.int("yellow"), red: s.int("red"))
            }
            m.match = HomeMatch(league: mt.str("league") ?? "", live: mt.bool("live"), status: mt.str("status") ?? "", home: side("home"), away: side("away"))
        }
        if let sh = o.obj("sheet") {
            m.sheet = HomeSheet(key: sh.str("key") ?? "", items: sh.objs("items").map { i in
                SheetItem(
                    id: i.str("id") ?? "",
                    label: i.str("label") ?? "",
                    icon: i.str("icon"),
                    active: i.bool("active"),
                    danger: i.bool("danger"),
                    indent: i.bool("indent"),
                    group: i.bool("group"),
                    open: i.bool("open"),
                    divider: i.bool("divider")
                )
            })
        }
        if let g = o.obj("message") {
            let msg = HomeMessage(title: g.str("title"), text: g.str("text"), action: g.str("action"))
            if msg.title != nil || msg.text != nil { m.message = msg }
        }
        return m
    }

    private static func chipList(_ a: [JObj]) -> [HomeChip] {
        a.compactMap { c in
            guard let id = c.str("id") else { return nil }
            return HomeChip(id: id, label: c.str("label") ?? id, on: c.bool("on"))
        }
    }

    /// "on" / "off" / anything else (not offered) as 1 / 0 / -1.
    private static func tri(_ v: String?) -> Int { v == "on" ? 1 : v == "off" ? 0 : -1 }

    private static func parseRow(_ r: JObj) -> HomeRow? {
        guard let key = r.str("key") else { return nil }
        let items = r.objs("items").map(parseCard)
        let ed: RowEdit? = r.obj("ed").map { e in
            RowEdit(
                hidden: e.bool("hidden"),
                up: e.bool("up"),
                down: e.bool("down"),
                numerals: tri(e.str("numerals")),
                hero: tri(e.str("hero")),
                delete: e.bool("del"),
                pinned: e.bool("pinned"),
                renamed: e.bool("renamed")
            )
        }
        // In the editor a row shows even with nothing in it; a row led by a spotlight card shows
        // with only that card; credits have no cards; a row of only choices or buttons shows too,
        // and a heading over a grid.
        let onlyChoices = r.obj("chips") != nil || !r.objs("tools").isEmpty || r.bool("head")
        let kindName = r.str("kind")
        var pk: PkBlock?
        var ad: AdBlock?
        if kindName == "pk" {
            guard let b = PkParse.block(r.obj("pk")) else { return nil }
            pk = b
        }
        if kindName == "ad" {
            guard let b = AdParse.block(r.obj("ad")) else { return nil }
            ad = b
        }
        if items.isEmpty && ed == nil && !onlyChoices && pk == nil && ad == nil && r.obj("lead") == nil && kindName != "credits" && kindName != "episodes" {
            return nil
        }
        var row = HomeRow(key: key, title: r.str("title") ?? "", kind: HomeRow.Kind(name: kindName), seeAll: r.bool("all"), more: r.bool("more"), items: items)
        row.edit = ed
        row.note = r.str("note")
        row.critic = r.obj("critic").map(parseCritic)
        row.sub = r.str("sub")
        row.gallery = r.bool("gallery")
        row.noInfo = r.bool("noInfo")
        if let g = r.obj("chips"), let ck = g.str("key") {
            let its = chipList(g.objs("items"))
            if !its.isEmpty { row.chips = HomeChips(key: ck, items: its) }
        }
        row.tools = chipList(r.objs("tools"))
        row.credits = r.objs("credits").map { g in
            CreditGroup(
                label: g.str("label") ?? "",
                people: g.objs("people").compactMap { p in
                    guard let name = p.str("name") else { return nil }
                    return CriticPerson(id: p.long("id"), name: name, image: nil)
                },
                value: g.str("value")
            )
        }
        row.grid = r.bool("grid")
        row.min = r.int("min")
        let ratio = r.double("ratio")
        row.ratio = ratio.isNaN || ratio <= 0 ? 0 : CGFloat(ratio)
        row.lead = r.obj("lead").map { l in
            HomeCard(title: l.str("title") ?? "", images: l.strs("img"), rating: nil, sub: l.str("sub"), progress: 0, rank: 0)
        }
        row.pk = pk
        row.ad = ad
        return row
    }

    private static func parseCard(_ c: JObj) -> HomeCard {
        var card = HomeCard(
            title: c.str("title") ?? "",
            images: c.strs("img"),
            rating: c.str("rating"),
            sub: c.str("sub"),
            progress: { () -> CGFloat in let p = c.double("progress"); return p.isNaN ? 0 : CGFloat(Swift.min(Swift.max(p, 0), 1)) }(),
            rank: c.int("rank")
        )
        card.watched = c.bool("watched")
        card.tint = c.color("tint")
        card.kicker = c.str("kicker")
        card.play = c.bool("play")
        card.emblem = c.bool("emblem")
        card.icon = c.str("icon")
        card.tone = c.str("tone")
        card.button = c.str("button")
        card.busy = c.bool("busy")
        card.logo = c.str("logo")
        card.bar = c.bool("bar")
        card.tags = c.strs("tags")
        card.desc = c.str("desc")
        return card
    }

    private static func parseCritic(_ c: JObj) -> CriticInfo {
        CriticInfo(
            title: c.str("title") ?? "",
            images: c.strs("img"),
            logo: c.str("logo"),
            year: c.str("year"),
            rating: c.str("rating"),
            quote: c.str("quote"),
            overview: c.str("overview"),
            reviews: c.objs("reviews").compactMap { r in
                guard let text = r.str("text") else { return nil }
                return CriticReview(text: text, full: r.str("full") ?? text, author: r.str("author"), score: r.str("score"), url: r.str("url"))
            },
            stills: c.strs("stills"),
            cast: c.objs("cast").compactMap { p in
                let id = p.long("id")
                guard id > 0 else { return nil }
                return CriticPerson(id: id, name: p.str("name") ?? "", image: p.str("img"))
            },
            director: c.obj("director").flatMap { d in
                let id = d.long("id")
                return id > 0 ? CriticPerson(id: id, name: d.str("name") ?? "", image: nil) : nil
            },
            genres: c.strs("genres"),
            castTitle: c.str("castTitle")
        )
    }
}

struct HomeSlide {
    let title: String
    let description: String?
    let year: String?
    let rating: String?
    let runtime: String?
    let images: [String]
    let logo: String?
    /// "#1 in Movies Today"
    let rank: String?
    let inList: Bool
}

struct HomeRow {
    /// POSTER and RANK: titles; CW: Continue Watching; TILE: a coloured card with its name on it;
    /// LOGO: a streaming service; FEATURE: one wide card; CRITIC: Critics' Pick; and the rest.
    enum Kind {
        case poster, rank, cw, tile, logo, feature, critic, credits, episodes, people, list, winners, action
        case live, guide, channel, livehero, sports, sources, versus, pitch, pk, ad

        init(name: String?) {
            switch name {
            case "cw": self = .cw
            case "rank": self = .rank
            case "tile": self = .tile
            case "logo": self = .logo
            case "feature": self = .feature
            case "critic": self = .critic
            case "credits": self = .credits
            case "episodes": self = .episodes
            case "people": self = .people
            case "list": self = .list
            case "winners": self = .winners
            case "action": self = .action
            case "live": self = .live
            case "guide": self = .guide
            case "channel": self = .channel
            case "livehero": self = .livehero
            case "sports": self = .sports
            case "sources": self = .sources
            case "versus": self = .versus
            case "pitch": self = .pitch
            case "pk": self = .pk
            case "ad": self = .ad
            default: self = .poster
            }
        }
    }

    let key: String
    let title: String
    let kind: Kind
    let seeAll: Bool
    /// The page can load more of this row when you near its end.
    let more: Bool
    let items: [HomeCard]
    var edit: RowEdit?
    var note: String?
    var critic: CriticInfo?
    var sub: String?
    var gallery = false
    var noInfo = false
    var credits: [CreditGroup] = []
    var chips: HomeChips?
    var tools: [HomeChip] = []
    var grid = false
    var min = 0
    var ratio: CGFloat = 0
    var lead: HomeCard?
    var pk: PkBlock?
    var ad: AdBlock?

    init(key: String, title: String, kind: Kind, seeAll: Bool, more: Bool, items: [HomeCard]) {
        self.key = key
        self.title = title
        self.kind = kind
        self.seeAll = seeAll
        self.more = more
        self.items = items
    }
}

/// Critics' Pick, as the page's own card shows it.
struct CriticInfo {
    let title: String
    let images: [String]
    let logo: String?
    let year: String?
    let rating: String?
    let quote: String?
    let overview: String?
    let reviews: [CriticReview]
    let stills: [String]
    let cast: [CriticPerson]
    let director: CriticPerson?
    let genres: [String]
    let castTitle: String?
}

struct CriticReview {
    let text: String
    let full: String
    let author: String?
    let score: String?
    let url: String?
}

struct CriticPerson {
    let id: Int64
    let name: String
    let image: String?
}

struct HomeCard {
    let title: String
    /// Picture addresses, best first: the next one is tried when one fails.
    let images: [String]
    let rating: String?
    /// Continue Watching: "S1E2 · 20m left".
    let sub: String?
    /// Continue Watching: how far in, 0…1.
    let progress: CGFloat
    /// Top 10: the number shown on the card (0 = none).
    let rank: Int
    var watched = false
    var tint: UIColor?
    var kicker: String?
    var play = false
    var emblem = false
    var desc: String?
    var icon: String?
    var tone: String?
    var button: String?
    var busy = false
    var logo: String?
    var bar = false
    var tags: [String] = []

    init(title: String, images: [String], rating: String?, sub: String?, progress: CGFloat, rank: Int) {
        self.title = title
        self.images = images
        self.rating = rating
        self.sub = sub
        self.progress = progress
        self.rank = rank
    }
}

/// A row's controls in the page's editor. numerals / hero: 1 on, 0 off, -1 not offered.
struct RowEdit {
    let hidden: Bool
    let up: Bool
    let down: Bool
    let numerals: Int
    let hero: Int
    let delete: Bool
    let pinned: Bool
    let renamed: Bool
}

/// The theme's colours (the page sends what its CSS uses).
struct HomeColors {
    let canvas: UIColor
    let surface: UIColor
    let ink: UIColor
    let muted: UIColor
    let subtle: UIColor
    let accent: UIColor

    static let standard = HomeColors(
        canvas: UIColor(argb: 0xFF141518),
        surface: UIColor(argb: 0xFF1C1D21),
        ink: UIColor(argb: 0xFFF5F5F7),
        muted: UIColor(argb: 0xFFAEAFB3),
        subtle: UIColor(argb: 0xFF6E7075),
        accent: UIColor(argb: 0xFFE8A45E)
    )

    static func parse(_ o: JObj?) -> HomeColors {
        guard let o else { return standard }
        return HomeColors(
            canvas: o.color("canvas") ?? standard.canvas,
            surface: o.color("surface") ?? standard.surface,
            ink: o.color("ink") ?? standard.ink,
            muted: o.color("muted") ?? standard.muted,
            subtle: o.color("subtle") ?? standard.subtle,
            accent: o.color("accent") ?? standard.accent
        )
    }
}

struct HomeHeader {
    let kicker: String?
    let title: String
    let subtitle: String?
    /// A picture instead of the title (a streaming service's logo).
    let logo: String?
    /// A glow of this colour behind the heading.
    let tint: UIColor?
    /// Small text after the title ("120 titles").
    let count: String?
    /// A small icon before the kicker.
    let icon: String?
    /// The title's size in points (30 when not given).
    let size: CGFloat?
    let body: String?
    let backdrop: [String]
    /// The title opens a list of these (a genre page: the other genres).
    let switchChips: [HomeChip]
    /// A portrait above it all (a person's photo).
    let photo: String?
    /// A small accent badge after the kicker ("Top 12").
    let badge: String?
    /// How many lines of [body] show until it's tapped.
    let bodyLines: Int
}

/// A title's hero. pills: kind "pill" (a tap sends {a:"pill", what:id}), "imdb", "score".
struct HomeDetail {
    let backdrop: [String]
    let logo: String?
    let title: String
    let tagline: String?
    let pills: [DetailPill]
    let awards: String?
    /// The Play button's label (nil = none). Sends {a:"d", what:"play"}.
    let play: String?
    /// The round "…" button.
    let more: Bool
    let synopsis: String?
    let taglineLink: Bool
    let extra: String?
    /// The title's full details are still on their way.
    let pending: Bool
}

struct DetailPill {
    let id: String
    let label: String
    let kind: String
}

/// The discovery queue: one title at a time on a big card, and the queue's pictures under it.
struct HomeQueue {
    let position: String
    let tag: String?
    let series: String?
    let title: String
    let facts: [String]
    let rating: String?
    let genres: String?
    let desc: String?
    let backdrop: [String]
    let saved: Bool
    let canPrev: Bool
    let canNext: Bool
    let labels: [String: String]
    let strip: [QueueTile]
    let active: Int
    let message: String?

    func label(_ k: String, _ fallback: String) -> String { labels[k] ?? fallback }
}

struct QueueTile {
    let img: [String]
    let tag: String
}

/// The release calendar's month.
struct HomeCalendar {
    let month: String
    let weekdays: [String]
    let cells: [CalCell]
    let labels: [String: String]

    func label(_ k: String, _ fallback: String) -> String { labels[k] ?? fallback }
}

struct CalCell {
    let day: Int
    let inMonth: Bool
    let today: Bool
    let count: Int
    let items: [CalItem]
    let more: String?
}

struct CalItem {
    let title: String
    let images: [String]
}

/// The downloads page as it lists them.
struct HomeDownloads {
    let storage: String?
    let notices: [DlNotice]
    let jobs: [DlJob]
    let groups: [DlGroup]
}

struct DlNotice {
    let id: String
    let icon: String
    let text: String
    let action: String?
    let accent: Bool
    let actionOn: Bool
}

struct DlJob {
    let key: String
    let text: String
    let stop: String
}

struct DlGroup {
    let key: String
    let title: String?
    let sub: String?
    let images: [String]
    let items: [DlItem]
}

struct DlItem {
    let id: String
    let title: String
    let side: String?
    let images: [String]
    let compact: Bool
    /// 0…1, or negative when there is no bar.
    let progress: CGFloat
    let paused: Bool
    let stats: String?
    let note: String?
    let status: String
    let statusText: String?
    let subs: String?
    let subsAction: String?
    let buttons: [DlButton]
}

struct DlButton {
    let id: String
    let label: String
}

/// A menu sliding up from the bottom. A tap sends {a:"sheet", what:id}; closing it sends what "".
struct HomeSheet {
    let key: String
    let items: [SheetItem]
}

struct SheetItem {
    let id: String
    let label: String
    let icon: String?
    let active: Bool
    let danger: Bool
    let indent: Bool
    let group: Bool
    let open: Bool
    let divider: Bool
}

/// A game's scoreboard.
struct HomeMatch {
    let league: String
    let live: Bool
    let status: String
    let home: MatchSide
    let away: MatchSide
}

struct MatchSide {
    let name: String
    let logo: String?
    let score: String
    let yellow: Int
    let red: Int
}

/// Live TV's guide: the hours across, the channels down.
struct HomeGuide {
    let start: Int64
    let end: Int64
    let now: Int64
    let day: String
    let ticks: [GuideTick]
    let channels: [GuideChannel]
    let more: Bool
    let labels: [String: String]

    func label(_ k: String, _ fallback: String) -> String { labels[k] ?? fallback }
}

struct GuideTick {
    let at: Int64
    let label: String
}

struct GuideChannel {
    let name: String
    let number: String?
    let logo: String?
    let programs: [GuideProgram]
}

struct GuideProgram {
    let s: Int64
    let e: Int64
    let title: String
    let from: String
    let to: String
    let replay: Bool
}

struct HomeToast {
    let id: Int
    let text: String
}

struct HomePrompt {
    let key: String
    let title: String
    let hint: String
    let text: String
    let ok: String
    let cancel: String
}

/// A line of credits: a label and the people, or a label and a value.
struct CreditGroup {
    let label: String
    let people: [CriticPerson]
    let value: String?
}

/// A search field; typing sends {a:"query", text}. A new key starts it afresh.
struct HomeSearch {
    let key: String
    let hint: String
    let text: String
    let busy: Bool
    let big: Bool
    let focus: Bool
}

/// A centred message; action is a button's label (sends {a:"message"}).
struct HomeMessage {
    let title: String?
    let text: String?
    let action: String?
}

/// One row of choices; tapping one sends {a:"chip", row:key, what:id}.
struct HomeChips {
    let key: String
    let items: [HomeChip]
}

struct HomeChip {
    let id: String
    let label: String
    let on: Bool
}
