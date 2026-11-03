// Bridge to the native Android shell (android/ in this repo). The shell injects
// `window.HarborAndroid` before the page loads; everywhere else this module is inert.

type HarborAndroidApi = {
  version(): string;
  fetch(id: string, requestJson: string): void;
  play(sourceJson: string): void;
  command(json: string): void;
  stop(): void;
  openExternal(url: string): void;
  // Downloads (android/…/Downloads.kt). Absent on shells older than the downloads release.
  dlStart?(json: string): string;
  dlStatus?(): string;
  dlDelete?(id: string): boolean;
  dlPause?(id: string): boolean;
  /** Resume a paused download, or retry a failed one from where it got to. */
  dlResume?(id: string): boolean;
  dlAddSubs?(id: string, json: string): boolean;
  dlFiles?(id: string): string;
  dlStorage?(): string;
  /** Background work in the page (season queue, subtitle searches): keep the app running. */
  dlKeepAlive?(on: boolean): void;
  /** Whether Harbor may run in the background without battery limits, and the system prompt for it. */
  bgAllowed?(): boolean;
  bgRequest?(): void;
};

export type NativePlayerEvent =
  | {
      type: "state";
      positionMs: number;
      durationMs: number;
      bufferedMs: number;
      playing: boolean;
      playWhenReady: boolean;
      buffering: boolean;
      ended: boolean;
      ready: boolean;
      rate: number;
      width: number;
      height: number;
    }
  | { type: "ended" }
  | { type: "error"; code: string; message: string }
  | { type: "closed"; positionMs: number; durationMs: number }
  | { type: "requestStreams" }
  | { type: "pickStream"; key: string }
  | { type: "next" }
  | { type: "subSearch" };

type NativeFetchResult =
  | { ok: true; status: number; url: string; headers: Record<string, string>; body: string }
  | { ok: false; error: string };

declare global {
  interface Window {
    HarborAndroid?: HarborAndroidApi;
    __harborNativeFetchDone?: (id: string, json: string) => void;
    __harborNativeEvent?: (json: string) => void;
    __harborAndroidBack?: () => boolean;
  }
}

export const NATIVE_PLAYER_CLOSED_EVENT = "harbor:native-player-closed";

export function androidApi(): HarborAndroidApi | null {
  if (typeof window === "undefined") return null;
  return window.HarborAndroid ?? null;
}

export function isAndroidApp(): boolean {
  return androidApi() != null;
}

// ---- native fetch -------------------------------------------------------------------

const pendingFetches = new Map<string, { resolve: (r: Response) => void; reject: (e: unknown) => void }>();
let fetchSeq = 0;

function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

if (typeof window !== "undefined") {
  window.__harborNativeFetchDone = (id, json) => {
    const p = pendingFetches.get(id);
    if (!p) return;
    pendingFetches.delete(id);
    let r: NativeFetchResult;
    try {
      r = JSON.parse(json) as NativeFetchResult;
    } catch (e) {
      p.reject(e);
      return;
    }
    if (!r.ok) {
      p.reject(new TypeError(`Network request failed: ${r.error}`));
      return;
    }
    const nullBody = r.status === 204 || r.status === 205 || r.status === 304;
    const resp = new Response(nullBody ? null : base64ToBytes(r.body), { status: r.status, headers: r.headers });
    try {
      Object.defineProperty(resp, "url", { value: r.url });
    } catch {
      /* read-only on some engines */
    }
    p.resolve(resp);
  };
}

/** Text/JSON request bodies only (same as the desktop harbor_fetch path). */
export function canNativeFetch(init?: RequestInit): boolean {
  const b = init?.body;
  return b == null || typeof b === "string" || b instanceof URLSearchParams;
}

export function androidFetch(url: string, init?: RequestInit): Promise<Response> {
  const api = androidApi();
  if (!api) return fetch(url, init);
  const headers: Record<string, string> = {};
  if (init?.headers) new Headers(init.headers as HeadersInit).forEach((v, k) => (headers[k] = v));
  const body = init?.body == null ? null : String(init.body);
  if (init?.body instanceof URLSearchParams && !headers["content-type"]) {
    headers["content-type"] = "application/x-www-form-urlencoded;charset=UTF-8";
  }
  const id = `f${++fetchSeq}`;
  return new Promise<Response>((resolve, reject) => {
    const signal = init?.signal;
    if (signal?.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    pendingFetches.set(id, { resolve, reject });
    signal?.addEventListener("abort", () => {
      if (pendingFetches.delete(id)) reject(new DOMException("Aborted", "AbortError"));
    });
    api.fetch(id, JSON.stringify({ url, method: init?.method ?? "GET", headers, body, timeoutMs: 30000 }));
  });
}

// ---- native player events -----------------------------------------------------------

const playerListeners = new Set<(e: NativePlayerEvent) => void>();

if (typeof window !== "undefined") {
  window.__harborNativeEvent = (json) => {
    let e: NativePlayerEvent;
    try {
      e = JSON.parse(json) as NativePlayerEvent;
    } catch {
      return;
    }
    playerListeners.forEach((l) => l(e));
    if (e.type === "closed") window.dispatchEvent(new CustomEvent(NATIVE_PLAYER_CLOSED_EVENT, { detail: e }));
  };
}

export function onNativePlayerEvent(cb: (e: NativePlayerEvent) => void): () => void {
  playerListeners.add(cb);
  return () => playerListeners.delete(cb);
}

// ---- back button interceptors --------------------------------------------------------

const backInterceptors: Array<() => boolean> = [];

/** Lets a screen handle the Android back gesture first (e.g. Settings: section -> list).
 *  The handler returns true when it consumed the back press. */
export function pushAndroidBackHandler(fn: () => boolean): () => void {
  backInterceptors.push(fn);
  return () => {
    const i = backInterceptors.lastIndexOf(fn);
    if (i >= 0) backInterceptors.splice(i, 1);
  };
}

export function runAndroidBackHandlers(): boolean {
  for (let i = backInterceptors.length - 1; i >= 0; i--) {
    if (backInterceptors[i]()) return true;
  }
  return false;
}
