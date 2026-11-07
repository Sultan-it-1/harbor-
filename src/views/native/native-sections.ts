// The non-title rows of the native screens: genre / language / award / collection tiles, the
// streaming services, the discovery queue and Critics' Pick, built from the same data the page's
// own components use.
import { useEffect, useState } from "react";
import { AWARDS } from "@/components/award-tiles";
import { GENRE_PALETTE, GENRE_TILES } from "@/components/genre-tiles";
import { laurelColorFor } from "@/components/icons/award-logo";
import { LANGS } from "@/components/language-tiles";
import type { Meta } from "@/lib/cinemeta";
import { COLLECTIONS_CATALOG } from "@/lib/collections-catalog";
import { fetchGenreSample, type FeedItem } from "@/lib/feed";
import { MOVIE_GENRES } from "@/lib/feed/tags";
import { collectionNameMatches, tmdbCollection, tmdbDiscover, tmdbSearchCollectionId } from "@/lib/providers/tmdb";
import { SERVICES } from "@/lib/providers/streaming";
import type { StreamingService } from "@/lib/settings";
import { useView } from "@/lib/view";
import { cssColorToHex, type NativeRowInput, type T } from "./native-screens";

type View = ReturnType<typeof useView>;

// ---- pictures fetched once per session, a few at a time ----

const fetched = new Map<string, unknown>();
const inflight = new Set<string>();
const queue: Array<() => Promise<void>> = [];
let running = 0;
function enqueue(job: () => Promise<void>) {
  queue.push(job);
  const pump = () => {
    while (running < 3 && queue.length > 0) {
      const next = queue.shift()!;
      running++;
      void next().finally(() => {
        running--;
        pump();
      });
    }
  };
  pump();
}

/** [load] for each key (once per session), as a record that fills in as answers arrive. */
function useFetchedOnce<V>(prefix: string, keys: string[], enabled: boolean, load: (key: string) => Promise<V>): Record<string, V | undefined> {
  const [, setTick] = useState(0);
  const sig = keys.join("|");
  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    for (const k of keys) {
      const id = `${prefix}:${k}`;
      if (fetched.has(id) || inflight.has(id)) continue;
      inflight.add(id);
      enqueue(async () => {
        let v: unknown = null;
        try {
          v = await load(k);
        } catch {
          v = null;
        }
        fetched.set(id, v);
        inflight.delete(id);
        if (alive) setTick((n) => n + 1);
      });
    }
    // Answers that arrive later for keys another screen asked for.
    const poll = window.setInterval(() => {
      if (keys.some((k) => inflight.has(`${prefix}:${k}`))) setTick((n) => n + 1);
      else window.clearInterval(poll);
    }, 1500);
    return () => {
      alive = false;
      window.clearInterval(poll);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prefix, sig, enabled]);
  const out: Record<string, V | undefined> = {};
  for (const k of keys) out[k] = fetched.get(`${prefix}:${k}`) as V | undefined;
  return out;
}

const firstBackdrop = (list: Meta[]) => list.find((m) => m.background)?.background ?? null;

// ---- genre / language / award tiles (Discover) ----

export function useGenreTilesRow(key: string, title: string, enabled: boolean, tmdbKey: string, t: T, view: View): NativeRowInput {
  const img = useFetchedOnce(`genre:${tmdbKey ? "tmdb" : "cm"}`, GENRE_TILES, enabled, (g) => fetchGenreSample(tmdbKey, g).then(firstBackdrop));
  return {
    key,
    title,
    metas: [],
    kind: "tile",
    cards: GENRE_TILES.map((g) => ({
      title: t(g),
      img: img[g] ? [img[g] as string] : [],
      tint: cssColorToHex((GENRE_PALETTE[g] ?? GENRE_PALETTE.Drama).from),
    })),
    onOpen: (i) => {
      const g = GENRE_TILES[i];
      const id = g ? MOVIE_GENRES[g] : undefined;
      if (g && id != null) view.openFilter({ kind: "genre", mediaType: "movie", name: g, id });
    },
  };
}

export function useLanguageTilesRow(key: string, title: string, enabled: boolean, tmdbKey: string, t: T, view: View): NativeRowInput {
  const img = useFetchedOnce(
    "lang",
    LANGS.map((l) => l.iso),
    enabled && !!tmdbKey,
    (iso) =>
      tmdbDiscover(tmdbKey, "tv", { with_original_language: iso, sort_by: "popularity.desc", "vote_count.gte": "150" }).then(firstBackdrop),
  );
  return {
    key,
    title,
    metas: [],
    kind: "tile",
    cards: LANGS.map((l) => ({
      title: t(l.name),
      sub: l.endonym,
      img: img[l.iso] ? [img[l.iso] as string] : [],
      tint: cssColorToHex(`oklch(0.42 0.13 ${l.hue})`),
    })),
    onOpen: (i) => {
      const l = LANGS[i];
      if (l) view.openFilter({ kind: "language", mediaType: "tv", name: l.name, iso: l.iso });
    },
  };
}

export function awardTilesRow(key: string, title: string, t: T, view: View): NativeRowInput {
  return {
    key,
    title,
    metas: [],
    kind: "tile",
    cards: AWARDS.map((a) => ({ title: t(a.name), sub: t(a.sub), tint: darken(laurelColorFor(a.type), 0.72) })),
    onOpen: (i) => {
      const a = AWARDS[i];
      if (a) view.openAward(a.type);
    },
  };
}

