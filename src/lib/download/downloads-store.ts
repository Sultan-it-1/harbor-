import { downloadDir as systemDownloadDir } from "@tauri-apps/api/path";
import { exists, remove } from "@tauri-apps/plugin-fs";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { useSyncExternalStore } from "react";
import type { Meta } from "@/lib/cinemeta";
import type { PlayEpisode } from "@/lib/view";
import { buildDefaultFilename } from "./filename";
import { startDownload, type DownloadHandle } from "./video-download";
import {
  androidDownloadsAvailable,
  gatherDownloadSubtitles,
  nativeAddSubs,
  nativeDelete,
  nativeKeepAlive,
  nativePause,
  nativeResume,
  nativeStart,
  nativeStatus,
} from "./android-downloads";

// Android app: the app downloads the files itself, in the background (see android-downloads.ts).
const ANDROID = androidDownloadsAvailable();

export type DownloadItem = {
  id: string;
  metaId: string;
  title: string;
  subtitle: string | null;
  poster: string | null;
  season: number | null;
  episode: number | null;
  streamLabel: string | null;
  url: string;
  path: string;
  status: "downloading" | "done" | "error" | "canceled" | "interrupted";
  receivedBytes: number;
  totalBytes: number | null;
  ratio: number;
  bytesPerSec: number;
  error: string | null;
  startedAt: number;
  /** Android: "Queued", "Waiting for internet", "Retrying in 10s", "Paused"… */
  note?: string | null;
  /** Android: paused by the user (still counts as an unfinished download). */
  paused?: boolean;
  /** Android: false when retrying can't help (the app lost the download or its link). */
  retryable?: boolean;
  /** Android: subtitles saved with the video, and whether a search is still running. */
  subsCount?: number;
  subsState?: "searching" | "done" | null;
};

type EnqueueArgs = {
  meta: Meta;
  episode?: PlayEpisode;
  streamLabel?: string | null;
  url: string;
  /** Android: the un-proxied URL + headers for the system downloader. */
  rawUrl?: string;
  headers?: Record<string, string>;
  /** Subtitles that came with the stream itself. */
  subtitles?: { url: string; lang?: string }[];
};

const items = new Map<string, DownloadItem>();
const handles = new Map<string, DownloadHandle>();
const speed = new Map<string, { bytes: number; at: number }>();
const listeners = new Set<() => void>();

let snapshot: DownloadItem[] = [];

const PERSIST_KEY = "harbor.downloads.v1";

// Android: work that runs in the page after you leave the app (season queues, subtitle
// searches). While there is any, the app keeps a background service up (DownloadService).
const backgroundJobs = new Set<string>();
let keepAliveOn = false;
let keepAliveTimer: number | null = null;

function syncKeepAlive() {
  if (!ANDROID) return;
  const busy = backgroundJobs.size > 0 || [...items.values()].some((d) => d.subsState === "searching");
  if (busy && !keepAliveOn) {
    keepAliveOn = true;
    nativeKeepAlive(true);
    // The app lets it lapse after a while unless it's renewed (a page that died mid-job
    // mustn't keep it up forever).
    keepAliveTimer = window.setInterval(() => nativeKeepAlive(true), 60_000);
  } else if (!busy && keepAliveOn) {
    keepAliveOn = false;
    if (keepAliveTimer != null) window.clearInterval(keepAliveTimer);
    keepAliveTimer = null;
    nativeKeepAlive(false);
  }
}

export function beginBackgroundJob(key: string): void {
  backgroundJobs.add(key);
  syncKeepAlive();
}

export function endBackgroundJob(key: string): void {
  backgroundJobs.delete(key);
  syncKeepAlive();
}

function persist() {
  try {
    const durable = [...items.values()].map((d) => ({ ...d, bytesPerSec: 0 }));
    localStorage.setItem(PERSIST_KEY, JSON.stringify(durable));
  } catch {
    /* ignore */
  }
}

function rebuild() {
  snapshot = [...items.values()].sort((a, b) => b.startedAt - a.startedAt);
  persist();
  syncKeepAlive();
  listeners.forEach((l) => l());
}

// Subtitle searches cut short by the app closing; they run again once the store is ready.
const interruptedSubSearches: string[] = [];

