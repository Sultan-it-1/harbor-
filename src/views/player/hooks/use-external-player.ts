import { useCallback, useRef, type RefObject } from "react";
import type { PlayerBridge } from "@/lib/player/bridge";
import { getPlaybackPosition } from "@/lib/player/playback-clock";
import type { PlayerSrc } from "@/lib/view";
import {
  externalPlayerLabel,
  externalPlayersSupported,
  openInExternalPlayer,
  rememberExternalPlayer,
  type ExternalPlayer,
} from "@/lib/external-player";
// The plain t reads the language when it runs, so the callback below can stay the same.
import { t } from "@/lib/i18n";
import type { LiveSource } from "./use-stream-switcher";

/**
 * Opens the stream that is playing now in another app (VLC, mpv, ...), at the current position
 * when it isn't live, then pauses Harbor so the two don't play over each other. Returns
 * undefined where no other app can be started (the web build, the Android app), which hides
 * the button.
 */
export function useExternalPlayer(params: {
  bridgeRef: RefObject<PlayerBridge | null>;
  liveSourceRef: RefObject<LiveSource>;
  src: PlayerSrc;
  isLive: boolean;
  notify: (kind: "ok" | "error", text: string) => void;
}): ((player: ExternalPlayer) => Promise<void>) | undefined {
  const paramsRef = useRef(params);
  paramsRef.current = params;

  const open = useCallback(
    async (player: ExternalPlayer) => {
      const { bridgeRef, liveSourceRef, src, isLive, notify } = paramsRef.current;
      // The source playing now: after a switch inside the player it is no longer src.
      const cur = liveSourceRef.current;
      const pos = getPlaybackPosition();
      const title = src.subtitle ? `${src.title} · ${src.subtitle}` : src.title;
      const name = externalPlayerLabel(player, t);
      try {
        await openInExternalPlayer({
          player: player.id,
          url: cur.url,
          title,
          startSec: !isLive && Number.isFinite(pos) && pos >= 1 ? pos : undefined,
          headers: cur.headers,
        });
      } catch (e) {
        console.warn("[external-player]", e);
        notify("error", t("Could not open in {name}", { name }));
        return;
      }
      rememberExternalPlayer(player.id);
      bridgeRef.current?.pause();
      notify("ok", player.id === "system" ? t("Opened in the default app") : t("Opened in {name}", { name }));
    },
    [],
  );

  return externalPlayersSupported() ? open : undefined;
}
