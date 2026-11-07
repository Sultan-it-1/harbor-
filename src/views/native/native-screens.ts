// Android app: the browse screens (Home, Discover, Movies, Shows, Library) drawn natively
// (android/…/NativeScreens.kt, NativeHome.kt) instead of in the page. Some devices (Android 13
// handhelds such as the Anbernic RG 476H) ship a WebView that can't lay the poster rows out at all.
// Each page still decides WHAT it shows (its rows, filters, customisation) and handles every tap;
// the shell only draws it.
//   page   -> HarborAndroid.homeSet(json)               a page's model (HomeModel in Kotlin)
//   page   -> HarborAndroid.screenShow(page, bottom, w)  which page's native screen is up ("" = none)
//   native -> window.__harborNativeHome(json)           taps: {p: page, a: …} (see NativeAction)
import { useEffect, useMemo, useRef, useState } from "react";
import { androidApi, visiblePopups } from "@/lib/android";
import type { Meta } from "@/lib/cinemeta";
import { formatRemaining } from "@/components/continue-card";
import { useContextMenu } from "@/lib/context-menu";
import { useOnboarding } from "@/lib/onboarding";
import { rpdbPoster } from "@/lib/providers/rpdb";
import { useSearch } from "@/lib/search-context";
import { useSettings } from "@/lib/settings";
import { episodeFromVideoId, isAnimeCwItem, libraryMetaType, type LibraryItem } from "@/lib/stremio";
import { useTogether } from "@/lib/together/provider";
import { useView, type PlayEpisode } from "@/lib/view";
import { openUrl } from "@/lib/window";
import { subscribeWatchlist, toggleWatchlist, watchlistHas } from "@/lib/watchlist";
import { isTitleWatched, useWatchedMarksVersion } from "@/lib/watched-marks";
import {
  movePageRow,
  orderedRowKeys,
  renamePageRow,
  resetPageRows,
  togglePageRowHidden,
  type PageRowCustomization,
} from "@/lib/page-rows";

export type T = (key: string, vars?: Record<string, string | number>) => string;

/** A tap on a native screen. */
export type NativeAction = {
  /** The screen it came from ("home", "discover", …). */
  p?: string;
  /** "hero" | "open" | "hold" | "play" | "all" | "more" | "chip" | "customize" | "together" | "failed" */
  a?: string;
  row?: string;
  i?: number;
  what?: string;
  /** "edit" rename: the new name ("" = its own name again). */
  text?: string;
};

/** The shell can draw the browse screens (an Android build with NativeScreens). */
export function nativeScreensAvailable(): boolean {
  const api = androidApi();
  return !!api && "homeSet" in api && "screenShow" in api;
}

// ---- turned off for the session if the shell reports it couldn't show what it got ----

let failed = false;
const failSubs = new Set<() => void>();
function markFailed() {
  if (failed) return;
  failed = true;
  failSubs.forEach((f) => f());
}

/** Native screens on: the setting is on, the shell has them, and nothing went wrong. */
export function useNativeScreensEnabled(): boolean {
  const { settings } = useSettings();
  const [off, setOff] = useState(failed);
  useEffect(() => {
    const f = () => setOff(true);
    failSubs.add(f);
    return () => {
      failSubs.delete(f);
    };
  }, []);
  return settings.nativeHome && !off && nativeScreensAvailable();
}

// ---- which screen is up ----

const wants = new Map<string, boolean>();
const handlers = new Map<string, (a: NativeAction) => void>();
let popupsClear = true;
let tabBarRoom = 0;
let lastSent = "";
let observing = false;

function sendShown() {
  let page = "";
  // Anything the page opens over a screen (dialogs, menus, the More sheet…) must show: the native
  // screen steps aside while one is open. Only one page is on top; the last that wants it wins.
  if (popupsClear) for (const [p, w] of wants) if (w) page = p;
  const key = `${page}|${tabBarRoom}|${window.innerWidth}`;
  if (key === lastSent) return;
  lastSent = key;
  try {
    androidApi()?.screenShow?.(page, tabBarRoom, window.innerWidth);
  } catch {
    /* an older shell */
  }
}

