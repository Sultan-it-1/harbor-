import { androidApi, onNativePlayerEvent } from "@/lib/android";
import { emptySnapshot, type PlayerBridge, type PlayerSnapshot, type PlayerSource } from "../bridge";

const MAX_SUBS = 8;

// One native player is shared by every bridge instance; only the bridge that loaded
// last may stop it, so a stale bridge being torn down can't kill the new playback.
let owner: object | null = null;

/** Narrow the addon's subtitle list to the user's preferred languages so ExoPlayer
 *  doesn't download dozens of side-loaded files before playback starts. */
function pickSubtitles(subs: PlayerSource["subtitles"]): { url: string; lang?: string }[] {
  if (!subs || subs.length === 0) return [];
  let prefs: string[] = [];
  try {
    const raw = localStorage.getItem("harbor.settings");
    const p = raw ? (JSON.parse(raw) as { preferredSubLangs?: unknown }).preferredSubLangs : null;
    if (Array.isArray(p)) prefs = p.filter((x): x is string => typeof x === "string").map((x) => x.toLowerCase());
  } catch {
    /* ignore */
  }
  const matches = (lang?: string) => {
    if (!lang) return false;
    const l = lang.toLowerCase();
    return prefs.some((p) => l === p || l.startsWith(p) || p.startsWith(l.slice(0, 2)));
  };
  const preferred = prefs.length > 0 ? subs.filter((s) => matches(s.lang)) : [];
  const list = preferred.length > 0 ? preferred : subs;
  return list.slice(0, MAX_SUBS).map((s) => ({ url: s.url, lang: s.lang }));
}

/** Plays through the Android shell's native ExoPlayer (FFmpeg audio decoders included). */
export function createAndroidBridge(): PlayerBridge {
  const api = androidApi();
  let snap: PlayerSnapshot = { ...emptySnapshot };
  const listeners = new Set<(s: PlayerSnapshot) => void>();
  let title = "";
  let active = false;
  const token = {};

  const emit = () => {
    const next = { ...snap };
    listeners.forEach((l) => l(next));
  };

  const off = onNativePlayerEvent((e) => {
    if (!active || owner !== token) return;
    if (e.type === "state") {
      snap.positionSec = e.positionMs / 1000;
      snap.durationSec = e.durationMs / 1000;
      snap.bufferedSec = Math.max(0, (e.bufferedMs - e.positionMs) / 1000);
      snap.buffering = e.buffering;
      snap.rate = e.rate;
      snap.videoWidth = e.width;
      snap.videoHeight = e.height;
      if (snap.status !== "error") {
        snap.status = e.ended ? "ended" : e.playing ? "playing" : e.ready || !e.playWhenReady ? "paused" : "loading";
      }
      emit();
    } else if (e.type === "ended") {
      snap.status = "ended";
      emit();
    } else if (e.type === "error") {
      snap.status = "error";
      const code = e.code as PlayerSnapshot["errorCode"];
      snap.errorCode = code === "decode" || code === "codec" || code === "network" || code === "source" ? code : "unknown";
      snap.errorMessage = e.message;
      emit();
    } else if (e.type === "closed") {
      snap.positionSec = e.positionMs / 1000;
      if (e.durationMs > 0) snap.durationSec = e.durationMs / 1000;
      snap.status = "paused";
      active = false;
      emit();
    }
  });

  const cmd = (c: Record<string, unknown>) => api?.command(JSON.stringify(c));

  return {
    attach() {},
    detach() {},
    async load(src) {
      snap = { ...emptySnapshot, status: "loading", volume: snap.volume, rate: snap.rate };
      active = true;
      owner = token;
      emit();
      api?.play(
        JSON.stringify({
          url: src.url,
          headers: src.headers ?? {},
          startMs: Math.max(0, Math.round((src.startAtSec ?? 0) * 1000)),
          subtitles: pickSubtitles(src.subtitles),
          title,
          isLive: src.isLive === true,
        }),
      );
    },
    async play() {
      cmd({ cmd: "play" });
    },
    pause() {
      cmd({ cmd: "pause" });
    },
    seek(sec) {
      cmd({ cmd: "seek", ms: Math.max(0, Math.round(sec * 1000)) });
    },
    setVolume(v) {
      snap.volume = v;
      cmd({ cmd: "volume", volume: v });
    },
    setMuted(m) {
      snap.muted = m;
      cmd({ cmd: "volume", volume: m ? 0 : snap.volume });
    },
    setRate(r) {
      cmd({ cmd: "rate", rate: r });
    },
    setAudioTrack() {},
    setSubtitleTrack() {},
    setSubVisible() {},
    setSubDelay() {},
    setAudioDelay() {},
    setPanscan() {},
    setVideoZoom() {},
    setAspectOverride() {},
    setAnime4kShaders() {},
    async addSubtitle() {
      return false;
    },
    getSelectedTrackCues: () => null,
    getSelectedTrackUrl: () => null,
    setAudioNormalize() {},
    setMediaInfo(info) {
      title = info.title;
    },
    async screenshot() {
      return { ok: false, error: "not supported" };
    },
    setAbLoop() {},
    async requestPiP() {},
    async exitPiP() {},
    async requestFullscreen() {},
    async exitFullscreen() {},
    capabilities: () => ({
      engine: "html5",
      pictureInPicture: false,
      airplay: false,
      chromecast: false,
      hdrPassthrough: true,
      hardwareDecode: true,
    }),
    subscribe(listener) {
      listeners.add(listener);
      listener({ ...snap });
      return () => listeners.delete(listener);
    },
    destroy() {
      off();
      listeners.clear();
      if (owner === token) {
        api?.stop();
        owner = null;
      }
      active = false;
    },
  };
}