function hydrate() {
  try {
    const raw = localStorage.getItem(PERSIST_KEY);
    if (!raw) return;
    const arr = JSON.parse(raw) as DownloadItem[];
    if (!Array.isArray(arr)) return;
    for (const d of arr) {
      if (!d || typeof d.id !== "string" || typeof d.path !== "string") continue;
      // Desktop downloads die with the app; Android's system downloader keeps going.
      const status = d.status === "downloading" && !ANDROID ? "interrupted" : d.status;
      // A subtitle search interrupted by closing the app is "not searched yet": run it again.
      if (ANDROID && d.subsState === "searching" && d.status !== "error" && d.status !== "canceled") {
        interruptedSubSearches.push(d.id);
      }
      items.set(d.id, { ...d, status, bytesPerSec: 0, subsState: d.subsState === "searching" ? null : d.subsState });
    }
    snapshot = [...items.values()].sort((a, b) => b.startedAt - a.startedAt);
  } catch {
    /* ignore */
  }
}

hydrate();

// ---- Android: poll the app's downloader -------------------------------------------------

let pollTimer: number | null = null;

function pollAndroid() {
  const st = nativeStatus();
  const now = Date.now();
  let active = 0;
  let changed = false;
  const set = (d: DownloadItem, next: Partial<DownloadItem>) => {
    const keys = Object.keys(next) as (keyof DownloadItem)[];
    if (keys.every((k) => d[k] === next[k])) return;
    items.set(d.id, { ...d, ...next });
    changed = true;
  };
  for (const d of [...items.values()]) {
    if (!d.path.startsWith("android:")) continue;
    const n = st[d.id];
    if (n && typeof n.subs === "number") set(d, { subsCount: n.subs });
    const cur = items.get(d.id) ?? d;
    if (!n) {
      // The app doesn't know it (any more): don't leave it spinning forever.
      if (cur.status === "downloading" && now - cur.startedAt > 60_000) {
        set(cur, { status: "error", error: "This download was lost. Delete it and download it again.", bytesPerSec: 0, note: null, paused: false, retryable: false });
      }
      continue;
    }
    if (n.status === "missing") {
      if (cur.status === "downloading") set(cur, { status: "canceled", bytesPerSec: 0, note: null, paused: false });
      continue;
    }
    const received = n.received ?? cur.receivedBytes;
    const total = n.total ?? cur.totalBytes;
    if (n.status === "done") {
      if (cur.status !== "done") {
        set(cur, { status: "done", receivedBytes: total ?? received, totalBytes: total ?? received, ratio: 1, bytesPerSec: 0, note: null, paused: false, error: null });
      }
      continue;
    }
    if (n.status === "error") {
      if (cur.status === "downloading" || cur.status === "error") {
        set(cur, { status: "error", error: n.reason || "Download failed", bytesPerSec: 0, note: null, paused: false, receivedBytes: received, totalBytes: total ?? null, ratio: total ? Math.min(1, received / total) : 0 });
      }
      continue;
    }
    // queued / waiting / paused / downloading
    if (cur.status !== "downloading" && cur.status !== "error") continue;
    active++;
    const s = speed.get(d.id);
    let bps = cur.bytesPerSec;
    if (s && now - s.at >= 900) {
      bps = Math.max(0, ((received - s.bytes) / (now - s.at)) * 1000);
      speed.set(d.id, { bytes: received, at: now });
    } else if (!s) speed.set(d.id, { bytes: received, at: now });
    set(cur, {
      status: "downloading",
      error: null,
      receivedBytes: received,
      totalBytes: total ?? null,
      ratio: total ? Math.min(1, received / total) : 0,
      bytesPerSec: n.status === "downloading" ? bps : 0,
      note: n.status === "downloading" ? null : n.reason || "Waiting…",
      paused: n.status === "paused",
    });
  }
  if (changed) rebuild();
  const pending = [...items.values()].some(
    (d) => d.status === "downloading" || d.subsState === "searching" || now - (subsSavingUntil.get(d.id) ?? 0) < 0,
  );
  if (!pending && active === 0 && pollTimer != null) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }
}

// Subtitles are saved by the native side after the search hands them over; keep
// polling for a while so the count shows up.
const subsSavingUntil = new Map<string, number>();

// One subtitle search at a time (a season download queues many), no hard time limit.
let subsQueue: Promise<void> = Promise.resolve();

function queueSubtitleSearch(id: string, meta: Meta, episode: PlayEpisode | undefined) {
  patch(id, { subsState: "searching" });
  subsQueue = subsQueue.then(async () => {
    if (!items.has(id)) return;
    const found = await Promise.race([
      gatherDownloadSubtitles(meta, episode),
      new Promise<{ url: string; lang?: string; label?: string }[]>((r) => window.setTimeout(() => r([]), 90_000)),
    ]).catch(() => []);
    if (!items.has(id)) return;
    if (found.length > 0 && nativeAddSubs(id, found)) subsSavingUntil.set(id, Date.now() + 60_000);
    patch(id, { subsState: "done" });
    ensureAndroidPolling();
  });
}