function startObserving() {
  if (observing || typeof document === "undefined") return;
  observing = true;
  let raf = 0;
  const check = () => {
    raf = 0;
    popupsClear = visiblePopups().length === 0;
    // Room for the page's tab bar at the bottom (none while the keyboard hides it).
    const bar = document.querySelector<HTMLElement>("[data-phone-tabbar]");
    const r = bar && !bar.hidden ? bar.getBoundingClientRect() : null;
    tabBarRoom = r && r.height > 0 ? Math.max(0, Math.round(window.innerHeight - r.top)) : 0;
    sendShown();
  };
  const schedule = () => {
    if (!raf) raf = requestAnimationFrame(check);
  };
  new MutationObserver(schedule).observe(document.body, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["role", "aria-modal", "hidden", "class", "style"],
  });
  window.addEventListener("resize", schedule);
  window.__harborNativeHome = (json: string) => {
    let a: NativeAction;
    try {
      a = JSON.parse(json) as NativeAction;
    } catch {
      return;
    }
    if (a.a === "failed") {
      markFailed();
      return;
    }
    handlers.get(a.p || "home")?.(a);
  };
  schedule();
}

/**
 * Publishes a page's [model] to its native screen and keeps that screen up exactly while the page
 * is on top ([active]) with nothing over it. [inUse] = the page is drawn natively right now (the page
 * then renders nothing of its own: it is underneath, out of sight).
 */
export function useNativeScreen(
  page: string,
  o: { inUse: boolean; active: boolean; model: Record<string, unknown> | null; onAction: (a: NativeAction) => void },
): void {
  const { settings } = useSettings();
  const { open: searchOpen } = useSearch();
  const { onboarded } = useOnboarding();
  const { openModal: openTogether } = useTogether();

  // The theme's colours, read once the theme is applied to the page.
  const [colors, setColors] = useState(themeColors);
  useEffect(() => {
    if (!o.inUse) return;
    const id = requestAnimationFrame(() =>
      setColors((prev) => {
        const next = themeColors();
        return JSON.stringify(next) === JSON.stringify(prev) ? prev : next;
      }),
    );
    return () => cancelAnimationFrame(id);
  }, [o.inUse, settings.theme]);

  const json = useMemo(
    () =>
      o.inUse && o.model
        ? JSON.stringify({
            v: 1,
            page,
            rtl: document.documentElement.dir === "rtl",
            colors,
            badgesTop: settings.badgePlacement === "top",
            together: true,
            ...o.model,
          })
        : null,
    [o.inUse, o.model, page, colors, settings.badgePlacement],
  );

  // Sent a moment after the last change: rows arrive one after another while a page loads.
  useEffect(() => {
    if (!json) return;
    const id = window.setTimeout(() => {
      try {
        androidApi()?.homeSet?.(json);
      } catch {
        markFailed();
      }
    }, 80);
    return () => window.clearTimeout(id);
  }, [json]);

  const onAction = useRef(o.onAction);
  onAction.current = o.onAction;
  useEffect(() => {
    if (!o.inUse) return;
    startObserving();
    const h = (a: NativeAction) => (a.a === "together" ? openTogether() : onAction.current(a));
    handlers.set(page, h);
    return () => {
      if (handlers.get(page) === h) handlers.delete(page);
    };
  }, [o.inUse, page, openTogether]);

  const want = o.inUse && o.active && !searchOpen && onboarded && json != null;
  useEffect(() => {
    wants.set(page, want);
    sendShown();
  }, [page, want]);
  useEffect(
    () => () => {
      wants.delete(page);
      sendShown();
    },
    [page],
  );
}

// ---- what the cards show ----

/** MetaHub's poster for an IMDb id (tt…), as Stremio shows it. */
function metahubPoster(id: string): string | undefined {
  const tt = /^(tt\d+)/.exec(id)?.[1];
  return tt ? `https://images.metahub.space/poster/medium/${tt}/img` : undefined;
}

function isUrl(u: string | null | undefined): u is string {
  return typeof u === "string" && /^https?:\/\//.test(u);
}

/** The hero's backdrop at the size the web hero uses: TMDB's full size (the shell keeps it to
 *  1280px on a phone) and Metahub's large one, the given address as the fallback. */
