import { useCallback, useMemo, useRef, useState, type RefObject } from "react";
import type { PlayerBridge } from "@/lib/player/bridge";

/** Speed while the play key or the mouse button is held (kept when already faster). */
export const HOLD_SPEED = 2;

export type HoldSpeedSource = "key" | "mouse";

export type HoldSpeed = {
  /** True while something holds; shows the speed indicator. */
  active: boolean;
  engage: (source: HoldSpeedSource) => void;
  release: (source: HoldSpeedSource) => void;
};

/**
 * Hold-to-speed-up, shared by the keyboard and the mouse so they can't fight. Each one says when
 * it starts and stops holding. The speed goes up when the first one starts and goes back to what
 * it was before when the last one lets go, so holding both and letting go in any order ends at
 * the right speed.
 */
export function useHoldSpeed(bridgeRef: RefObject<PlayerBridge | null>, rate: number): HoldSpeed {
  const rateRef = useRef(rate);
  rateRef.current = rate;
  const holdRef = useRef<{ sources: Set<HoldSpeedSource>; baseRate: number }>({
    sources: new Set(),
    baseRate: 1,
  });
  const [active, setActive] = useState(false);

  const engage = useCallback(
    (source: HoldSpeedSource) => {
      const h = holdRef.current;
      if (h.sources.has(source)) return;
      if (h.sources.size === 0) {
        // The speed to go back to: read when the hold starts, not when the key went down.
        h.baseRate = rateRef.current;
        setActive(true);
        bridgeRef.current?.setRate(Math.max(HOLD_SPEED, h.baseRate));
      }
      h.sources.add(source);
    },
    [bridgeRef],
  );

  const release = useCallback(
    (source: HoldSpeedSource) => {
      const h = holdRef.current;
      if (!h.sources.delete(source)) return;
      if (h.sources.size > 0) return;
      setActive(false);
      bridgeRef.current?.setRate(h.baseRate);
    },
    [bridgeRef],
  );

  return useMemo(() => ({ active, engage, release }), [active, engage, release]);
}
