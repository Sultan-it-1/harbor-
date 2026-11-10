// The iPhone app's services (ios/native/App/App/HarborSystemPlugin.swift): downloads, stremio://
// links, saved pictures, saving a file, opening a link outside the app.
//
// The page calls Android's shell synchronously (androidApi().dlStatus() returns the answer), but
// iOS plugins answer later. So the app keeps a copy of its state in the page
// (window.__harborIosState) and these calls answer from that copy, sending the change to the app
// and updating the copy at once. Same names and answers as Android's (see HarborAndroidApi).
import { isIOSApp } from "@/lib/platform";

type CapacitorGlobal = { nativePromise?: (plugin: string, method: string, options?: object) => Promise<unknown> };

type IosState = {
  downloads?: Record<string, Record<string, unknown>>;
  files?: Record<string, unknown>;
  storage?: { free?: number; used?: number };
  wifiOnly?: boolean;
  imageCache?: { used: number; limit: number; free: number };
  link?: string;
};

declare global {
  interface Window {
    __harborIosState?: (json: string) => void;
  }
}

/** The calls the page makes on Android's shell that the iPhone app answers too. */
export type IosSystemApi = {
  dlStart(json: string): string;
  dlStatus(): string;
  dlDelete(id: string): boolean;
  dlPause(id: string): boolean;
  dlResume(id: string): boolean;
  dlAddSubs(id: string, json: string): boolean;
  dlFiles(id: string): string;
  dlStorage(): string;
  dlRelink(id: string, url: string, headersJson: string): boolean;
  dlSetWifiOnly(on: boolean): void;
  dlWifiOnly(): boolean;
  dlKeepAlive(on: boolean): void;
  bgAllowed(): boolean;
  bgRequest(): void;
  takeLink(): string;
  setSecure(on: boolean): void;
  saveFile(id: string, name: string, mime: string, base64: string): boolean;
  imageCache(): string;
  imageCacheClear(): string;
  openExternal(url: string): void;
};

let state: IosState = {};
let api: IosSystemApi | null = null;
/** Ids deleted here that the app may still list for a moment. */
const deleted = new Set<string>();

function cap(): CapacitorGlobal | null {
  if (typeof window === "undefined" || !isIOSApp()) return null;
  const c = (window as unknown as { Capacitor?: CapacitorGlobal }).Capacitor;
  return c?.nativePromise ? c : null;
}

function take(json: string): void {
  try {
    const next = JSON.parse(json) as IosState;
    for (const id of [...deleted]) {
      if (!next.downloads?.[id]) deleted.delete(id);
      else delete next.downloads[id];
    }
    state = next;
  } catch {
    /* a bad push: keep the last state */
  }
}

/** The iPhone app's services, or null elsewhere. */
export function iosSystemApi(): IosSystemApi | null {
  if (api) return api;
  const c = cap();
  if (!c) return null;
  const call = (method: string, options: object = {}): Promise<unknown> =>
    c.nativePromise!("HarborSystem", method, options).catch((e) => {
      console.warn("[ios system]", method, e);
      return null;
    });
  window.__harborIosState = take;
  void call("state").then((r) => {
    const json = (r as { json?: string } | null)?.json;
    if (json) take(json);
  });
  const downloads = () => (state.downloads ??= {});
  api = {
    dlStart(json) {
      try {
        const id = (JSON.parse(json) as { id?: string }).id;
        if (id) {
          deleted.delete(id);
          downloads()[id] = { status: "pending", received: 0, total: null, code: "queued", reason: "Queued", subs: 0 };
        }
      } catch {
        return JSON.stringify({ ok: false, error: "bad request" });
      }
      void call("dlStart", { json });
      return JSON.stringify({ ok: true });
    },
    dlStatus: () => JSON.stringify(state.downloads ?? {}),
    dlDelete(id) {
      deleted.add(id);
      delete downloads()[id];
      delete (state.files ?? {})[id];
      void call("dlDelete", { id });
      return true;
    },
    dlPause(id) {
      const d = downloads()[id];
      if (!d || d.status === "done" || d.status === "error" || d.status === "paused") return false;
      downloads()[id] = { ...d, status: "paused", code: "paused", reason: "Paused" };
      void call("dlPause", { id });
      return true;
    },
    dlResume(id) {
      const d = downloads()[id];
      if (!d || d.status === "done" || d.status === "downloading") return false;
      downloads()[id] = { ...d, status: "pending", code: "queued", reason: "Queued" };
      void call("dlResume", { id });
      return true;
    },
    dlAddSubs(id, json) {
      if (!downloads()[id]) return false;
      void call("dlAddSubs", { id, json });
      return true;
    },
    dlFiles: (id) => JSON.stringify((state.files ?? {})[id] ?? { subtitles: [] }),
    dlStorage: () => JSON.stringify(state.storage ?? {}),
    dlRelink(id, url, headersJson) {
      const d = downloads()[id];
      if (!d || d.status === "done" || d.status === "downloading" || !/^https?:\/\//.test(url)) return false;
      downloads()[id] = { ...d, status: "pending", code: "queued", reason: "Queued", http: 0 };
      void call("dlRelink", { id, url, headers: headersJson });
      return true;
    },
    dlSetWifiOnly(on) {
      state.wifiOnly = on;
      void call("dlSetWifiOnly", { on });
    },
    dlWifiOnly: () => state.wifiOnly ?? true,
    dlKeepAlive(on) {
      void call("dlKeepAlive", { on });
    },
    // iOS has no battery limit to lift for the app: its downloads go on in the background anyway.
    bgAllowed: () => true,
    bgRequest() {},
    takeLink() {
      const link = state.link ?? "";
      if (link) {
        state.link = undefined;
        void call("linkTaken");
      }
      return link;
    },
    setSecure(on) {
      void call("setSecure", { on });
    },
    saveFile(id, name, mime, base64) {
      void call("saveFile", { id, name, mime, base64 });
      return true;
    },
    imageCache: () => JSON.stringify(state.imageCache ?? { used: 0, limit: 0, free: -1 }),
    imageCacheClear() {
      const now = { used: 0, limit: state.imageCache?.limit ?? 0, free: state.imageCache?.free ?? -1 };
      state.imageCache = now;
      void call("imageCacheClear");
      return JSON.stringify(now);
    },
    openExternal(url) {
      void call("openExternal", { url });
    },
  };
  return api;
}
