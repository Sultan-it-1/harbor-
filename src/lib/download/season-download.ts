// "Download season": for every episode, run the same stream query + ranking the source
// picker uses, take the best stream that can actually be saved, resolve it (debrid /
// direct) and queue the download. Runs one episode at a time, and keeps running when you
// leave the page (or, on Android, the app).
import { useSyncExternalStore } from "react";
import type { Meta } from "@/lib/cinemeta";
import type { DebridStore } from "@/lib/debrid/types";
import type { Settings } from "@/lib/settings";
import { runPipeline } from "@/lib/streams/pipeline";
import { resolveStream } from "@/lib/streams/resolve";
import { buildStreamIds } from "@/lib/streams/stream-ids";
import type { ScoredStream } from "@/lib/streams/types";
import { tmdbImdbId } from "@/lib/providers/tmdb";
import type { PlayEpisode } from "@/lib/view";
import { loadPickerAddons } from "@/views/play-picker/use-addons";
import { buildPipelineInput } from "@/views/play-picker/use-pipeline-result";
import { activeDownloadFor, beginBackgroundJob, endBackgroundJob, enqueueDownload } from "./downloads-store";

export type SeasonDownloadProgress = {
  total: number;
  done: number;
  queued: number;
  skipped: number;
  failed: PlayEpisode[];
  current: PlayEpisode | null;
  finished: boolean;
};

const isCached = (s: ScoredStream) => Object.values(s.cached ?? {}).some(Boolean);

/** Streams worth trying for a download, best first: cached on a debrid or a direct link. */
function downloadCandidates(all: ScoredStream[]): ScoredStream[] {
  const direct = (s: ScoredStream) => !!s.url && s.url !== "#" && !s.infoHash;
  const good = all.filter((s) => isCached(s) || direct(s));
  const rest = all.filter((s) => !good.includes(s));
  return [...good, ...rest].slice(0, 4);
}

export async function downloadSeason(opts: {
  meta: Meta;
  episodes: PlayEpisode[];
  authKey: string | null;
  settings: Settings;
  debrids: DebridStore[];
  signal: AbortSignal;
  onProgress: (p: SeasonDownloadProgress) => void;
}): Promise<SeasonDownloadProgress> {
  const { meta, episodes, authKey, settings, debrids, signal, onProgress } = opts;
  const state: SeasonDownloadProgress = {
    total: episodes.length,
    done: 0,
    queued: 0,
    skipped: 0,
    failed: [],
    current: null,
    finished: false,
  };
  const emit = () => onProgress({ ...state, failed: [...state.failed] });
  emit();

  const { addons } = await loadPickerAddons(authKey, settings);
  let imdbId: string | null = meta.id.startsWith("tt") ? meta.id : null;
  if (!imdbId && settings.tmdbKey) imdbId = await tmdbImdbId(settings.tmdbKey, meta.id).catch(() => null);

  for (const ep of episodes) {
    if (signal.aborted) break;
    state.current = ep;
    emit();
    // Already saved or downloading: don't fetch it twice.
    const existing = activeDownloadFor(meta.id, ep.season, ep.episode);
    if (existing && existing.status !== "error" && existing.status !== "canceled") {
      state.skipped++;
      state.done++;
      emit();
      continue;
    }
    let ok = false;
    try {
      const streamIds = buildStreamIds(meta.id, ep, imdbId, meta.behaviorHints?.defaultVideoId);
      if (streamIds.length > 0) {
        const result = await runPipeline(
          buildPipelineInput({
            meta,
            episode: ep,
            imdbId,
            streamIds,
            addons,
            debrids,
            settings,
            strictMode: settings.streamFilterLevel === "strict",
            filterDisabled: settings.streamFilterLevel === "off",
          }),
          signal,
        );
        for (const s of downloadCandidates(result.picker.all)) {
          if (signal.aborted) break;
          const r = await resolveStream(s, debrids, signal, true);
          if (!r.ok) continue;
          const label =
            [s.resolution, s.source].filter(Boolean).join(" ") || s.parsedTitle || s.title || s.name || s.addonName || null;
          await enqueueDownload({
            meta,
            episode: ep,
            streamLabel: label,
            url: r.data.url,
            rawUrl: r.data.url,
            headers: r.data.headers,
            subtitles: r.data.subtitles,
          });
          ok = true;
          break;
        }
      }
    } catch (e) {
      if (signal.aborted) break;
      console.warn("[season-download] episode failed", ep, e);
    }
    if (ok) state.queued++;
    else state.failed.push(ep);
    state.done++;
    emit();
  }
  state.current = null;
  state.finished = true;
  emit();
  return state;
}

// ---- running season downloads ---------------------------------------------------------
// Held here rather than in the button, so leaving the show's page doesn't stop the queue.

type SeasonJob = {
  key: string;
  title: string;
  season: number | null;
  progress: SeasonDownloadProgress;
  ac: AbortController;
};

const jobs = new Map<string, SeasonJob>();
const jobListeners = new Set<() => void>();
let jobList: SeasonJob[] = [];

function notifyJobs() {
  jobList = [...jobs.values()];
  jobListeners.forEach((l) => l());
}

function subscribeJobs(l: () => void) {
  jobListeners.add(l);
  return () => {
    jobListeners.delete(l);
  };
}

export function seasonJobKey(metaId: string, episodes: PlayEpisode[]): string {
  return `${metaId}|s${episodes[0]?.season ?? ""}`;
}

export function startSeasonDownload(
  key: string,
  opts: Omit<Parameters<typeof downloadSeason>[0], "signal" | "onProgress">,
): void {
  const cur = jobs.get(key);
  if (cur && !cur.progress.finished) return;
  const ac = new AbortController();
  const job: SeasonJob = {
    key,
    title: opts.meta.name ?? "",
    season: opts.episodes[0]?.season ?? null,
    ac,
    progress: { total: opts.episodes.length, done: 0, queued: 0, skipped: 0, failed: [], current: null, finished: false },
  };
  jobs.set(key, job);
  notifyJobs();
  const bgKey = `season:${key}`;
  beginBackgroundJob(bgKey);
  void downloadSeason({
    ...opts,
    signal: ac.signal,
    onProgress: (p) => {
      job.progress = p;
      notifyJobs();
    },
  })
    .catch((e: unknown) => console.warn("[season-download] stopped", e))
    .finally(() => {
      job.progress = { ...job.progress, current: null, finished: true };
      endBackgroundJob(bgKey);
      notifyJobs();
      // Keep the summary up for a moment, then forget the job.
      window.setTimeout(() => {
        if (jobs.get(key) !== job) return;
        jobs.delete(key);
        notifyJobs();
      }, 10_000);
    });
}

export function stopSeasonDownload(key: string): void {
  jobs.get(key)?.ac.abort();
}

export function useSeasonDownload(key: string): SeasonDownloadProgress | null {
  return useSyncExternalStore(subscribeJobs, () => jobs.get(key)?.progress ?? null);
}

/** Season queues still looking for sources (Downloads page). */
export function useRunningSeasonJobs(): { key: string; title: string; season: number | null; progress: SeasonDownloadProgress }[] {
  const all = useSyncExternalStore(subscribeJobs, () => jobList);
  return all.filter((j) => !j.progress.finished);
}
