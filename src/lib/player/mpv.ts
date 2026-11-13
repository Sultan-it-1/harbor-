import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import {
  emptySnapshot,
  type PlayerBridge,
  type PlayerCapabilities,
  type PlayerSnapshot,
  type PlayerSource,
  type TrackInfo,
} from "./bridge";

export type MpvProbe = {
  available: boolean;
  binary: string | null;
  version: string | null;
  error: string | null;
};

export async function probeMpv(): Promise<MpvProbe> {
  try {
    return await invoke<MpvProbe>("mpv_probe");
  } catch (e) {
    return {
      available: false,
      binary: null,
      version: null,
      error: e instanceof Error ? e.message : String(e),
    };
  }
}

type MpvEvent =
  | {
      event: "property-change";
      id?: number;
      name: string;
      data: unknown;
    }
  | { event: "end-file"; reason?: string }
  | { event: "playback-restart" }
  | { event: "file-loaded" }
  | { event: string; [k: string]: unknown };

export type MpvRect = {
  cssLeft: number;
  cssTop: number;
  cssWidth: number;
  cssHeight: number;
  cssViewW: number;
  cssViewH: number;
};

export type MpvOptions = {
  anime4k: boolean;
  hdrToSdr: boolean;
  embed?: boolean;
  anime4kShaders?: string[];
  d3d11Flip?: boolean;
  extraOptions?: string;
  getEmbedRect?: () => Promise<MpvRect | null> | MpvRect | null;
};

const AUDIO_PROFILE_AF: Record<string, string> = {
  bass: "lavfi=[bass=g=7:f=110:w=0.6]",
  voice: "lavfi=[equalizer=f=300:t=q:w=1:g=-3,equalizer=f=2800:t=q:w=1:g=5]",
  "bass-reduce": "lavfi=[bass=g=-8:f=110:w=0.6]",
  night: "lavfi=[acompressor=ratio=3:threshold=-20dB:attack=20:release=300:makeup=4dB]",
};

const DEFAULT_UA = "VLC/3.0.20 LibVLC/3.0.20";

async function applyHeaderProps(headers?: Record<string, string>): Promise<void> {
  let ua = DEFAULT_UA;
  const fields: string[] = [];
  for (const [k, v] of Object.entries(headers ?? {})) {
    if (k.toLowerCase() === "user-agent") ua = v;
    else fields.push(`${k}: ${v}`);
  }
  await invoke("mpv_set_property", { name: "user-agent", value: ua }).catch(() => {});
  await invoke("mpv_set_property", { name: "http-header-fields", value: fields.join(",") }).catch(() => {});
}

