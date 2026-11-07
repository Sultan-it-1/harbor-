// Android app: Home drawn natively (see src/views/native/native-screens.ts). The page still
// decides what Home shows (addons, TMDB, Trakt, the row order and hidden rows…) and handles every
// tap; the shell only draws it.
import { useMemo, useRef } from "react";
import type { Meta } from "@/lib/cinemeta";
import type { Slide } from "@/components/hero-carousel";
import { useSettings } from "@/lib/settings";
import type { LibraryItem } from "@/lib/stremio";
import { useView } from "@/lib/view";
import {
  cwCard,
  cwEpisode,
  cwMeta,
  nativeLabels,
  nativeScreensAvailable,
  useNativeCards,
  useNativeMetaActions,
  useNativeScreen,
  useNativeScreensEnabled,
  type NativeAction,
  type T,
} from "@/views/native/native-screens";
import type { HomeRow } from "./home-types";

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

/** The shell can draw the browse screens (kept under this name for the Settings switch). */
export const nativeHomeAvailable = nativeScreensAvailable;

/**
 * Publishes Home to its native screen. Returns true while the native Home is in use: the page then
 * leaves its own Home empty (it is underneath, out of sight).
 */
export function useNativeHome(input: NativeHomeInput): boolean {
  const { settings } = useSettings();
  const { openPicker, openGrid } = useView();
  const enabled = useNativeScreensEnabled();
  const inUse = enabled && !input.editMode;
  const cards = useNativeCards();
  const meta = useNativeMetaActions();

  const published = useRef<{ hero: Meta[]; cw: LibraryItem[]; rows: Map<string, { metas: Meta[]; row?: HomeRow }> }>({
    hero: [],
    cw: [],
    rows: new Map(),
  });
  const model = useMemo(() => {
    if (!inUse) return null;
    const { t } = input;
    const hero = input.showHero ? input.heroSlides.map((s) => s.meta) : [];
    const rows: unknown[] = [];
    const rowMap = new Map<string, { metas: Meta[]; row?: HomeRow }>();
    if (input.cwItems.length > 0) {
      rows.push({ key: "cw", title: t("Continue Watching"), kind: "cw", items: input.cwItems.map((i) => cwCard(i, t)) });
    }
    if (input.top10.length >= 10) {
      rowMap.set("top10", { metas: input.top10 });
      rows.push({ key: "top10", title: input.top10Title, kind: "rank", items: input.top10.map(cards.rank) });
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
        items: ranked ? shown.map(cards.rank) : shown.map(cards.poster),
      });
    }
    published.current = { hero, cw: input.cwItems, rows: rowMap };
    return {
      top: input.resetTick,
      labels: nativeLabels(t, t("Customize home")),
      hero: input.heroSlides
        .slice(0, hero.length)
        .map((s) => cards.hero(s.meta, t("#{position} in {label} Today", { position: s.rank.position, label: t(s.rank.label) }))),
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
    };
  }, [inUse, input.t, input.heroSlides, input.showHero, input.cwItems, input.signedIn, input.top10, input.top10Title, input.rows, input.resetTick, cards]);

  useNativeScreen("home", {
    inUse,
    active: input.active,
    model,
    onAction: (a: NativeAction) => {
      const p = published.current;
      const i = typeof a.i === "number" ? a.i : -1;
      switch (a.a) {
        case "hero":
          return meta.hero(p.hero[i], a.what);
        case "open":
        case "hold": {
          const m = a.row === "cw" ? (p.cw[i] ? cwMeta(p.cw[i]) : undefined) : p.rows.get(a.row ?? "")?.metas[i];
          return a.a === "open" ? meta.open(m) : meta.hold(m);
        }
        case "play": {
          const item = a.row === "cw" ? p.cw[i] : undefined;
          if (item) openPicker(cwMeta(item), cwEpisode(item), { autoPlay: settings.instantPlay, resume: true });
          return;
        }
        case "all": {
          const row = p.rows.get(a.row ?? "")?.row;
          if (row?.fetcher) openGrid({ title: input.t(row.name), fetcher: row.fetcher, initial: row.metas });
          return;
        }
        case "more":
          if (a.row) input.onLoadMore(a.row);
          return;
        case "customize":
          input.setEditMode(true);
          return;
      }
    },
  });

  return inUse;
}