/** Downloads page: search (again) for subtitles to save with a finished or running download. */
export function fetchDownloadSubtitles(id: string): void {
  const d = items.get(id);
  if (!d || !ANDROID) return;
  const meta = { id: d.metaId, type: d.season != null ? "series" : "movie", name: d.title } as Meta;
  const episode = d.season != null && d.episode != null ? { season: d.season, episode: d.episode } : undefined;
  queueSubtitleSearch(id, meta, episode);
  ensureAndroidPolling();
}

function ensureAndroidPolling() {
  if (!ANDROID || pollTimer != null) return;
  pollTimer = window.setInterval(pollAndroid, 1000);
}

if (ANDROID && [...items.values()].some((d) => d.status === "downloading")) ensureAndroidPolling();
if (ANDROID) for (const id of interruptedSubSearches) fetchDownloadSubtitles(id);

/** Downloads page: re-read the app's downloader once (e.g. subtitles saved from the player). */
export function refreshDownloads(): void {
  if (!ANDROID) return;
  pollAndroid();
  if ([...items.values()].some((d) => d.status === "downloading")) ensureAndroidPolling();
}

/** Android: pause a running download (it keeps what it has). */
export function pauseDownload(id: string): void {
  if (!ANDROID || !nativePause(id)) return;
  patch(id, { paused: true, note: "Paused", bytesPerSec: 0 });
}

/** Android: carry on with a paused download, or retry a failed one from where it stopped. */
export function resumeDownload(id: string): void {
  if (!ANDROID) return;
  if (!nativeResume(id)) {
    // Nothing to resume from (lost, or no link any more): the error text says what to do.
    patch(id, { retryable: false });
    refreshDownloads();
    return;
  }
  patch(id, { status: "downloading", paused: false, error: null, note: "Queued", retryable: true });
  ensureAndroidPolling();
}

function patch(id: string, next: Partial<DownloadItem>) {
  const cur = items.get(id);
  if (!cur) return;
  items.set(id, { ...cur, ...next });
  rebuild();
}

function sep(): string {
  return navigator.platform.toLowerCase().includes("win") ? "\\" : "/";
}

async function resolveDir(): Promise<string> {
  try {
    const raw = localStorage.getItem("harbor.settings");
    const fromSettings = raw ? (JSON.parse(raw) as { downloadDir?: string }).downloadDir?.trim() : "";
    if (fromSettings) return fromSettings;
  } catch {
    /* fall through to system default */
  }
  return (await systemDownloadDir().catch(() => "")) || "";
}

async function pathTaken(path: string): Promise<boolean> {
  for (const d of items.values()) if (d.path === path) return true;
  try {
    return await exists(path);
  } catch {
    return false;
  }
}

async function uniquePath(path: string): Promise<string> {
  if (!(await pathTaken(path))) return path;
  const s = sep();
  const slash = path.lastIndexOf(s);
  const dir = slash >= 0 ? path.slice(0, slash + 1) : "";
  const file = slash >= 0 ? path.slice(slash + 1) : path;
  const dot = file.lastIndexOf(".");
  const stem = dot > 0 ? file.slice(0, dot) : file;
  const ext = dot > 0 ? file.slice(dot) : "";
  for (let i = 2; i < 1000; i++) {
    const candidate = `${dir}${stem} (${i})${ext}`;
    if (!(await pathTaken(candidate))) return candidate;
  }
  return path;
}

function randomId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  return `${Date.now().toString(36)}${Math.floor(performance.now()).toString(36)}`;
}

export function activeDownloadFor(
  metaId: string,
  season?: number | null,
  episode?: number | null,
): DownloadItem | null {
  for (const d of items.values()) {
    if (d.metaId !== metaId) continue;
    if (season != null && episode != null) {
      if (d.season !== season || d.episode !== episode) continue;
    } else if (d.season != null || d.episode != null) {
      continue;
    }
    return d;
  }
  return null;
}

/** Android: the saved (or still downloading) copy of this title/episode, if there is one. */
export function androidDownloadIdFor(
  metaId: string,
  season?: number | null,
  episode?: number | null,
): string | null {
  if (!ANDROID) return null;
  for (const d of items.values()) {
    if (d.metaId !== metaId || !d.path.startsWith("android:")) continue;
    if (d.status !== "done" && d.status !== "downloading") continue;
    if ((season ?? null) !== d.season || (episode ?? null) !== d.episode) continue;
    return d.id;
  }
  return null;
}

