// Android app: Home drawn natively (android/…/NativeHome.kt) instead of in the page. Some devices
// (Android 13 handhelds such as the Anbernic RG 476H) ship a WebView that can't lay the poster rows
// out at all. The page still decides what Home shows (addons, TMDB, Trakt, the row order and
// hidden rows…) and handles every tap; the shell only draws it.
//   page   -> HarborAndroid.homeSet(json)          what to show (HomeModel in Kotlin)
//   page   -> HarborAndroid.homeShow(on, bottom, w) on while Home is on screen with nothing over it
//   native -> window.__harborNativeHome(json)      taps (see onAction below)
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { androidApi, visiblePopups } from "@/lib/android";
import type { Meta } from "@/lib/cinemeta";
import { formatRemaining } from "@/components/continue-card";
import type { Slide } from "@/components/hero-carousel";
import { useOnboarding } from "@/lib/onboarding";
import { rpdbPoster } from "@/lib/providers/rpdb";
import { useSearch } from "@/lib/search-context";
import { useSettings } from "@/lib/settings";
import { episodeFromVideoId, isAnimeCwItem, libraryMetaType, type LibraryItem } from "@/lib/stremio";
import { useTogether } from "@/lib/together/provider";
import { useView, type PlayEpisode } from "@/lib/view";
import { subscribeWatchlist, toggleWatchlist, watchlistHas } from "@/lib/watchlist";
import { isTitleWatched, useWatchedMarksVersion } from "@/lib/watched-marks";
import type { HomeRow } from "./home-types";

type T = (key: string, vars?: Record<string, string | number>) => string;

/** A row as the page would show it, already filtered (see CustomizableRows). */
export type NativeHomeRow = { row: HomeRow; metas: Meta[]; ranked: boolean };

export type NativeHomeInput = {
  /** Home is the screen on top. */
  active: boolean;
  editMode: boolean;
  setEditMode: (on: boolean) => void;
  t: T;
  heroSlides: Slide[];
  showHero: boolean;
  cwItems: LibraryItem[];
  signedIn: boolean;
  top10: Meta[];
  top10Title: string;
  rows: NativeHomeRow[];
  onLoadMore: (rowKey: string) => void;
  resetTick: number;
};

/** The shell can draw Home (an Android build with NativeHome). */
export function nativeHomeAvailable(): boolean {
  const api = androidApi();
  return !!api && "homeSet" in api && "homeShow" in api;
}

// Turned off for the rest of the session if the shell reports it couldn't show what it got.
let failedThisSession = false;

/**
 * Publishes Home to the native screen and keeps it shown exactly while Home is on top with
 * nothing over it. Returns true while the native Home is in use: the page then leaves its own Home
 * empty (it is underneath, out of sight).
 */
