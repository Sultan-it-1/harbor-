import { useEffect, useMemo, useRef, type RefObject } from "react";
import type { PlayerBridge, PlayerSnapshot, TrackInfo } from "@/lib/player/bridge";
import type { SecondSubControls } from "@/lib/player/second-sub-context";
import { readPlayerPrefs, writePlayerPrefs } from "@/lib/player-prefs";
import { episodeSubsKey, findPickedTrack, pickFromTrack, readEpisodeSubs, writeEpisodeSubs } from "@/lib/player/sub-memory";
import { langScore } from "@/lib/subtitles/language";

const SETTLE_MS = 450;

/**
 * The second subtitle (desktop player only): what the menu and the sync bar call to change
 * it, and putting the remembered one back when an episode plays again.
 */
export function useSecondSubtitle(params: {
  bridgeRef: RefObject<PlayerBridge | null>;
  snap: PlayerSnapshot;
  engine: "html5" | "mpv";
  metaId: string;
  season?: number | null;
  episode?: number | null;
  srcUrl: string;
}) {
  const { bridgeRef, snap, engine, metaId, season, episode, srcUrl } = params;
  const key = episodeSubsKey(metaId, season, episode);
  const keyRef = useRef(key);
  keyRef.current = key;
  const metaIdRef = useRef(metaId);
  metaIdRef.current = metaId;
  const snapRef = useRef(snap);
  snapRef.current = snap;
  // The viewer changed the second subtitle during this playback: nothing is put back over it.
  const touchedRef = useRef(false);
  // The second subtitle this hook turned on by itself (not the viewer's pick).
  const autoIdRef = useRef<string | null>(null);
  // Tracks already put on for this file. One that didn't stay on (mpv couldn't show it) is
  // not tried again, so a broken file doesn't keep being switched on.
  const triedRef = useRef(new Set<string>());

  useEffect(() => {
    touchedRef.current = false;
    autoIdRef.current = null;
    triedRef.current = new Set();
  }, [srcUrl, key]);

  // Putting the second subtitle back: the exact one remembered for this episode once the
  // player has it (an addon subtitle only if it is offered again), or else one in the second
  // language last used for this title. It waits for a first subtitle, and never takes the
  // first one's track. Runs again as tracks arrive, because addon subtitles come in late.
  const restore = () => {
    const now = snapRef.current;
    const tracks = now.subtitleTracks;
    if (touchedRef.current || tracks.length === 0) return;
    const first = tracks.find((t) => t.selected);
    if (!first) return;
    const current = tracks.find((t) => t.secondarySelected) ?? null;
    // A second subtitle someone else turned on (text sync's result, for one) stays.
    if (current && current.id !== autoIdRef.current) return;
    const b = bridgeRef.current;
    if (!b) return;

    const candidates = tracks.filter((t) => t.id !== first.id);
    const memory = readEpisodeSubs(keyRef.current);
    let want: TrackInfo | null = null;
    let exact = false;
    if (memory && memory.second !== undefined) {
      // Remembered for this episode (null: the viewer chose no second subtitle here).
      want = findPickedTrack(candidates, memory.second);
      exact = !!want;
    } else {
      const lang = readPlayerPrefs(metaIdRef.current)?.sub2Lang;
      if (lang) want = bestTrackForLang(candidates, lang);
    }
    if (!want || want.id === current?.id || triedRef.current.has(want.id)) return;
    triedRef.current.add(want.id);
    autoIdRef.current = want.id;
    b.setSecondarySubtitleTrack(want.id);
    const delay = memory?.secondDelaySec;
    if (exact && typeof delay === "number" && delay !== now.secondarySubDelaySec) {
      b.setSecondarySubDelay(delay);
    }
  };
  const restoreRef = useRef(restore);
  restoreRef.current = restore;
  const timerRef = useRef<number | null>(null);

  useEffect(() => {
    if (engine !== "mpv") return;
    if (snap.subtitleTracks.length === 0) {
      // A new file is loading (an episode or stream change): start over for it.
      touchedRef.current = false;
      autoIdRef.current = null;
      triedRef.current = new Set();
      return;
    }
    // A moment's wait, so the first subtitle the player picks by itself on load is settled
    // (it may be about to take the very track the second would get). One wait at a time;
    // it looks at the newest tracks when it ends.
    if (timerRef.current != null) return;
    timerRef.current = window.setTimeout(() => {
      timerRef.current = null;
      restoreRef.current();
    }, SETTLE_MS);
  }, [engine, key, snap.subtitleTracks]);

  useEffect(
    () => () => {
      if (timerRef.current != null) window.clearTimeout(timerRef.current);
    },
    [],
  );

  const controls = useMemo<SecondSubControls | null>(() => {
    if (engine !== "mpv") return null;
    return {
      onSelect: (id) => {
        touchedRef.current = true;
        bridgeRef.current?.setSecondarySubtitleTrack(id);
        if (id == null) {
          writeEpisodeSubs(key, { second: null });
          writePlayerPrefs(metaId, { sub2Lang: "" });
          return;
        }
        const tracks = snapRef.current.subtitleTracks;
        const t = tracks.find((x) => x.id === id);
        if (!t) return;
        writeEpisodeSubs(key, {
          second: pickFromTrack(t, tracks) ?? undefined,
          secondDelaySec: snapRef.current.secondarySubDelaySec,
        });
        writePlayerPrefs(metaId, { sub2Lang: t.lang ?? "" });
      },
      onAdd: async (url, lang, title) => {
        const b = bridgeRef.current;
        if (!b) return false;
        touchedRef.current = true;
        const ok = await b.addSecondarySubtitle(url, lang, title);
        if (ok) {
          writeEpisodeSubs(key, {
            second: { kind: "url", url, lang },
            secondDelaySec: snapRef.current.secondarySubDelaySec,
          });
          writePlayerPrefs(metaId, { sub2Lang: lang ?? "" });
        }
        return ok;
      },
      onDelay: (sec) => {
        bridgeRef.current?.setSecondarySubDelay(sec);
        writeEpisodeSubs(key, { secondDelaySec: sec });
      },
    };
  }, [engine, key, metaId, bridgeRef]);

  return controls;
}

// A subtitle in the given language for the second subtitle: not a forced-only track; the
// file's default one if it has one, else the first in the player's list.
function bestTrackForLang(tracks: TrackInfo[], lang: string): TrackInfo | null {
  const matching = tracks.filter(
    (t) => !t.forced && !/\bforced\b/i.test(`${t.title ?? ""} ${t.label ?? ""}`) && langScore(t.lang ?? "", [lang]) >= 0,
  );
  if (matching.length === 0) return null;
  return matching.find((t) => t.default) ?? matching[0];
}
