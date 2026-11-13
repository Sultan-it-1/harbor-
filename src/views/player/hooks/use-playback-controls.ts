import { useCallback, type RefObject } from "react";
import type { CastDeviceInfo } from "@/lib/cast";
import type { PlayerBridge, PlayerSnapshot, TrackInfo } from "@/lib/player/bridge";
import { getPlaybackPosition } from "@/lib/player/playback-clock";
import { writePlayerPrefs } from "@/lib/player-prefs";
import { episodeSubsKey, pickFromTrack, writeEpisodeSubs } from "@/lib/player/sub-memory";
import type { RoomCommand } from "@/lib/together/protocol";

/** What is known about a first subtitle the viewer picked: a track from the list, an addon
 *  subtitle just added (its address), or only a language. */
export type SubChoice =
  | (Partial<Pick<TrackInfo, "id" | "lang" | "title" | "external" | "url" | "forced" | "hearingImpaired" | "secondarySelected">>)
  | null
  | undefined;

export function usePlaybackControls(params: {
  bridgeRef: RefObject<PlayerBridge | null>;
  snapRef: RefObject<PlayerSnapshot>;
  metaId: string;
  season?: number | null;
  episode?: number | null;
  inRoom: boolean;
  isHost: boolean;
  hasStarted: boolean;
  canControl: boolean;
  castDevice: CastDeviceInfo | null;
  startHost: () => void;
  togglePlayCast: () => Promise<void>;
  seekCast: (sec: number) => Promise<void>;
  sendCommand: (command: RoomCommand) => void;
}) {
  const {
    bridgeRef,
    snapRef,
    metaId,
    season,
    episode,
    inRoom,
    isHost,
    hasStarted,
    canControl,
    castDevice,
    startHost,
    togglePlayCast,
    seekCast,
    sendCommand,
  } = params;

  const rememberSubChoice = useCallback(
    (t: SubChoice) => {
      if (t) writePlayerPrefs(metaId, t.lang ? { subLang: t.lang, subsOff: false } : { subsOff: false });
      // Off: the second subtitle goes with the first one.
      else writePlayerPrefs(metaId, { subsOff: true, sub2Lang: "" });

      // The exact subtitle for this episode, so the same one comes back next time.
      const key = episodeSubsKey(metaId, season, episode);
      if (!t) {
        writeEpisodeSubs(key, { first: null, second: null });
        return;
      }
      // Only a language known (no track, no address): the language memory above is all there is.
      const exact = t.id || t.url ? pickFromTrack(t, snapRef.current.subtitleTracks) : null;
      if (t.secondarySelected) {
        // The second subtitle's track became the first, so there is no second any more.
        writeEpisodeSubs(key, { first: exact ?? undefined, second: null });
        writePlayerPrefs(metaId, { sub2Lang: "" });
      } else {
        writeEpisodeSubs(key, { first: exact ?? undefined });
      }
    },
    [metaId, season, episode, snapRef],
  );

  const cycleSubtitles = () => {
    // The second subtitle's track is left out: cycling moves the first one only.
    const subs = snapRef.current.subtitleTracks.filter((t) => !t.secondarySelected);
    const idx = subs.findIndex((t) => t.selected);
    const off = idx === -1;
    if (subs.length === 0) return;
    if (off) {
      bridgeRef.current?.setSubtitleTrack(subs[0].id);
      rememberSubChoice(subs[0]);
      return;
    }
    const next = idx + 1;
    if (next >= subs.length) {
      bridgeRef.current?.setSubtitleTrack(null);
      rememberSubChoice(null);
    } else {
      bridgeRef.current?.setSubtitleTrack(subs[next].id);
      rememberSubChoice(subs[next]);
    }
  };

  const playPauseToggle = () => {
    if (inRoom && isHost && !hasStarted) {
      startHost();
      return;
    }
    if (castDevice) {
      void togglePlayCast();
      return;
    }
    if (!canControl) return;
    if (inRoom && !isHost) {
      sendCommand(snapRef.current.status === "playing" ? { action: "pause" } : { action: "play" });
      return;
    }
    const b = bridgeRef.current;
    if (!b) return;
    if (snapRef.current.status === "playing") b.pause();
    else b.play().catch(() => {});
  };

  const seekStep = (delta: number) => {
    const pos = getPlaybackPosition();
    if (castDevice) {
      void seekCast(Math.max(0, pos + delta));
      return;
    }
    if (!canControl) return;
    if (inRoom && !isHost) {
      sendCommand({ action: "seek", positionSeconds: Math.max(0, pos + delta) });
      return;
    }
    bridgeRef.current?.seek(Math.max(0, pos + delta));
  };

  const seekTo = useCallback(
    (sec: number) => {
      if (castDevice) {
        void seekCast(Math.max(0, sec));
        return;
      }
      if (!canControl) return;
      if (inRoom && !isHost) {
        sendCommand({ action: "seek", positionSeconds: Math.max(0, sec) });
        return;
      }
      bridgeRef.current?.seek(Math.max(0, sec));
    },
    [castDevice, canControl, inRoom, isHost, sendCommand, seekCast, bridgeRef],
  );

  return { rememberSubChoice, cycleSubtitles, playPauseToggle, seekStep, seekTo };
}