export function useNativeHome(input: NativeHomeInput): boolean {
  const { settings } = useSettings();
  const { openMeta, openPicker, openGrid } = useView();
  const { open: searchOpen } = useSearch();
  const { onboarded } = useOnboarding();
  const { openModal: openTogether } = useTogether();
  const [failed, setFailed] = useState(failedThisSession);
  const enabled = settings.nativeHome && !failed && nativeHomeAvailable();
  const inUse = enabled && !input.editMode;

  // ---- what native shows ----
  const watchedVer = useWatchedMarksVersion();
  const [watchlistVer, setWatchlistVer] = useState(0);
  useEffect(() => (inUse ? subscribeWatchlist(() => setWatchlistVer((v) => v + 1)) : undefined), [inUse]);
  const published = useRef<{ hero: Meta[]; cw: LibraryItem[]; rows: Map<string, { metas: Meta[]; row?: HomeRow }> }>({
    hero: [],
    cw: [],
    rows: new Map(),
  });
  const model = useMemo(() => {
    if (!inUse) return null;
    const { t } = input;
    const rtl = document.documentElement.dir === "rtl";
    const poster = (m: Meta) => [rpdbPoster(settings.rpdbKey, m.id, m.poster), m.poster].filter(isUrl);
    const rating = (m: Meta) => (settings.showCardBadges && m.imdbRating ? String(m.imdbRating) : null);
    const hero = input.showHero ? input.heroSlides.map((s) => s.meta) : [];
    const rows: unknown[] = [];
    const rowMap = new Map<string, { metas: Meta[]; row?: HomeRow }>();

    if (input.cwItems.length > 0) {
      rows.push({
        key: "cw",
        title: t("Continue Watching"),
        kind: "cw",
        items: input.cwItems.map((i) => cwCard(i, t)),
      });
    }
    if (input.top10.length >= 10) {
      rowMap.set("top10", { metas: input.top10 });
      rows.push({
        key: "top10",
        title: input.top10Title,
        kind: "rank",
        items: input.top10.map((m, i) => ({ title: m.name, img: poster(m), rank: i + 1, watched: isTitleWatched(m.id) })),
      });
    }
    for (const { row, metas, ranked } of input.rows) {
      if (row.sourceRow || metas.length === 0) continue;
      const shown = ranked ? metas.slice(0, 10) : metas;
      rowMap.set(row.key, { metas: shown, row });
      rows.push({
        key: row.key,
        title: t(row.name),
        kind: ranked ? "rank" : "poster",
        all: !!row.fetcher,
        more: !ranked && row.hasMore,
        items: shown.map((m, i) =>
          ranked
            ? { title: m.name, img: poster(m), rank: i + 1, watched: isTitleWatched(m.id) }
            : { title: m.name, img: poster(m), rating: rating(m), watched: isTitleWatched(m.id) },
        ),
      });
    }
    published.current = { hero, cw: input.cwItems, rows: rowMap };
    const json = JSON.stringify({
      v: 1,
      rtl,
      top: input.resetTick,
      badgesTop: settings.badgePlacement === "top",
      colors: themeColors(),
      labels: {
        play: t("Play"),
        add: t("Add to Watchlist"),
        inList: t("In Watchlist"),
        seeAll: t("See all"),
        customize: t("Customize home"),
        together: t("Watch together"),
        year: t("Year"),
        runtime: t("Runtime"),
        watched: t("Watched"),
      },
      hero: input.heroSlides.slice(0, hero.length).map((s) => ({
        title: s.meta.name,
        desc: s.meta.description ?? null,
        year: s.meta.releaseInfo ?? null,
        rating: settings.showImdbBadge && s.meta.imdbRating ? String(s.meta.imdbRating) : null,
        runtime: s.meta.runtime ?? null,
        img: [s.meta.background, s.meta.poster].filter(isUrl),
        logo: isUrl(s.meta.logo) ? s.meta.logo : null,
        rank: t("#{position} in {label} Today", { position: s.rank.position, label: t(s.rank.label) }),
        inList: watchlistHas(s.meta.id),
      })),
      rows,
      cwEmpty:
        input.cwItems.length > 0
          ? null
          : {
              title: t("Continue Watching"),
              text: input.signedIn
                ? t("Nothing in progress yet. Press Play on something.")
                : `${t("Sign in to")} Stremio ${t("to bring in your library.")}`,
            },
      customize: true,
      together: true,
    });
    return json;
    // watchlistVer / watchedVer: the hero's watchlist buttons and the cards' watched checks follow them.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inUse, input.t, input.heroSlides, input.showHero, input.cwItems, input.signedIn, input.top10, input.top10Title, input.rows, input.resetTick, settings.rpdbKey, settings.showCardBadges, settings.showImdbBadge, settings.badgePlacement, watchlistVer, watchedVer]);

  // Sent a moment after the last change: rows arrive one after another while Home loads.
  useEffect(() => {
    if (!model) return;
    const id = window.setTimeout(() => {
      try {
        androidApi()?.homeSet?.(model);
      } catch {
        failedThisSession = true;
        setFailed(true);
      }
    }, 80);
    return () => window.clearTimeout(id);
  }, [model]);

  // ---- taps on the native Home ----
  const latest = useRef(input);
  latest.current = input;
  const onAction = useCallback(
    (json: string) => {
      let a: { a?: string; row?: string; i?: number; what?: string };
      try {
        a = JSON.parse(json);
      } catch {
        return;
      }
      const p = published.current;
      const i = typeof a.i === "number" ? a.i : -1;
      switch (a.a) {
        case "hero": {
          const m = p.hero[i];
          if (!m) return;
          if (a.what === "list") toggleWatchlist({ id: m.id, type: m.type, name: m.name, poster: m.poster });
          else openMeta(m);
          return;
        }
        case "open": {
          if (a.row === "cw") {
            const item = p.cw[i];
            if (item) openMeta(cwMeta(item));
            return;
          }
          const m = a.row ? p.rows.get(a.row)?.metas[i] : undefined;
          if (m) openMeta(m);
          return;
        }
        case "play": {
          const item = a.row === "cw" ? p.cw[i] : undefined;
          if (!item) return;
          openPicker(cwMeta(item), cwEpisode(item), { autoPlay: settings.instantPlay, resume: true });
          return;
        }
        case "all": {
          const row = a.row ? p.rows.get(a.row)?.row : undefined;
          if (row?.fetcher) openGrid({ title: latest.current.t(row.name), fetcher: row.fetcher, initial: row.metas });
          return;
        }
        case "more":
          if (a.row) latest.current.onLoadMore(a.row);
          return;
        case "customize":
          latest.current.setEditMode(true);
          return;
        case "together":
          openTogether();
          return;
        case "failed":
          failedThisSession = true;
          setFailed(true);
          return;
      }
    },
    [openMeta, openPicker, openGrid, openTogether, settings.instantPlay],
  );
  useEffect(() => {
    if (!enabled) return;
    window.__harborNativeHome = onAction;
    return () => {
      if (window.__harborNativeHome === onAction) window.__harborNativeHome = undefined;
    };
  }, [enabled, onAction]);

  // ---- on screen or not ----
  // Anything the page opens over Home (dialogs, menus, the More sheet…) must show: native Home
  // steps aside while one is open, and leaves room for the page's tab bar at the bottom.
  const [clear, setClear] = useState(true);
  const [bottom, setBottom] = useState(0);
  useEffect(() => {
    if (!enabled) return;
    let raf = 0;
    const check = () => {
      raf = 0;
      setClear(visiblePopups().length === 0);
      const bar = document.querySelector<HTMLElement>("[data-phone-tabbar]");
      const r = bar && !bar.hidden ? bar.getBoundingClientRect() : null;
      setBottom(r && r.height > 0 ? Math.max(0, Math.round(window.innerHeight - r.top)) : 0);
    };
    const schedule = () => {
      if (!raf) raf = requestAnimationFrame(check);
    };
    const mo = new MutationObserver(schedule);
    mo.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["role", "aria-modal", "hidden", "class", "style"] });
    window.addEventListener("resize", schedule);
    schedule();
    return () => {
      mo.disconnect();
      window.removeEventListener("resize", schedule);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [enabled]);

  const show = inUse && input.active && !searchOpen && onboarded && clear && model != null;
  useEffect(() => {
    if (!enabled) return;
    try {
      androidApi()?.homeShow?.(show, bottom, window.innerWidth);
    } catch {
      /* the shell has no native Home after all */
    }
  }, [enabled, show, bottom]);
  useEffect(
    () => () => {
      try {
        androidApi()?.homeShow?.(false, 0, window.innerWidth);
      } catch {
        /* nothing to hide */
      }
    },
    [],
  );

  return inUse;
}

function isUrl(u: string | null | undefined): u is string {
  return typeof u === "string" && /^https?:\/\//.test(u);
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

function cwCard(item: LibraryItem, t: T) {
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

function cwMeta(item: LibraryItem): Meta {
  return { id: item._id, type: libraryMetaType(item.type), name: item.name, poster: item.poster, background: item.background };
}

function cwEpisode(item: LibraryItem): PlayEpisode | undefined {
  const { ep, kitsuThreeSeg } = cwEpisodeOf(item);
  if (item.type === "series" && ep) return ep;
  if (kitsuThreeSeg) {
    const n = Number((item.state?.video_id ?? "").split(":")[2]);
    if (Number.isFinite(n) && n > 0) return { season: 1, episode: n };
  }
  return undefined;
}

// ---- the theme's colours for the native screen ----

function themeColors() {
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
  const hex = v.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/);
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