export function createMpvBridge(mpvOptions?: MpvOptions): PlayerBridge {
  let host: HTMLElement | null = null;
  let snap: PlayerSnapshot = { ...emptySnapshot };
  let profileAf = "";
  const applyAudioFilters = () => {
    const parts: string[] = [];
    if (snap.audioNormalize) parts.push("dynaudnorm=f=500:g=31:p=0.9:m=4");
    if (profileAf) parts.push(profileAf);
    if (parts.length > 0) parts.push("lavfi=[alimiter=limit=0.97]");
    invoke("mpv_command", { cmd: ["af", "set", parts.join(",")] }).catch(() => {});
  };
  const listeners = new Set<(s: PlayerSnapshot) => void>();
  let unlistenEvent: UnlistenFn | null = null;
  let unlistenLog: UnlistenFn | null = null;
  let pendingTracks: Record<string, unknown[]> = {};
  let geomTimer: number | null = null;
  let geomKickHandler: ((e?: Event) => void) | null = null;
  let geomForceHandler: (() => void) | null = null;
  let geomResizeObserver: ResizeObserver | null = null;
  let geomTauriUnlisten: Array<() => void> = [];
  let mpvStarted = false;
  let suppressEndFileUntil = 0;
  const urlByExternalFilename = new Map<string, string>();

  const emit = () => {
    const next: PlayerSnapshot = { ...snap };
    listeners.forEach((l) => l(next));
  };

  // mpv's own word on which track is the first (sid) and which the second (secondary-sid)
  // subtitle: an id, null for none, undefined while mpv hasn't said.
  let mpvSid: string | null | undefined = undefined;
  let mpvSecondarySid: string | null | undefined = undefined;

  // The address a subtitle was added from. The shell downloads addon subtitles to a temp file
  // first, so mpv only knows that file; a subtitle mpv loaded straight from the web keeps its
  // own address.
  const addonUrlFor = (externalFilename: string): string | undefined =>
    urlByExternalFilename.get(externalFilename) ??
    (/^https?:/i.test(externalFilename) ? externalFilename : undefined);

  const trackListHasMainSelection = (list: Array<Record<string, unknown>>): boolean =>
    list.some((t) => t.type === "sub" && t.selected === true && typeof t["main-selection"] === "number");

  // mpv marks both the first and the second subtitle "selected". Its main-selection field
  // tells them apart (0 = first, 1 = second). An mpv without it is told apart with sid and
  // secondary-sid; a lone selected subtitle is the first one (as before) unless mpv says it
  // is the second.
  const subRole = (
    t: Record<string, unknown>,
    hasMainSelection: boolean,
    selectedSubs: number,
  ): "first" | "second" | null => {
    if (t.selected !== true) return null;
    const id = String(t.id ?? "");
    const mainSelection = t["main-selection"];
    if (hasMainSelection && typeof mainSelection === "number") return mainSelection === 1 ? "second" : "first";
    if (selectedSubs < 2) return mpvSecondarySid === id && mpvSid !== id ? "second" : "first";
    if (mpvSid !== undefined) return id === mpvSid ? "first" : "second";
    if (mpvSecondarySid !== undefined) return id === mpvSecondarySid ? "second" : "first";
    return "first";
  };

  const roleSignature = (subs: TrackInfo[]): string =>
    subs.map((t) => `${t.id}:${t.selected ? 1 : 0}${t.secondarySelected ? 1 : 0}`).join(",");

  const buildTracks = (list: Array<Record<string, unknown>>, selectionOnly = false) => {
    const hasMainSelection = trackListHasMainSelection(list);
    const selectedSubs = list.filter((t) => t.type === "sub" && t.selected === true).length;
    const audio: TrackInfo[] = [];
    const subs: TrackInfo[] = [];
    for (const t of list) {
      const type = String(t.type ?? "");
      const id = String(t.id ?? "");
      const lang = (t.lang ?? t.language) as string | undefined;
      const title = t.title as string | undefined;
      const codecDesc = (t["codec-desc"] as string | undefined) || (t.codec as string | undefined);
      const channels = t["demux-channels"] as string | undefined;
      const channelCount = typeof t["demux-channel-count"] === "number"
        ? (t["demux-channel-count"] as number)
        : undefined;
      const external = t.external === true;
      const externalFilename = t["external-filename"] as string | undefined;
      const forced = t.forced === true;
      const isDefault = t.default === true;
      const hearingImpaired = t["hearing-impaired"] === true;
      const selected = t.selected === true;
      const role = type === "sub" ? subRole(t, hasMainSelection, selectedSubs) : null;
      const codec = codecDesc ? codecDesc.toUpperCase() : undefined;
      const baseLabel = title || lang || `${type} ${id}`;
      const tags: string[] = [];
      if (codec) tags.push(codec);
      if (type === "audio" && channels) tags.push(channels);
      if (forced) tags.push("Forced");
      if (hearingImpaired) tags.push("SDH");
      if (external) tags.push("External");
      const label = tags.length > 0 ? `${baseLabel} · ${tags.join(" · ")}` : baseLabel;
      const info: TrackInfo = {
        id,
        label,
        lang,
        kind: type === "audio" ? "audio" : "subtitle",
        // For subtitles "selected" means the first subtitle only.
        selected: type === "sub" ? role === "first" : selected,
        codec,
        channels,
        channelCount,
        title,
        external,
        externalFilename,
        forced,
        default: isDefault,
        hearingImpaired,
        url: external && externalFilename ? addonUrlFor(externalFilename) : undefined,
      };
      if (role === "second") info.secondarySelected = true;
      if (type === "audio") audio.push(info);
      else if (type === "sub") subs.push(info);
    }
    const secondaryId = subs.find((t) => t.secondarySelected)?.id ?? null;
    if (secondaryId !== snap.secondarySubTrackId) {
      snap.secondarySubTrackId = secondaryId;
      // mpv sends no last "empty" line when the second subtitle goes away.
      if (secondaryId == null) snap.secondarySubText = "";
    }
    if (selectionOnly && roleSignature(subs) === roleSignature(snap.subtitleTracks)) return;
    snap.audioTracks = audio;
    snap.subtitleTracks = subs;
  };

  const firstSubId = (): string | null => snap.subtitleTracks.find((t) => t.selected)?.id ?? null;

  // Drops the second subtitle on the page's side right away; mpv's next track-list agrees.
  const clearSecondaryLocal = () => {
    snap.secondarySubTrackId = null;
    snap.secondarySubText = "";
  };

  const setSecondaryTrack = (id: string | null) => {
    // The first subtitle's track can't also be the second one.
    if (id != null && id === firstSubId()) return;
    if (id == null) clearSecondaryLocal();
    else snap.secondarySubText = "";
    invoke("mpv_set_property", {
      name: "secondary-sid",
      value: id == null ? "no" : Number(id) || id,
    }).catch(() => {});
    emit();
  };

  const handleEvent = (raw: MpvEvent) => {
    if (raw.event === "property-change") {
      const name = raw.name;
      const data = raw.data;
      if (name === "time-pos" && typeof data === "number") snap.positionSec = data;
      if (name === "duration" && typeof data === "number") snap.durationSec = data;
      if (name === "pause" && typeof data === "boolean") {
        snap.status = data ? "paused" : "playing";
      }
      if (name === "eof-reached" && data === true) snap.status = "ended";
      if (name === "volume" && typeof data === "number") snap.volume = data / 100;
      if (name === "mute" && typeof data === "boolean") snap.muted = data;
      if (name === "track-list" && Array.isArray(data)) {
        const list = data as Array<Record<string, unknown>>;
        pendingTracks["track-list"] = list;
        buildTracks(list);
      }
      if (name === "sid" || name === "secondary-sid") {
        // A track number, "no" for none, or "auto" before a file has picked its tracks.
        const id =
          typeof data === "string" && /^\d+$/.test(data)
            ? data
            : data === "no" || data === false
              ? null
              : undefined;
        if (name === "sid") mpvSid = id;
        else mpvSecondarySid = id;
        // Only needed to tell the two subtitles apart when track-list has no main-selection.
        const list = pendingTracks["track-list"] as Array<Record<string, unknown>> | undefined;
        if (list && !trackListHasMainSelection(list)) buildTracks(list, true);
      }
      if (name === "sub-delay" && typeof data === "number") snap.subDelaySec = data;
      if (name === "audio-delay" && typeof data === "number") snap.audioDelaySec = data;
      if (name === "sub-text") snap.subText = typeof data === "string" ? data : "";
      if (name === "secondary-sub-text") snap.secondarySubText = typeof data === "string" ? data : "";
      if (name === "secondary-sub-delay" && typeof data === "number") snap.secondarySubDelaySec = data;
      if (name === "sub-start" && typeof data === "number") snap.subStartSec = data;
      if (name === "dwidth" && typeof data === "number") snap.videoWidth = data;
      if (name === "dheight" && typeof data === "number") snap.videoHeight = data;
      if (name === "video-params/gamma") snap.hdrGamma = typeof data === "string" ? data : "";
      if (name === "af") {
        const repr = typeof data === "string" ? data : JSON.stringify(data ?? "");
        snap.audioNormalize = repr.includes("dynaudnorm");
      }
      if (name === "chapter-list" && Array.isArray(data)) {
        const list = data as Array<Record<string, unknown>>;
        snap.chapters = list
          .map((c) => ({
            title: typeof c.title === "string" ? c.title : "",
            startSec: typeof c.time === "number" ? c.time : 0,
          }))
          .filter((c) => Number.isFinite(c.startSec) && c.startSec >= 0)
          .sort((a, b) => a.startSec - b.startSec);
      }
      emit();
    } else if (raw.event === "end-file") {
      const reason = (raw as { reason?: string }).reason?.toLowerCase();
      if (reason === "stop" || reason === "quit" || reason === "redirect") return;
      if (Date.now() < suppressEndFileUntil) return;
      if (reason && reason !== "eof") {
        snap.status = "error";
        snap.errorCode = "decode";
        snap.errorMessage = `mpv ended playback: ${reason}`;
      } else {
        snap.status = "ended";
      }
      emit();
    } else if (raw.event === "file-loaded") {
      snap.status = "playing";
      snap.errorCode = null;
      snap.errorMessage = null;
      emit();
    }
  };

  return {
    attach(h) {
      host = h;
      const embed = mpvOptions?.embed === true;
      const placeholder = document.createElement("div");
      placeholder.style.width = "100%";
      placeholder.style.height = "100%";
      if (embed) {
        placeholder.style.background = "transparent";
      } else {
        placeholder.style.background = "black";
        placeholder.style.display = "flex";
        placeholder.style.alignItems = "center";
        placeholder.style.justifyContent = "center";
        placeholder.style.color = "rgba(255,255,255,0.45)";
        placeholder.style.fontFamily = "Inter, system-ui, sans-serif";
        placeholder.style.fontSize = "13px";
        placeholder.textContent = "mpv plays in its own window. Controls remain here.";
      }
      h.appendChild(placeholder);
    },
    detach() {
      if (host) {
        while (host.firstChild) host.removeChild(host.firstChild);
      }
      host = null;
    },
    async load(src: PlayerSource) {
      snap.status = "loading";
      snap.errorCode = null;
      snap.errorMessage = null;
      snap.audioTracks = [];
      snap.subtitleTracks = [];
      snap.subText = "";
      snap.subStartSec = 0;
      snap.secondarySubText = "";
      snap.secondarySubTrackId = null;
      snap.secondarySubDelaySec = 0;
      snap.positionSec = 0;
      snap.durationSec = 0;
      snap.bufferedSec = 0;
      snap.hdrGamma = "";
      pendingTracks = {};
      urlByExternalFilename.clear();
      emit();
      if (!unlistenEvent) {
        unlistenEvent = await listen<MpvEvent>("mpv://event", (ev) => handleEvent(ev.payload));
      }
      if (!unlistenLog) {
        unlistenLog = await listen<string>("mpv://log", () => {});
      }
      try {
        const opts = mpvOptions ?? { anime4k: false, hdrToSdr: true };
        if (mpvStarted) {
          try {
            suppressEndFileUntil = Date.now() + 1500;
            await invoke("mpv_command", { cmd: ["stop"] });
            // A second subtitle belongs to the file it was picked for. mpv keeps secondary-sid
            // as an option and would pick the same track number in the next file, so it is
            // cleared here; the player puts the remembered one back once the tracks are known.
            await invoke("mpv_set_property", { name: "secondary-sid", value: "no" }).catch(() => {});
            await invoke("mpv_set_property", { name: "secondary-sub-delay", value: 0 }).catch(() => {});
            await applyHeaderProps(src.headers);
            const cmd: Array<string | number> = ["loadfile", src.url];
            if (typeof src.startAtSec === "number" && src.startAtSec > 0) {
              cmd.push("replace", 0, `start=${src.startAtSec}`);
            }
            await invoke("mpv_command", { cmd });
            for (const s of src.subtitles ?? []) {
              try {
                let url = s.url;
                if (/^https?:/i.test(url)) {
                  try {
                    url = await invoke<string>("sub_download", { url: s.url });
                  } catch {
                    /* fall back to remote URL */
                  }
                }
                // Remembered by the address it came from (to put the same one back later).
                if (url !== s.url) urlByExternalFilename.set(url, s.url);
                await invoke("mpv_sub_add", {
                  url,
                  lang: s.lang ?? null,
                  title: null,
                  select: false,
                });
              } catch {
                /* noop */
              }
            }
            window.dispatchEvent(new Event("harbor:mpv-refresh-geom"));
            return;
          } catch (err) {
            console.warn("[mpv] loadfile reload failed, falling back to recreate", err);
            mpvStarted = false;
          }
        }
        await invoke("mpv_start", {
          args: {
            url: src.url,
            startAtSec: src.startAtSec ?? null,
            subtitles: (src.subtitles ?? []).map((s) => ({ url: s.url, lang: s.lang ?? null })),
            anime4k: opts.anime4k,
            hdrToSdr: opts.hdrToSdr,
            embed: opts.embed === true,
            anime4kShaders: opts.anime4kShaders ?? [],
            d3d11Flip: opts.d3d11Flip === true,
            isLive: src.isLive === true,
            headers: src.headers ?? null,
            extraOptions: opts.extraOptions || undefined,
          },
        });
        mpvStarted = true;
        if (opts.embed) {
          await invoke("mpv_set_property", { name: "sub-visibility", value: false }).catch(() => {});
        }
        if (opts.embed && opts.getEmbedRect && geomTimer == null) {
          let lastRect: MpvRect | null = null;
          const tick = async () => {
            try {
              const r = await opts.getEmbedRect!();
              if (!r) return;
              if (
                lastRect &&
                lastRect.cssLeft === r.cssLeft &&
                lastRect.cssTop === r.cssTop &&
                lastRect.cssWidth === r.cssWidth &&
                lastRect.cssHeight === r.cssHeight &&
                lastRect.cssViewW === r.cssViewW &&
                lastRect.cssViewH === r.cssViewH
              ) {
                return;
              }
              lastRect = r;
              await invoke("mpv_set_geometry", { geom: r });
            } catch {}
          };
          tick();
          geomTimer = window.setInterval(() => {
            void tick();
          }, 250);
          geomKickHandler = () => {
            void tick();
            window.setTimeout(() => void tick(), 60);
            window.setTimeout(() => void tick(), 200);
            window.setTimeout(() => void tick(), 500);
            window.setTimeout(() => void tick(), 1000);
            window.setTimeout(() => void tick(), 1800);
          };
          geomForceHandler = () => {
            lastRect = null;
            geomKickHandler?.();
          };
          window.addEventListener("resize", geomKickHandler);
          window.addEventListener("harbor:mpv-refresh-geom", geomKickHandler);
          window.addEventListener("harbor:mpv-force-geom", geomForceHandler);
          if (host && typeof ResizeObserver !== "undefined") {
            try {
              geomResizeObserver = new ResizeObserver(() => void tick());
              geomResizeObserver.observe(host);
            } catch {
              /* noop */
            }
          }
          try {
            const { getCurrentWindow } = await import("@tauri-apps/api/window");
            const win = getCurrentWindow();
            const unResized = await win.onResized(() => geomKickHandler?.());
            const unMoved = await win.onMoved(() => geomKickHandler?.());
            geomTauriUnlisten.push(unResized, unMoved);
          } catch {
            /* noop */
          }
        }
      } catch (e) {
        snap.status = "error";
        snap.errorCode = "source";
        snap.errorMessage = e instanceof Error ? e.message : String(e);
        emit();
      }
    },
    async play() {
      await invoke("mpv_set_property", { name: "pause", value: false }).catch(() => {});
    },
    pause() {
      invoke("mpv_set_property", { name: "pause", value: true }).catch(() => {});
    },
    seek(sec) {
      snap.subText = "";
      snap.subStartSec = 0;
      snap.secondarySubText = "";
      emit();
      invoke("mpv_command", { cmd: ["seek", sec, "absolute", "exact"] }).catch(() => {});
    },
    frameStep(dir) {
      invoke("mpv_command", { cmd: [dir > 0 ? "frame-step" : "frame-back-step"] }).catch(() => {});
    },
    setVolume(v) {
      invoke("mpv_set_property", { name: "volume", value: Math.round(v * 100) }).catch(() => {});
    },
    setMuted(m) {
      invoke("mpv_set_property", { name: "mute", value: m }).catch(() => {});
    },
    setRate(r) {
      invoke("mpv_set_property", { name: "speed", value: r }).catch(() => {});
    },
    setAudioTrack(id) {
      invoke("mpv_set_property", { name: "aid", value: Number(id) || id }).catch(() => {});
    },
    setSubtitleTrack(id) {
      if (id == null) {
        // The second subtitle only shows with a first one: turning the first off ends it too.
        if (snap.secondarySubTrackId != null) {
          clearSecondaryLocal();
          invoke("mpv_set_property", { name: "secondary-sid", value: "no" }).catch(() => {});
        }
        invoke("mpv_set_property", { name: "sid", value: "no" }).catch(() => {});
        snap.subText = "";
        snap.subStartSec = 0;
        emit();
      } else {
        const value = Number(id) || id;
        if (snap.secondarySubTrackId === id) {
          // mpv won't make a track the first while it is the second, so the second lets go first.
          clearSecondaryLocal();
          invoke("mpv_set_property", { name: "secondary-sid", value: "no" })
            .catch(() => {})
            .then(() => invoke("mpv_set_property", { name: "sid", value }))
            .catch(() => {});
        } else {
          invoke("mpv_set_property", { name: "sid", value }).catch(() => {});
        }
        snap.subText = "";
        snap.subStartSec = 0;
        emit();
      }
    },
    setSecondarySubtitleTrack(id) {
      setSecondaryTrack(id);
    },
    setSecondarySubDelay(sec) {
      invoke("mpv_set_property", { name: "secondary-sub-delay", value: sec }).catch(() => {});
    },
    setSecondarySubVisible(on) {
      invoke("mpv_set_property", { name: "secondary-sub-visibility", value: on }).catch(() => {});
    },
    setSubVisible(on) {
      invoke("mpv_set_property", { name: "sub-visibility", value: on }).catch(() => {});
    },
    setSubDelay(sec) {
      invoke("mpv_set_property", { name: "sub-delay", value: sec }).catch(() => {});
    },
    setAudioDelay(sec) {
      invoke("mpv_set_property", { name: "audio-delay", value: sec }).catch(() => {});
    },
    setPanscan(value) {
      const v = Math.max(0, Math.min(1, value));
      invoke("mpv_set_property", { name: "panscan", value: v }).catch(() => {});
    },
    setVideoZoom(log2) {
      invoke("mpv_set_property", { name: "video-zoom", value: log2 }).catch(() => {});
    },
    setAspectOverride(ratio) {
      invoke("mpv_set_property", { name: "video-aspect-override", value: ratio }).catch(() => {});
    },
    setAnime4kShaders(shaders) {
      const sep = typeof navigator !== "undefined" && navigator.userAgent.toLowerCase().includes("windows") ? ";" : ":";
      invoke("mpv_set_property", { name: "glsl-shaders", value: shaders.filter(Boolean).join(sep) }).catch(() => {});
    },
    async addSubtitle(url, lang, title, select): Promise<boolean> {
      let mpvUrl = url;
      if (/^https?:/i.test(url)) {
        try {
          mpvUrl = await invoke<string>("sub_download", { url });
        } catch (e) {
          console.warn("[mpv] sub_download failed, falling back to URL", e);
        }
      }
      urlByExternalFilename.set(mpvUrl, url);
      try {
        await invoke("mpv_sub_add", {
          url: mpvUrl,
          lang: lang ?? null,
          title: title ?? null,
          select: select ?? true,
        });
        return true;
      } catch (e) {
        console.warn("[mpv] sub-add failed", e);
        return false;
      }
    },
    async addSecondarySubtitle(url, lang, title): Promise<boolean> {
      // Already in the list (an addon subtitle the player loaded by itself): use that track.
      const existing = snap.subtitleTracks.find((t) => t.url === url && !t.selected);
      if (existing) {
        if (!existing.secondarySelected) setSecondaryTrack(existing.id);
        return true;
      }
      let mpvUrl = url;
      if (/^https?:/i.test(url)) {
        try {
          mpvUrl = await invoke<string>("sub_download", { url });
        } catch (e) {
          console.warn("[mpv] sub_download failed, falling back to URL", e);
        }
      }
      urlByExternalFilename.set(mpvUrl, url);
      try {
        await invoke("mpv_sub_add", {
          url: mpvUrl,
          lang: lang ?? null,
          title: title ?? null,
          select: false,
          secondary: true,
        });
        return true;
      } catch (e) {
        console.warn("[mpv] adding the second subtitle failed", e);
        return false;
      }
    },
    getSelectedTrackCues() {
      return null;
    },
    getSelectedTrackUrl() {
      const sel = snap.subtitleTracks.find((t) => t.selected);
      if (!sel || !sel.external) return null;
      return sel.url ?? sel.externalFilename ?? null;
    },
    setAudioNormalize(on) {
      snap.audioNormalize = on;
      applyAudioFilters();
      emit();
    },
    setAudioProfile(profile) {
      profileAf = AUDIO_PROFILE_AF[profile] ?? "";
      applyAudioFilters();
    },
    setMediaInfo(info) {
      invoke("mpv_set_property", { name: "force-media-title", value: info.title }).catch(() => {});
    },
    async screenshot(path) {
      try {
        const out = await invoke<string>("mpv_save_screenshot", { path });
        return { ok: true, path: out };
      } catch (e) {
        return { ok: false, error: e instanceof Error ? e.message : String(e) };
      }
    },
    setAbLoop(a, b) {
      invoke("mpv_set_property", { name: "ab-loop-a", value: a == null ? "no" : a }).catch(() => {});
      invoke("mpv_set_property", { name: "ab-loop-b", value: b == null ? "no" : b }).catch(() => {});
    },
    async requestPiP() {},
    async exitPiP() {},
    async requestFullscreen() {
      await invoke("mpv_set_property", { name: "fullscreen", value: true }).catch(() => {});
    },
    async exitFullscreen() {
      await invoke("mpv_set_property", { name: "fullscreen", value: false }).catch(() => {});
    },
    capabilities(): PlayerCapabilities {
      return {
        engine: "mpv",
        pictureInPicture: true,
        airplay: false,
        chromecast: true,
        hdrPassthrough: false,
        hardwareDecode: true,
      };
    },
    subscribe(l) {
      listeners.add(l);
      l(snap);
      return () => {
        listeners.delete(l);
      };
    },
    destroy() {
      if (geomTimer != null) {
        window.clearInterval(geomTimer);
        geomTimer = null;
      }
      if (geomKickHandler) {
        window.removeEventListener("resize", geomKickHandler);
        window.removeEventListener("harbor:mpv-refresh-geom", geomKickHandler);
        geomKickHandler = null;
      }
      if (geomForceHandler) {
        window.removeEventListener("harbor:mpv-force-geom", geomForceHandler);
        geomForceHandler = null;
      }
      if (geomResizeObserver) {
        try {
          geomResizeObserver.disconnect();
        } catch {
          /* noop */
        }
        geomResizeObserver = null;
      }
      for (const u of geomTauriUnlisten) {
        try {
          u();
        } catch {
          /* noop */
        }
      }
      geomTauriUnlisten = [];
      mpvStarted = false;
      invoke("mpv_stop").catch(() => {});
      if (unlistenEvent) {
        unlistenEvent();
        unlistenEvent = null;
      }
      if (unlistenLog) {
        unlistenLog();
        unlistenLog = null;
      }
      if (host) {
        while (host.firstChild) host.removeChild(host.firstChild);
      }
      host = null;
      listeners.clear();
    },
  };
}
