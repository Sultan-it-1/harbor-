// "Download season": for every episode, run the same stream query + ranking the source
// picker uses, take the best stream that can actually be saved, resolve it (debrid /
// direct) and queue the download. Runs one episode at a time.
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
import { activeDownloadFor, enqueueDownload } from "./downloads-store";

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