// ---- collections (Home, Discover) ----

type Resolved = { id: number; backdrop: string | null; count: number } | null;

export function useCollectionsRow(key: string, title: string, enabled: boolean, tmdbKey: string, t: T, view: View): NativeRowInput {
  const list = COLLECTIONS_CATALOG.slice(0, 24);
  const resolved = useFetchedOnce<Resolved>(
    "coll",
    list.map((c) => `${c.id}|${c.name}`),
    enabled && !!tmdbKey,
    async (k) => {
      const [idStr, ...rest] = k.split("|");
      const id = Number(idStr);
      const name = rest.join("|");
      let c = id > 0 ? await tmdbCollection(tmdbKey, id).catch(() => null) : null;
      if (!c || (id <= 0 && !collectionNameMatches(c.name, name))) {
        const healed = await tmdbSearchCollectionId(tmdbKey, name).catch(() => null);
        if (healed != null && healed !== id) c = await tmdbCollection(tmdbKey, healed).catch(() => null);
      }
      return c ? { id: c.id, backdrop: c.backdrop ?? null, count: c.parts.length } : null;
    },
  );
  return {
    key,
    title,
    metas: [],
    kind: "tile",
    cards: list.map((c) => {
      const r = resolved[`${c.id}|${c.name}`];
      return {
        title: c.name,
        sub: r ? t("{count} films", { count: r.count }) : t("Collection"),
        img: r?.backdrop ? [r.backdrop] : [],
        tint: cssColorToHex(`oklch(0.42 0.13 ${((c.id || c.name.length * 37) * 47) % 360})`),
      };
    }),
    onAll: () => view.openCollections(),
    onOpen: (i) => {
      const c = list[i];
      if (!c) return;
      const r = resolved[`${c.id}|${c.name}`];
      const id = r?.id ?? c.id;
      if (id > 0) view.openCollection(id);
    },
  };
}

// ---- streaming services (Home) ----

const logoCache = new Map<string, Promise<string | null>>();

/** A service's (SVG) logo drawn white into a PNG: Android can't show SVG pictures itself. */
function rasterLogo(src: string): Promise<string | null> {
  let p = logoCache.get(src);
  if (!p) {
    p = new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        try {
          const w0 = img.naturalWidth || 300;
          const h0 = img.naturalHeight || 150;
          let h = 72;
          let w = Math.max(1, Math.round((h * w0) / h0));
          if (w > 420) {
            h = Math.max(1, Math.round((h * 420) / w));
            w = 420;
          }
          const c = document.createElement("canvas");
          c.width = w;
          c.height = h;
          const g = c.getContext("2d");
          if (!g) return resolve(null);
          g.drawImage(img, 0, 0, w, h);
          g.globalCompositeOperation = "source-in";
          g.fillStyle = "#ffffff";
          g.fillRect(0, 0, w, h);
          resolve(c.toDataURL("image/png"));
        } catch {
          resolve(null);
        }
      };
      img.onerror = () => resolve(null);
      img.src = src;
    });
    logoCache.set(src, p);
  }
  return p;
}

export function useServicesRow(services: StreamingService[], enabled: boolean, t: T, view: View): NativeRowInput | null {
  const logos = useFetchedOnce("svc", services, enabled, (svc) => {
    const logo = SERVICES[svc as StreamingService]?.logo;
    return logo ? rasterLogo(logo) : Promise.resolve(null);
  });
  if (services.length === 0) return null;
  return {
    key: "services",
    title: t("Your Streaming"),
    metas: [],
    kind: "logo",
    cards: services.map((s) => ({ title: SERVICES[s]?.name ?? s, img: logos[s] ? [logos[s] as string] : [] })),
    onOpen: (i) => {
      const s = services[i];
      if (s) view.openService(s);
    },
  };
}

// ---- Discover: the queue and Critics' Pick ----

export function queueRow(key: string, title: string, items: FeedItem[], t: T, view: View): NativeRowInput | null {
  if (items.length === 0) return null;
  const bg = items.map((it) => it.meta.background).find(Boolean);
  return {
    key,
    title,
    metas: [],
    kind: "feature",
    cards: [{ title: t("Explore your queue"), sub: t("{count} picks ready", { count: items.length }), img: bg ? [bg] : [] }],
    onOpen: () => view.openQueue(),
  };
}

export function criticsRow(key: string, title: string, meta: Meta | null | undefined): NativeRowInput | null {
  if (!meta) return null;
  const bg = meta.background ?? meta.poster;
  const big = bg?.replace(/\/t\/p\/w\d+\//, "/t/p/original/");
  return {
    key,
    title,
    metas: [meta],
    kind: "feature",
    cards: [{ title: meta.name, sub: meta.description ?? null, img: [big, bg].filter((u): u is string => !!u) }],
  };
}

/** A colour [f] of the way to black (the award tiles are a dark shade of their laurel's gold). */
function darken(hex: string, f: number): string | null {
  const c = cssColorToHex(hex);
  if (!c) return null;
  const n = parseInt(c.slice(1), 16);
  const ch = (v: number) =>
    Math.round(v * (1 - f))
      .toString(16)
      .padStart(2, "0");
  return `#${ch((n >> 16) & 255)}${ch((n >> 8) & 255)}${ch(n & 255)}`;
}
