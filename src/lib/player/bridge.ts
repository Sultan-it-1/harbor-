import type { SubCue } from "@/lib/subtitles/parser";

export type TrackInfo = {
  id: string;
  label: string;
  lang?: string;
  kind: "audio" | "subtitle";
  selected: boolean;
  codec?: string;
  channels?: string;
  channelCount?: number;
  title?: string;
  external?: boolean;
  externalFilename?: string;
  forced?: boolean;
  default?: boolean;
  hearingImpaired?: boolean;
  url?: string;
  /** This subtitle track is the second subtitle (shown with the first). `selected` stays
   *  false for it, so lists of the first subtitle never show it as picked. */
  secondarySelected?: boolean;
};

export type Chapter = {
  title: string;
  startSec: number;
};

export type PlayerStatus = "idle" | "loading" | "ready" | "playing" | "paused" | "ended" | "error";

export type PlayerSnapshot = {
  status: PlayerStatus;
  positionSec: number;
  durationSec: number;
  bufferedSec: number;
  buffering: boolean;
  volume: number;
  muted: boolean;
  rate: number;
  audioTracks: TrackInfo[];
  subtitleTracks: TrackInfo[];
  chapters: Chapter[];
  subDelaySec: number;
  audioDelaySec: number;
  subText: string;
  subStartSec: number;
  /** The second subtitle: its current line, its track id (null when there is none) and its
   *  own delay. Only the desktop player (mpv) has one. */
  secondarySubText: string;
  secondarySubTrackId: string | null;
  secondarySubDelaySec: number;
  audioNormalize: boolean;
  videoWidth: number;
  videoHeight: number;
  hdrGamma: string;
  errorMessage: string | null;
  errorCode: "decode" | "codec" | "network" | "source" | "unknown" | null;
  noAudio?: boolean;
};

export type PlayerSource = {
  url: string;
  subtitles?: { id?: string; url: string; lang?: string; m?: string; label?: string }[];
  notWebReady?: boolean;
  startAtSec?: number;
  isLive?: boolean;
  headers?: Record<string, string>;
  /** Identity of the title/episode; lets the Android player keep subtitles across stream swaps. */
  contentKey?: string;
  /** Android: the download of this title/episode, whose saved subtitles the player lists
   *  (and where its "save subtitle" button stores new ones). */
  downloadId?: string;
};

export type PlayerBridge = {
  attach: (host: HTMLElement) => void;
  detach: () => void;
  load: (src: PlayerSource) => Promise<void>;
  play: () => Promise<void>;
  pause: () => void;
  seek: (sec: number) => void;
  frameStep?: (dir: 1 | -1) => void;
  setVolume: (v: number) => void;
  setMuted: (m: boolean) => void;
  setRate: (r: number) => void;
  setAudioTrack: (id: string) => void;
  setSubtitleTrack: (id: string | null) => void;
  setSubVisible: (on: boolean) => void;
  setSubDelay: (sec: number) => void;
  /** The second subtitle: a track to show together with the first one, or null for none.
   *  The first subtitle's track can't also be the second. */
  setSecondarySubtitleTrack: (id: string | null) => void;
  setSecondarySubDelay: (sec: number) => void;
  /** Whether the player itself draws the second subtitle (only when the page can't). */
  setSecondarySubVisible?: (on: boolean) => void;
  setAudioDelay: (sec: number) => void;
  setPanscan: (value: number) => void;
  setVideoZoom: (log2: number) => void;
  setAspectOverride: (ratio: string) => void;
  setAnime4kShaders: (shaders: string[]) => void;
  addSubtitle: (url: string, lang?: string, title?: string, select?: boolean) => Promise<boolean>;
  /** Adds a subtitle file and shows it as the second subtitle (the first one stays). */
  addSecondarySubtitle: (url: string, lang?: string, title?: string) => Promise<boolean>;
  getSelectedTrackCues: () => SubCue[] | null;
  getSelectedTrackUrl: () => string | null;
  setAudioNormalize: (on: boolean) => void;
  setAudioProfile?: (profile: string) => void;
  setMediaInfo?: (info: { title: string; artist?: string; artwork?: string }) => void;
  screenshot: (path: string) => Promise<{ ok: boolean; path?: string; error?: string }>;
  setAbLoop: (a: number | null, b: number | null) => void;
  requestPiP: () => Promise<void>;
  exitPiP: () => Promise<void>;
  requestFullscreen: () => Promise<void>;
  exitFullscreen: () => Promise<void>;
  capabilities: () => PlayerCapabilities;
  subscribe: (listener: (snap: PlayerSnapshot) => void) => () => void;
  destroy: () => void;
};

export type PlayerCapabilities = {
  engine: "html5" | "mpv";
  pictureInPicture: boolean;
  airplay: boolean;
  chromecast: boolean;
  hdrPassthrough: boolean;
  hardwareDecode: boolean;
};

export const emptySnapshot: PlayerSnapshot = {
  status: "idle",
  positionSec: 0,
  durationSec: 0,
  bufferedSec: 0,
  buffering: false,
  volume: 1,
  muted: false,
  rate: 1,
  audioTracks: [],
  subtitleTracks: [],
  chapters: [],
  subDelaySec: 0,
  audioDelaySec: 0,
  subText: "",
  subStartSec: 0,
  secondarySubText: "",
  secondarySubTrackId: null,
  secondarySubDelaySec: 0,
  audioNormalize: false,
  videoWidth: 0,
  videoHeight: 0,
  hdrGamma: "",
  errorMessage: null,
  errorCode: null,
};
