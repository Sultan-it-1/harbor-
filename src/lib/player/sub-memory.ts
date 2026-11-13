import type { TrackInfo } from "./bridge";

// The exact subtitles picked for one episode (or movie), so the same ones come back the next
// time it plays. The per-title language memory in player-prefs stays the fallback.
const STORAGE_KEY = "harbor.player.episode-subs.v1";
const MAX_ENTRIES = 400;

/** One exact subtitle: an addon (or other external) subtitle by the address it came from, an
 *  embedded one by its language and title (its flags and position among equal ones break ties). */
export type SubPick =
  | { kind: "url"; url: string; lang?: string }
  | { kind: "embedded"; lang: string; title: string; forced?: boolean; hi?: boolean; nth?: number };

export type EpisodeSubs = {
  /** null: picked "off" for this episode. Left out: nothing remembered. */
  first?: SubPick | null;
  /** null: the viewer chose no second subtitle for this episode. */
  second?: SubPick | null;
  secondDelaySec?: number;
  updatedAt: number;
};

type Store = Record<string, EpisodeSubs>;

let cache: Store | null = null;

function loadStore(): Store {
  if (cache) return cache;
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    const parsed = raw ? (JSON.parse(raw) as unknown) : null;
    cache = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Store) : {};
  } catch {
    cache = {};
  }
  return cache;
}

function persistStore(): void {
  if (!cache) return;
  const entries = Object.entries(cache);
  if (entries.length > MAX_ENTRIES) {
    entries.sort((a, b) => b[1].updatedAt - a[1].updatedAt);
    cache = Object.fromEntries(entries.slice(0, MAX_ENTRIES));
  }
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(cache));
  } catch {
    /* ignore */
  }
}

/** Title + season + episode (a movie has no season or episode). */
export function episodeSubsKey(metaId: string, season?: number | null, episode?: number | null): string {
  if (!metaId) return "";
  return `${metaId}|${season ?? ""}|${episode ?? ""}`;
}

export function readEpisodeSubs(key: string): EpisodeSubs | null {
  if (!key) return null;
  return loadStore()[key] ?? null;
}

export function writeEpisodeSubs(key: string, patch: Partial<Omit<EpisodeSubs, "updatedAt">>): void {
  if (!key) return;
  const store = loadStore();
  const prev = store[key] ?? { updatedAt: 0 };
  store[key] = { ...prev, ...patch, updatedAt: Date.now() };
  persistStore();
}

type PickSource = Partial<Pick<TrackInfo, "lang" | "title" | "external" | "url" | "forced" | "hearingImpaired" | "id">>;

/** What to remember about a track, or null when it can't be found again (an external
 *  subtitle without an address). */
export function pickFromTrack(t: PickSource, all: PickSource[] = []): SubPick | null {
  if (t.external) {
    return t.url ? { kind: "url", url: t.url, lang: t.lang } : null;
  }
  const lang = t.lang ?? "";
  const title = t.title ?? "";
  const same = all.filter((x) => !x.external && sameEmbedded(x, lang, title, !!t.forced, !!t.hearingImpaired));
  const nth = Math.max(0, same.findIndex((x) => x.id === t.id));
  return { kind: "embedded", lang, title, forced: !!t.forced, hi: !!t.hearingImpaired, nth };
}

function sameEmbedded(x: PickSource, lang: string, title: string, forced: boolean, hi: boolean): boolean {
  return (x.lang ?? "") === lang && (x.title ?? "") === title && !!x.forced === forced && !!x.hearingImpaired === hi;
}

/** The track a remembered pick stands for, if the player has it now. An addon subtitle only
 *  matches when it is offered again (same address). */
export function findPickedTrack(tracks: TrackInfo[], pick: SubPick | null | undefined): TrackInfo | null {
  if (!pick) return null;
  if (pick.kind === "url") return tracks.find((t) => t.external && t.url === pick.url) ?? null;
  const lang = pick.lang ?? "";
  const title = pick.title ?? "";
  const embedded = tracks.filter((t) => !t.external && (t.lang ?? "") === lang && (t.title ?? "") === title);
  if (embedded.length === 0) return null;
  const exact = embedded.filter((t) => !!t.forced === !!pick.forced && !!t.hearingImpaired === !!pick.hi);
  const pool = exact.length > 0 ? exact : embedded;
  return pool[Math.min(pick.nth ?? 0, pool.length - 1)] ?? pool[0];
}