function heroImages(bg: string | undefined): string[] {
  if (!bg) return [];
  const out: string[] = [];
  if (/image\.tmdb\.org\/t\/p\/w\d+\//.test(bg)) out.push(bg.replace(/\/t\/p\/w\d+\//, "/t/p/original/"));
  if (/images\.metahub\.space\/background\/(small|medium)\//.test(bg)) out.push(bg.replace(/\/background\/(small|medium)\//, "/background/large/"));
  out.push(bg);
  return out;
}

/** Poster / Top 10 / hero cards as the page's own cards would show them (follows the settings, the
 *  watched marks and the watchlist; include `cards` in a model's memo so it follows them too). */
export function useNativeCards() {
  const { settings } = useSettings();
  const watchedVer = useWatchedMarksVersion();
  const [watchlistVer, setWatchlistVer] = useState(0);
  useEffect(() => subscribeWatchlist(() => setWatchlistVer((v) => v + 1)), []);
  return useMemo(() => {
    void watchedVer;
    void watchlistVer;
    // The next address is tried when one fails: an IMDb title also has MetaHub's poster (a dead
    // addon's picture, or none at all, still shows one).
    const img = (m: Meta) =>
      [...new Set([rpdbPoster(settings.rpdbKey, m.id, m.poster), m.poster, metahubPoster(m.id)])].filter(isUrl);
    return {
      poster: (m: Meta) => ({
        title: m.name,
        img: img(m),
        rating: settings.showCardBadges && m.imdbRating ? String(m.imdbRating) : null,
        watched: isTitleWatched(m.id),
      }),
      rank: (m: Meta, i: number) => ({ title: m.name, img: img(m), rank: i + 1, watched: isTitleWatched(m.id) }),
      hero: (m: Meta, rank: string | null) => ({
        title: m.name,
        desc: m.description ?? null,
        year: m.releaseInfo ?? null,
        rating: settings.showImdbBadge && m.imdbRating ? String(m.imdbRating) : null,
        runtime: m.runtime ?? null,
        img: [...heroImages(m.background), m.poster].filter(isUrl),
        logo: isUrl(m.logo) ? m.logo : null,
        rank,
        inList: watchlistHas(m.id),
      }),
    };
  }, [settings.rpdbKey, settings.showCardBadges, settings.showImdbBadge, watchedVer, watchlistVer]);
}

/** Labels every screen uses, in the app's language. */
export function nativeLabels(t: T, customize: string) {
  return {
    play: t("Play"),
    add: t("Add to Watchlist"),
    inList: t("In Watchlist"),
    seeAll: t("See all"),
    customize,
    together: t("Watch together"),
    more: t("Show more"),
    less: t("Show less"),
    moreActions: t("More actions"),
    year: t("Year"),
    runtime: t("Runtime"),
    watched: t("Watched"),
    readFull: t("Read full"),
    director: t("Director"),
    close: t("Close"),
    source: t("Open review source"),
  };
}

/** What a tap on a title does: open it; long-press opens the same menu as on the page's cards;
 *  the hero's watchlist button adds / removes it. */
export function useNativeMetaActions() {
  const { openMeta } = useView();
  const { open: openContextMenu } = useContextMenu();
  return useMemo(
    () => ({
      open: (m: Meta | undefined) => {
        if (m) openMeta(m);
      },
      hold: (m: Meta | undefined) => {
        if (!m) return;
        const at = new MouseEvent("contextmenu", { clientX: window.innerWidth / 2, clientY: window.innerHeight / 2 });
        openContextMenu(at, { kind: "meta", meta: m });
      },
      hero: (m: Meta | undefined, what: string | undefined) => {
        if (!m) return;
        if (what === "list") toggleWatchlist({ id: m.id, type: m.type, name: m.name, poster: m.poster });
        else openMeta(m);
      },
    }),
    [openMeta, openContextMenu],
  );
}

// ---- Continue Watching (what ContinueCard shows and does) ----

function cwEpisodeOf(item: LibraryItem) {
  const vid = item.state?.video_id ?? "";
  const kitsuThreeSeg = /^(kitsu|mal|anilist|anidb):/.test(item._id) && vid.split(":").length === 3;
  const ep =
    item.state?.season && item.state?.episode
      ? { season: item.state.season, episode: item.state.episode }
      : kitsuThreeSeg
        ? null
        : episodeFromVideoId(item.state?.video_id);
  const animeEp = kitsuThreeSeg ? Number(vid.split(":")[2]) : isAnimeCwItem(item) && ep ? ep.episode : null;
  return { ep, animeEp, kitsuThreeSeg };
}

export function cwCard(item: LibraryItem, t: T) {
  const dur = item.state?.duration ?? 0;
  const off = item.state?.timeOffset ?? 0;
  const { ep, animeEp } = cwEpisodeOf(item);
  const parts: string[] = [];
  if (animeEp && Number.isFinite(animeEp) && animeEp > 0) parts.push(`Ep ${animeEp}`);
  else if (ep) parts.push(`S${ep.season}E${ep.episode}`);
  if (item.upNext) parts.push(t("Up Next"));
  else if (dur > 0 && item.external !== "simkl") parts.push(formatRemaining(t, dur - off));
  const wide = (u?: string) => (u ? u.replace(/\/t\/p\/original\//, "/t/p/w780/") : u);
  return {
    title: item.name,
    img: [wide(item.background), wide(item.poster)].filter(isUrl),
    sub: parts.join(" · ") || null,
    progress: dur > 0 ? Math.min(1, off / dur) : 0,
  };
}

export function cwMeta(item: LibraryItem): Meta {
  return { id: item._id, type: libraryMetaType(item.type), name: item.name, poster: item.poster, background: item.background };
}

export function cwEpisode(item: LibraryItem): PlayEpisode | undefined {
  const { ep, kitsuThreeSeg } = cwEpisodeOf(item);
  if (item.type === "series" && ep) return ep;
  if (kitsuThreeSeg) {
    const n = Number((item.state?.video_id ?? "").split(":")[2]);
    if (Number.isFinite(n) && n > 0) return { season: 1, episode: n };
  }
  return undefined;
}

// ---- the theme's colours for the native screens ----

function themeColors() {
  if (typeof document === "undefined") return {};
  const cs = getComputedStyle(document.documentElement);
  const read = (name: string) => cssColorToHex(cs.getPropertyValue(name));
  return {
    canvas: read("--color-canvas"),
    surface: read("--color-surface"),
    ink: read("--color-ink"),
    muted: read("--color-ink-muted"),
    subtle: read("--color-ink-subtle"),
    accent: read("--color-accent"),
  };
}

/** "#rgb", "#rrggbb", "rgb()" or "oklch()" (the theme's tokens) as "#rrggbb"; null otherwise.
 *  Done by hand: older WebViews can't parse oklch() themselves. */
export function cssColorToHex(value: string): string | null {
  const v = value.trim().toLowerCase();
  if (!v) return null;
  const hex = v.match(/^#([0-9a-f]{3}|[0-9a-f]{6})([0-9a-f]{2})?$/);
  if (hex) {
    const h = hex[1].length === 3 ? [...hex[1]].map((c) => c + c).join("") : hex[1];
    return `#${h}`;
  }
  const nums = (s: string) => s.split(/[\s,/]+/).filter(Boolean);
  const rgb = v.match(/^rgba?\(([^)]*)\)$/);
  if (rgb) {
    const [r, g, b] = nums(rgb[1]).map((n) => (n.endsWith("%") ? (parseFloat(n) * 255) / 100 : parseFloat(n)));
    if ([r, g, b].some((n) => !Number.isFinite(n))) return null;
    return toHex(r / 255, g / 255, b / 255);
  }
  const ok = v.match(/^oklch\(([^)]*)\)$/);
  if (ok) {
    const [ls, cs, hs] = nums(ok[1]);
    const L = ls?.endsWith("%") ? parseFloat(ls) / 100 : parseFloat(ls ?? "");
    const C = cs?.endsWith("%") ? (parseFloat(cs) / 100) * 0.4 : parseFloat(cs ?? "");
    const H = parseFloat(hs ?? "0") || 0;
    if (!Number.isFinite(L) || !Number.isFinite(C)) return null;
    const hr = (H * Math.PI) / 180;
    const a = C * Math.cos(hr);
    const b = C * Math.sin(hr);
    const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
    const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
    const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
    const lin = (x: number) => (x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055);
    return toHex(
      lin(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
      lin(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
      lin(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
    );
  }
  return null;
}

function toHex(r: number, g: number, b: number): string {
  const c = (x: number) =>
    Math.round(Math.min(1, Math.max(0, Number.isFinite(x) ? x : 0)) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

// ---- a whole browse page (Discover, Movies, Shows, Anime, Library) ----

/** A row as the page shows it (already filtered, renamed and ordered). */
export type NativeRowInput = {
  key: string;
  /** Already in the app's language. */
  title: string;
  metas: Meta[];
  /** Top 10 style: big numbers, the first ten. */
  rank?: boolean;
  /** "See all" opens this list. */
  seeAll?: { title: string; fetcher: (page: number) => Promise<Meta[]>; initial?: Meta[] };
  /** Load more when the row's end comes near. */
  more?: () => void;
  /** Not titles: genre / language / award / collection tiles, service logos, one wide card,
   *  Critics' Pick. */
  kind?: "tile" | "logo" | "feature" | "critic" | "poster" | "credits" | "episodes";
  /** Choices under the title (a series' seasons) and what picking one does. */
  chips?: { key: string; items: Array<{ id: string; label: string; on: boolean }> } | null;
  onRowChip?: (id: string) => void;
  /** Buttons under them (Random, Download season…) and what they do. */
  tools?: Array<{ id: string; label: string }>;
  onTool?: (id: string) => void;
  /** Other taps on a card ("info", "dl", "hold" on an episode); return true when handled. */
  onAction?: (a: string, i: number) => boolean | void;
  /** "credits": who made it (names open the person) and facts, as lines of text. */
  credits?: Array<{ label: string; people?: Array<{ id: number; name: string }>; value?: string | null }>;
  /** Pictures shown full screen by the native screen itself on a tap (a title's stills). */
  gallery?: boolean;
  /** A small line at the end of the title (Critics' Pick: "Loved by reviewers today"). */
  note?: string | null;
  /** Critics' Pick: everything its card shows (see CriticInfo in HomeModel.kt). */
  critic?: Record<string, unknown> | null;
  /** The cards of a [kind] row (its [metas], if any, are what a tap opens). */
  cards?: NativeCardInput[];
  /** What a tap on card [i] does, instead of opening its title. */
  onOpen?: (i: number) => void;
  /** What "See all" does when it isn't a list of titles (Collections opens its own page). */
  onAll?: () => void;
  /** The wide card's Play button. */
  onPlay?: (i: number) => void;
  /** A small second line under the title (a genre page's "TRENDING NOW"). */
  sub?: string | null;
  /** Drawn as a grid down the page instead of a strip ([min]: narrowest card in dp). */
  grid?: boolean;
  min?: number;
  /** Tiles: height / width (16:9 = 0.5625). */
  ratio?: number;
  /** A wide card before the others (a spotlight on a person) and what a tap on it does. */
  lead?: { title: string; sub?: string | null; img?: string[] } | null;
  onLead?: () => void;
};

/** A page's heading (see HomeHeader in HomeModel.kt). */
export type NativeHeader = {
  kicker?: string | null;
  title: string;
  subtitle?: string | null;
  /** A picture instead of the title (a service's logo). */
  logo?: string | null;
  /** A glow of this colour behind it (#rrggbb). */
  tint?: string | null;
  /** Small text after the title ("120 titles"). */
  count?: string | null;
  icon?: "tag" | "calendar" | "clock" | "globe" | "languages" | "building" | "tv" | null;
  /** The title's size in sp (30 by default). */
  size?: number;
  body?: string | null;
  backdrop?: string[];
  /** The title opens these (sends the chip group "switch"). */
  switch?: Array<{ id: string; label: string; on: boolean }>;
};

/** A tile / logo / feature card. */
export type NativeCardInput = {
  title: string;
  img?: string[];
  sub?: string | null;
  tint?: string | null;
  /** Feature card: a label on top, the IMDb rating, a Play button. */
  kicker?: string | null;
  rating?: string | null;
  play?: boolean;
  /** Tile: the picture is an emblem shown whole (awards). */
  emblem?: boolean;
  /** An episode: its number, how far in, watched, overview. */
  rank?: number;
  progress?: number;
  watched?: boolean;
  desc?: string | null;
};

/** The page's row editor (Discover, Movies, Shows): the page-rows customisation it edits. */
export type NativePageEditor = {
  on: boolean;
  setOn: (on: boolean) => void;
  custom: PageRowCustomization;
  /** Every editable row's key, in the page's own order (what movePageRow wants). */
  allKeys: string[];
  persist: (next: PageRowCustomization) => void;
};

/** The editor's labels (the page's own row controls use the same text). */
export function editLabels(t: T) {
  return {
    done: t("Done editing"),
    reset: t("Reset"),
    addSource: t("Add Source"),
    up: t("Move up"),
    down: t("Move down"),
    hide: t("Hide row"),
    show: t("Show row"),
    rename: t("Rename row"),
    save: t("Save"),
    cancel: t("Cancel"),
    resetName: t("Reset to original name"),
    numerals: t("Show as a Top 10 with big numerals"),
    heroSource: t("Feature this catalog in the hero carousel"),
    delete: t("Delete custom source"),
  };
}

/** A row's JSON for the native screen. */
export function nativeRowJson(r: NativeRowInput, cards: ReturnType<typeof useNativeCards>) {
  if (r.kind === "credits") {
    return { key: r.key, title: r.title, kind: "credits", all: false, more: false, items: [], credits: r.credits ?? [] };
  }
  if (r.cards) {
    return {
      key: r.key,
      title: r.title,
      kind: r.kind ?? "tile",
      all: !!r.seeAll || !!r.onAll,
      more: !!r.grid && !!r.more,
      note: r.note ?? null,
      critic: r.critic ?? null,
      sub: r.sub ?? null,
      grid: !!r.grid,
      min: r.min ?? 0,
      ratio: r.ratio ?? 0,
      gallery: !!r.gallery,
      credits: r.credits ?? [],
      lead: r.lead ? { title: r.lead.title, sub: r.lead.sub ?? null, img: (r.lead.img ?? []).filter(isUrlOrData) } : null,
      items: r.cards.map((c) => ({
        title: c.title,
        img: (c.img ?? []).filter(isUrlOrData),
        sub: c.sub ?? null,
        tint: c.tint ?? null,
        kicker: c.kicker ?? null,
        rating: c.rating ?? null,
        play: !!c.play,
        emblem: !!c.emblem,
        rank: c.rank ?? 0,
        progress: c.progress ?? 0,
        watched: !!c.watched,
        desc: c.desc ?? null,
      })),
      chips: r.chips ?? null,
      tools: r.tools ?? [],
    };
  }
  const shown = r.rank ? r.metas.slice(0, 10) : r.metas;
  return {
    key: r.key,
    title: r.title,
    kind: r.rank ? "rank" : "poster",
    all: !!r.seeAll || !!r.onAll,
    more: !r.rank && !!r.more,
    sub: r.sub ?? null,
    grid: !!r.grid,
    min: r.min ?? 0,
    lead: r.lead ? { title: r.lead.title, sub: r.lead.sub ?? null, img: (r.lead.img ?? []).filter(isUrlOrData) } : null,
    items: r.rank ? shown.map(cards.rank) : shown.map(cards.poster),
  };
}

function isUrlOrData(u: string | null | undefined): u is string {
  return typeof u === "string" && (/^https?:\/\//.test(u) || u.startsWith("data:image/"));
}

export type NativePageInput = {
  /** The page is the screen on top. */
  active: boolean;
  /** The page shows itself for now (its row editor is open…). */
  blocked?: boolean;
  t: T;
  hero?: { metas: Meta[]; rank?: string | null } | null;
  header?: NativeHeader | null;
  /** A page opened over another: the Back pill at the top. */
  back?: boolean;
  /** A search field under the heading, held at the top while the page scrolls. */
  search?: { key: string; hint: string; text: string; busy?: boolean; onQuery: (text: string) => void } | null;
  /** A line of small text over the rows. */
  note?: string | null;
  /** A centred message with an optional button (no results…). */
  message?: { title?: string | null; text?: string | null; action?: string | null; onAction?: () => void } | null;
  /** A title's hero and synopsis (see HomeDetail in HomeModel.kt); its buttons and pills. */
  detail?: Record<string, unknown> | null;
  onDetail?: (what: string) => void;
  onPill?: (id: string) => void;
  /** Steps aside for now without giving the page back (a dialog the page opens over it). */
  hidden?: boolean;
  cw?: { title: string; items: LibraryItem[] } | null;
  rows: NativeRowInput[];
  customize?: { label: string; onTap: () => void } | null;
  chips?: Array<{ key: string; items: Array<{ id: string; label: string; on: boolean }> }> | null;
  onChip?: (group: string, id: string) => void;
  /** Shown when there are no rows. */
  empty?: { title?: string | null; text: string } | null;
  /** A long-press the page handles itself (Library: remove); return true when it did. */
  onHold?: (rowKey: string, meta: Meta) => boolean;
  /** Changes when the page wants its top back in view. */
  resetTick?: number;
  /** The page's row editor, drawn in the native screen too (rows then include hidden ones). */
  editor?: NativePageEditor | null;
};

/**
 * Draws a browse page natively and handles its taps. Returns true while the native screen is in
 * use: the page then renders nothing of its own (it is underneath, out of sight).
 */
export function useNativeBrowsePage(page: string, input: NativePageInput): boolean {
  const { settings } = useSettings();
  const { openPicker, openGrid, openPerson, goBack } = useView();
  const enabled = useNativeScreensEnabled();
  const inUse = enabled && !input.blocked;
  const cards = useNativeCards();
  const meta = useNativeMetaActions();
  const published = useRef<{ hero: Meta[]; cw: LibraryItem[]; rows: Map<string, NativeRowInput> }>({
    hero: [],
    cw: [],
    rows: new Map(),
  });

  const { t, hero, header, cw, rows, customize, chips, empty, resetTick, editor, back, note } = input;
  const searchKey = input.search?.key;
  const searchHint = input.search?.hint;
  const searchText = input.search?.text;
  const searchBusy = !!input.search?.busy;
  const msgTitle = input.message?.title ?? null;
  const msgText = input.message?.text ?? null;
  const msgAction = input.message?.action ?? null;
  const hasMessage = !!input.message;
  const detailModel = input.detail;
  const customizeLabel = customize?.label;
  const editing = !!editor?.on;
  const editCustom = editor?.custom;
  const editKeys = editor?.allKeys;
  const model = useMemo(() => {
    if (!inUse) return null;
    const heroMetas = hero?.metas ?? [];
    const out: unknown[] = [];
    const map = new Map<string, NativeRowInput>();
    const cwItems = cw?.items ?? [];
    if (cw && cwItems.length > 0) {
      out.push({ key: "cw", title: cw.title, kind: "cw", items: cwItems.map((i) => cwCard(i, t)) });
    }
    // The editor: every editable row with its controls, hidden ones too (without their cards).
    const order = editing && editCustom && editKeys ? orderedRowKeys(editKeys, editCustom) : [];
    for (const r of rows) {
      const shown = r.rank ? r.metas.slice(0, 10) : r.metas;
      const editable = editing && editCustom && editKeys?.includes(r.key);
      const empty =
        r.kind === "episodes" ? false : r.kind === "credits" ? (r.credits ?? []).length === 0 : (r.cards ? r.cards.length : shown.length) === 0;
      if (!editable && (empty || r.key === "cw")) continue;
      map.set(r.key, { ...r, metas: shown });
      const json = nativeRowJson(r, cards) as Record<string, unknown>;
      if (editable && editCustom) {
        const hidden = editCustom.hidden.includes(r.key);
        const idx = order.indexOf(r.key);
        json.ed = { hidden, up: idx > 0, down: idx >= 0 && idx < order.length - 1, renamed: r.key in editCustom.renamed };
        if (hidden) json.items = [];
      }
      out.push(json);
    }
    published.current = { hero: heroMetas, cw: cwItems, rows: map };
    return {
      top: resetTick ?? 0,
      labels: { ...nativeLabels(t, customizeLabel ?? t("Customize page")), ...editLabels(t) },
      header: header ?? null,
      hero: heroMetas.map((m) => cards.hero(m, hero?.rank ?? null)),
      rows: out,
      chips: chips ?? [],
      empty: empty ?? null,
      customize: !!customizeLabel,
      edit: editing,
      back: back ? t("common.back") : null,
      search: searchKey != null ? { key: searchKey, hint: searchHint ?? "", text: searchText ?? "", busy: searchBusy } : null,
      note: note ?? null,
      message: hasMessage ? { title: msgTitle, text: msgText, action: msgAction } : null,
      detail: detailModel ?? null,
    };
  }, [detailModel, inUse, t, hero, header, cw, rows, customizeLabel, chips, empty, resetTick, cards, editing, editCustom, editKeys, back, note, searchKey, searchHint, searchText, searchBusy, hasMessage, msgTitle, msgText, msgAction]);

  const latest = useRef(input);
  latest.current = input;
  useNativeScreen(page, {
    inUse,
    active: input.active && !input.hidden,
    model,
    onAction: (a: NativeAction) => {
      const p = published.current;
      const i = typeof a.i === "number" ? a.i : -1;
      const cur = latest.current;
      switch (a.a) {
        case "hero":
          return meta.hero(p.hero[i], a.what);
        case "open":
        case "hold": {
          const row = a.row === "cw" ? undefined : p.rows.get(a.row ?? "");
          if (a.a === "open" && row?.onOpen) return row.onOpen(i);
          if (a.a === "hold" && row?.onAction?.("hold", i)) return;
          const m = a.row === "cw" ? (p.cw[i] ? cwMeta(p.cw[i]) : undefined) : row?.metas[i];
          if (a.a === "open") return meta.open(m);
          if (m && a.row && cur.onHold?.(a.row, m)) return;
          return meta.hold(m);
        }
        case "play": {
          const onPlay = a.row !== "cw" ? p.rows.get(a.row ?? "")?.onPlay : undefined;
          if (onPlay) return onPlay(i);
          const item = a.row === "cw" ? p.cw[i] : undefined;
          if (item) openPicker(cwMeta(item), cwEpisode(item), { autoPlay: settings.instantPlay, resume: true });
          return;
        }
        case "done":
          cur.editor?.setOn(false);
          return;
        case "reset":
          cur.editor?.persist(resetPageRows());
          return;
        case "edit": {
          const ed = cur.editor;
          if (!ed || !a.row) return;
          if (a.what === "up" || a.what === "down") ed.persist(movePageRow(ed.custom, ed.allKeys, a.row, a.what === "up" ? -1 : 1));
          else if (a.what === "hide") ed.persist(togglePageRowHidden(ed.custom, a.row));
          else if (a.what === "rename") ed.persist(renamePageRow(ed.custom, a.row, a.text ?? ""));
          return;
        }
        case "all": {
          const row = p.rows.get(a.row ?? "");
          if (row?.onAll) return row.onAll();
          const all = row?.seeAll;
          if (all) openGrid({ title: all.title, fetcher: all.fetcher, initial: all.initial });
          return;
        }
        case "more":
          p.rows.get(a.row ?? "")?.more?.();
          return;
        case "customize":
          if (cur.editor) cur.editor.setOn(true);
          else cur.customize?.onTap();
          return;
        case "chip":
          if (a.row && a.what) cur.onChip?.(a.row, a.what);
          return;
        case "person": {
          const id = Number(a.what);
          if (id > 0) openPerson(id);
          return;
        }
        case "back":
          goBack();
          return;
        case "query":
          cur.search?.onQuery(a.text ?? "");
          return;
        case "lead":
          p.rows.get(a.row ?? "")?.onLead?.();
          return;
        case "message":
          cur.message?.onAction?.();
          return;
        case "d":
          if (a.what) cur.onDetail?.(a.what);
          return;
        case "rowchip":
          if (a.what) p.rows.get(a.row ?? "")?.onRowChip?.(a.what);
          return;
        case "tool":
          if (a.what) p.rows.get(a.row ?? "")?.onTool?.(a.what);
          return;
        case "info":
        case "dl":
          p.rows.get(a.row ?? "")?.onAction?.(a.a, i);
          return;
        case "pill":
          if (a.what) cur.onPill?.(a.what);
          return;
        case "link":
          if (a.text && /^https?:\/\//.test(a.text)) openUrl(a.text);
          return;
      }
    },
  });
  return inUse;
}
