// The non-title rows of the native screens: genre / language / award / collection tiles, the
// streaming services, the discovery queue and Critics' Pick, built from the same data the page's
// own components use.
import { createElement, useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { AWARDS } from "@/components/award-tiles";
import { GENRE_PALETTE, GENRE_TILES } from "@/components/genre-tiles";
import { laurelColorFor } from "@/components/icons/award-logo";
import { Laurel } from "@/components/icons/laurel";
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

/**
 * [load] for each key (once per session), as a record that fills in as answers arrive. [local]:
 * nothing to download (drawn on the phone), so it doesn't wait behind the network's queue.
 */
function useFetchedOnce<V>(
  prefix: string,
  keys: string[],
  enabled: boolean,
  load: (key: string) => Promise<V>,
  local = false,
): Record<string, V | undefined> {
  const [, setTick] = useState(0);
  const sig = keys.join("|");
  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    for (const k of keys) {
      const id = `${prefix}:${k}`;
      if (fetched.has(id) || inflight.has(id)) continue;
      inflight.add(id);
      (local ? (job: () => Promise<void>) => void job() : enqueue)(async () => {
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

export function useAwardTilesRow(key: string, title: string, enabled: boolean, t: T, view: View): NativeRowInput {
  const emblems = useFetchedOnce(
    "award",
    AWARDS.map((a) => a.type),
    enabled,
    (type) => awardEmblem(type),
    true,
  );
  return {
    key,
    title,
    metas: [],
    kind: "tile",
    cards: AWARDS.map((a) => ({
      title: t(a.name),
      sub: t(a.sub),
      tint: darken(laurelColorFor(a.type), 0.62),
      img: emblems[a.type] ? [emblems[a.type] as string] : [],
      emblem: true,
    })),
    onOpen: (i) => {
      const a = AWARDS[i];
      if (a) view.openAward(a.type);
    },
  };
}

// The award's emblem as the page draws it (its laurel round its statuette), as one picture: the
// native tile can't draw the page's SVG laurel or its masked / filtered logos itself.

const AWARD_LOGOS: Record<string, { src: string; scale: number; mask?: string; filter?: string; box?: [number, number] }> = {
  oscar: { src: "/awards/oscar.png", scale: 1.15 },
  golden_globe: { src: "/awards/golden-globe.png", scale: 1.15 },
  bafta: { src: "/awards/bafta.png", scale: 1, mask: "#CA9200", box: [0.85, 1] },
  emmy: { src: "/awards/emmy.png", scale: 1.1 },
  sag: { src: "/awards/sag.png", scale: 1.15 },
  critics_choice: { src: "/awards/critics-choice.png", scale: 1.1, filter: "saturate(0.4) sepia(0.85) hue-rotate(-12deg) brightness(1.05)" },
  cannes: { src: "/awards/cannestrophy.png", scale: 1.2 },
  venice: { src: "/awards/venice.webp", scale: 1.2 },
  berlin: { src: "/awards/berlin.png", scale: 1.2 },
};

type LaurelShape = { d: string; evenodd: boolean; dx: number; dy: number };
let laurelShapes: LaurelShape[] | null = null;

/** The laurel's paths, read once from the component the page draws. */
function laurel(): LaurelShape[] {
  if (laurelShapes) return laurelShapes;
  const host = document.createElement("div");
  const root = createRoot(host);
  flushSync(() => root.render(createElement(Laurel, { size: 100 })));
  laurelShapes = Array.from(host.querySelectorAll("path")).map((p) => {
    const m = /translate\(\s*(-?[\d.]+)[\s,]+(-?[\d.]+)\s*\)/.exec(p.getAttribute("transform") ?? "");
    return {
      d: p.getAttribute("d") ?? "",
      evenodd: p.getAttribute("fill-rule") === "evenodd",
      dx: m ? Number(m[1]) : 0,
      dy: m ? Number(m[2]) : 0,
    };
  });
  root.unmount();
  return laurelShapes;
}

function loadImage(src: string): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = src;
  });
}

async function awardEmblem(type: string): Promise<string | null> {
  const spec = AWARD_LOGOS[type] ?? AWARD_LOGOS.oscar;
  const logo = await loadImage(spec.src);
  try {
    const color = laurelColorFor(type);
    // The laurel's own proportions (its viewBox is 2000 x 1682).
    const W = 300;
    const H = Math.round((W * 1682) / 2000);
    const layer = (): [HTMLCanvasElement, CanvasRenderingContext2D] | null => {
      const c = document.createElement("canvas");
      c.width = W;
      c.height = H;
      const g = c.getContext("2d");
      return g ? [c, g] : null;
    };
    const out = layer();
    const wreath = layer();
    if (!out || !wreath) return null;
    const [canvas, g] = out;
    // The statuette sits where the page centres it: above the laurel's open bottom.
    const cx = W / 2;
    const cy = H * 0.417;

    // A soft glow of the laurel's colour behind it.
    const glow = g.createRadialGradient(cx, cy, 0, cx, cy, W * 0.4);
    glow.addColorStop(0, hexA(color, 0.24));
    glow.addColorStop(1, hexA(color, 0));
    g.fillStyle = glow;
    g.fillRect(0, 0, W, H);

    // The laurel, with a drop shadow under it as a whole.
    const [wc, wg] = wreath;
    wg.scale(W / 2000, H / 1682);
    wg.fillStyle = color;
    for (const s of laurel()) {
      wg.save();
      wg.translate(s.dx, s.dy);
      wg.fill(new Path2D(s.d), s.evenodd ? "evenodd" : "nonzero");
      wg.restore();
    }
    g.save();
    g.shadowColor = "rgba(0,0,0,0.45)";
    g.shadowBlur = 15;
    g.shadowOffsetY = 4;
    g.globalAlpha = 0.95;
    g.drawImage(wc, 0, 0);
    g.restore();

    if (logo && logo.naturalWidth > 0 && logo.naturalHeight > 0) {
      const size = W / 3;
      let lw: number;
      let lh: number;
      if (spec.box) {
        // Fitted inside a box (the BAFTA mask).
        const bw = size * spec.box[0];
        const bh = size * spec.box[1];
        const k = Math.min(bw / logo.naturalWidth, bh / logo.naturalHeight);
        lw = logo.naturalWidth * k;
        lh = logo.naturalHeight * k;
      } else {
        lh = size * spec.scale;
        lw = (lh * logo.naturalWidth) / logo.naturalHeight;
      }
      const x = cx - lw / 2;
      const y = cy - lh / 2;
      if (spec.mask) {
        const m = layer();
        if (m) {
          const [mc, mg] = m;
          mg.drawImage(logo, x, y, lw, lh);
          mg.globalCompositeOperation = "source-in";
          mg.fillStyle = spec.mask;
          mg.fillRect(0, 0, W, H);
          g.drawImage(mc, 0, 0);
        }
      } else {
        g.save();
        if (spec.filter) g.filter = spec.filter;
        g.drawImage(logo, x, y, lw, lh);
        g.restore();
      }
    }
    const webp = canvas.toDataURL("image/webp", 0.85);
    return webp.startsWith("data:image/webp") ? webp : canvas.toDataURL("image/png");
  } catch {
    return null;
  }
}

/** [hex] with alpha [a], as rgba(). */
function hexA(hex: string, a: number): string {
  const c = cssColorToHex(hex) ?? "#d4af37";
  const n = parseInt(c.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
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

export function criticsRow(key: string, title: string, meta: Meta | null | undefined, t: T, view: View): NativeRowInput | null {
  if (!meta) return null;
  const bg = meta.background ?? meta.poster;
  const big = bg?.replace(/\/t\/p\/w\d+\//, "/t/p/original/");
  const year = meta.releaseInfo ?? null;
  return {
    key,
    title,
    metas: [meta],
    kind: "feature",
    cards: [
      {
        title: meta.name,
        sub: meta.description ?? null,
        img: [big, bg].filter((u): u is string => !!u),
        kicker: [t("Loved by reviewers today"), year].filter(Boolean).join(" · "),
        rating: meta.imdbRating ?? null,
        play: true,
      },
    ],
    onPlay: () => view.openPicker(meta),
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