export async function enqueueDownload(args: EnqueueArgs): Promise<string> {
  const { meta, episode, streamLabel, url } = args;
  const dir = await resolveDir();
  const filename = buildDefaultFilename(meta, episode, url, streamLabel);
  const path = await uniquePath(
    dir ? `${dir}${dir.endsWith(sep()) ? "" : sep()}${filename}` : filename,
  );
  const id = randomId();
  const item: DownloadItem = {
    id,
    metaId: meta.id,
    title: meta.name ?? "Download",
    subtitle: episode
      ? `S${episode.imdbSeason ?? episode.season} · E${String(episode.imdbEpisode ?? episode.episode).padStart(2, "0")}${episode.name ? ` · ${episode.name}` : ""}`
      : (meta.releaseInfo ?? null),
    poster: meta.poster ?? null,
    season: episode?.season ?? null,
    episode: episode?.episode ?? null,
    streamLabel: streamLabel ?? null,
    url,
    path,
    status: "downloading",
    receivedBytes: 0,
    totalBytes: null,
    ratio: 0,
    bytesPerSec: 0,
    error: null,
    startedAt: Date.now(),
  };
  items.set(id, item);
  speed.set(id, { bytes: 0, at: Date.now() });
  rebuild();

  if (ANDROID) {
    item.path = `android:${id}`;
    items.set(id, { ...item });
    rebuild();
    // Start the video right away; the subtitle search (which can take a while on a phone,
    // and runs one title at a time) adds its results to the download when it's done.
    const r = nativeStart({
      id,
      url: args.rawUrl ?? url,
      headers: args.headers,
      fileName: filename,
      title: item.title,
      description: item.subtitle,
      subtitles: (args.subtitles ?? []).slice(0, 4).map((s) => ({ url: s.url, lang: s.lang })),
    });
    if (!r.ok) {
      patch(id, { status: "error", error: r.error ?? "Download failed" });
      return id;
    }
    ensureAndroidPolling();
    queueSubtitleSearch(id, meta, episode);
    return id;
  }

  const handle = startDownload(id, url, path, (p) => {
    const now = Date.now();
    const s = speed.get(id);
    let bps = 0;
    if (s && now - s.at >= 500) {
      bps = ((p.receivedBytes - s.bytes) / (now - s.at)) * 1000;
      speed.set(id, { bytes: p.receivedBytes, at: now });
    }
    patch(id, {
      receivedBytes: p.receivedBytes,
      totalBytes: p.totalBytes,
      ratio: p.ratio,
      ...(bps > 0 ? { bytesPerSec: bps } : {}),
    });
  });
  handles.set(id, handle);
  handle.promise
    .then(() => patch(id, { status: "done", ratio: 1, bytesPerSec: 0 }))
    .catch((e: unknown) => {
      if (e instanceof Error && e.name === "AbortError") {
        patch(id, { status: "canceled", bytesPerSec: 0 });
        return;
      }
      patch(id, { status: "error", error: e instanceof Error ? e.message : "Download failed", bytesPerSec: 0 });
    })
    .finally(() => {
      handles.delete(id);
      speed.delete(id);
    });
  return id;
}

export function cancelDownload(id: string): void {
  if (ANDROID) {
    // Cancelling frees the space right away (pause keeps what's downloaded).
    removeDownload(id);
    return;
  }
  handles.get(id)?.abort();
}

export function removeDownload(id: string): void {
  const item = items.get(id);
  handles.get(id)?.abort();
  handles.delete(id);
  speed.delete(id);
  if (items.delete(id)) rebuild();
  if (ANDROID) {
    nativeDelete(id); // video + subtitles + folder, for good
    return;
  }
  if (item) {
    void remove(item.path).catch(() => {});
    void remove(`${item.path}.part`).catch(() => {});
  }
}

export async function revealDownload(id: string): Promise<void> {
  const d = items.get(id);
  if (!d) return;
  try {
    await revealItemInDir(d.path);
  } catch {
    /* opener unavailable */
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useDownloads(): DownloadItem[] {
  return useSyncExternalStore(subscribe, () => snapshot, () => snapshot);
}

export function useActiveDownloadCount(): number {
  const all = useDownloads();
  return all.filter((d) => d.status === "downloading").length;
}
