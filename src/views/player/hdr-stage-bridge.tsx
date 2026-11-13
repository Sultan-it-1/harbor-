import { useEffect, useRef } from "react";
import { hdrOverlayEmitProps } from "@/lib/hdr-overlay";
import type { SecondSubControls } from "@/lib/player/second-sub-context";
import type { ExternalPlayer } from "@/lib/external-player";
import type { HdrStagePayload } from "../hdr-overlay-app";
import type { SubChoice } from "./hooks/use-playback-controls";

export type HdrStageHandlers = {
  playPause: () => void;
  fullscreen: () => void;
  seek: (sec: number) => void;
  seekStep: (delta: number) => void;
  rememberSub: (t: SubChoice) => void;
  /** The second subtitle, changed from the HDR window's menu (null: none possible). */
  sub2: SecondSubControls | null;
  pip: () => void;
  cast: () => void;
  back: () => void;
  prevEp: () => void;
  nextEp: () => void;
  pickAnother: () => void;
  screenshot: () => void;
  menuOpen: (open: boolean) => void;
  activity: () => void;
  /** The mouse button is held on the video in the HDR window (true) or let go (false). */
  holdSpeed: (on: boolean) => void;
  openExternal: (player: ExternalPlayer) => void;
};

export function HdrStageBridge({
  active,
  payload,
  handlers,
}: {
  active: boolean;
  payload: HdrStagePayload;
  handlers: HdrStageHandlers;
}) {
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;
  const payloadRef = useRef(payload);
  payloadRef.current = payload;

  useEffect(() => {
    if (!active) return;
    void hdrOverlayEmitProps(payload);
  }, [active, payload]);

  useEffect(() => {
    if (!active) return;
    const id = window.setInterval(() => void hdrOverlayEmitProps(payloadRef.current), 1000);
    return () => window.clearInterval(id);
  }, [active]);

  useEffect(() => {
    if (!active) return;
    const isTauri = "__TAURI__" in window || "__TAURI_INTERNALS__" in window;
    if (!isTauri) return;
    let cancelled = false;
    let holding = false;
    const offs: Array<() => void> = [];
    void (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      const bind = async (event: string, fn: (p: unknown) => void) => {
        const off = await listen(event, (e) => fn(e.payload));
        if (cancelled) off();
        else offs.push(off);
      };
      const h = () => handlersRef.current;
      await bind("hdr-stage://play-pause", () => h().playPause());
      await bind("hdr-stage://fullscreen", () => h().fullscreen());
      await bind("hdr-stage://seek", (p) => h().seek((p as { sec: number }).sec));
      await bind("hdr-stage://seek-step", (p) => h().seekStep((p as { delta: number }).delta));
      await bind("hdr-stage://remember-sub", (p) => {
        const { off, lang, ...track } = p as { off?: boolean; lang?: string | null } & NonNullable<SubChoice>;
        if (off === true) h().rememberSub(null);
        // A message with only a language (no "off" field): what the HDR window used to send.
        else if (off === undefined) h().rememberSub(lang ? { lang } : null);
        else h().rememberSub({ ...track, lang: lang ?? undefined });
      });
      // The second subtitle is changed here, in the main window, which also remembers it.
      await bind("hdr-stage://sub2-select", (p) => h().sub2?.onSelect((p as { id: string | null }).id));
      await bind("hdr-stage://sub2-add", (p) => {
        const a = p as { url: string; lang?: string; title?: string };
        void h().sub2?.onAdd(a.url, a.lang, a.title);
      });
      await bind("hdr-stage://sub2-delay", (p) => h().sub2?.onDelay((p as { sec: number }).sec));
      await bind("hdr-stage://pip", () => h().pip());
      await bind("hdr-stage://cast", () => h().cast());
      await bind("hdr-stage://back", () => h().back());
      await bind("hdr-stage://prev-ep", () => h().prevEp());
      await bind("hdr-stage://next-ep", () => h().nextEp());
      await bind("hdr-stage://pick-another", () => h().pickAnother());
      await bind("hdr-stage://screenshot", () => h().screenshot());
      await bind("hdr-stage://menu-open", (p) => h().menuOpen((p as { open: boolean }).open));
      await bind("hdr-stage://activity", () => h().activity());
      await bind("hdr-stage://hold-speed", (p) => {
        holding = (p as { on: boolean }).on === true;
        h().holdSpeed(holding);
      });
      await bind("hdr-stage://open-external", (p) => {
        const player = (p as { player?: ExternalPlayer }).player;
        if (player && typeof player.id === "string") h().openExternal(player);
      });
      await bind("hdr-stage://request", () => void hdrOverlayEmitProps(payloadRef.current));
    })();
    return () => {
      cancelled = true;
      for (const off of offs) off();
      // The HDR window went away mid-hold: its button-up will never come.
      if (holding) handlersRef.current.holdSpeed(false);
    };
  }, [active]);

  return null;
}
