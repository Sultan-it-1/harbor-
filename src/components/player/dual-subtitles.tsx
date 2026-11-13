import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useSettings } from "@/lib/settings";
import type { PlayerSnapshot } from "@/lib/player/bridge";
import { firstSubLook, firstSubOnRight, resolveSecondLook } from "@/lib/player/dual-subs";
import { oneLineHeight, SubtitleOverlay, type SubPlacement } from "./subtitle-overlay";

/** How the second subtitle is placed right now. "follow": stacked, its place follows the first
 *  subtitle. "top": at the top of the picture (the video player draws the first one, so the
 *  page can't measure or move it). "own": side by side, at its own distance from the bottom. */
export type SecondPlacementMode = "follow" | "top" | "own";

/** Whether the player area (the whole window, outside picture-in-picture) is taller than it
 *  is wide. Side by side doesn't fit there, so the two subtitles are stacked instead. */
export function useTallPlayerArea(): boolean {
  const read = () => typeof window !== "undefined" && window.innerHeight > window.innerWidth;
  const [tall, setTall] = useState(read);
  useEffect(() => {
    const onResize = () => setTall(read());
    onResize();
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return tall;
}

/** The layout actually used: side by side only fits a player area wider than tall. */
export function effectiveSecondLayout(layout: "stacked" | "side", portrait: boolean): "stacked" | "side" {
  return portrait ? "stacked" : layout;
}

export function secondPlacementMode(
  layout: "stacked" | "side",
  portrait: boolean,
  firstDrawnByPlayer: boolean,
): SecondPlacementMode {
  if (firstDrawnByPlayer) return "top";
  return effectiveSecondLayout(layout, portrait) === "side" ? "own" : "follow";
}

/**
 * The first subtitle, and the second one with it when there is one. With no second subtitle
 * this draws exactly what the first subtitle alone always drew.
 */
export function DualSubtitles({
  snap,
  pipMode,
  showFirst,
  showSecond,
  firstDrawnByPlayer,
  portrait,
}: {
  snap: PlayerSnapshot;
  pipMode: boolean;
  /** The page draws the first subtitle (not the video player, not hidden). */
  showFirst: boolean;
  /** The page draws the second subtitle (there is one, not in picture-in-picture, not hidden). */
  showSecond: boolean;
  /** The video player draws the first subtitle itself (styled ASS, picture subtitles). */
  firstDrawnByPlayer: boolean;
  portrait: boolean;
}) {
  const { settings } = useSettings();

  // The first subtitle's box as drawn, so a stacked second subtitle sits right above it
  // whatever its size, line count or wrapping.
  const firstElRef = useRef<HTMLDivElement | null>(null);
  const roRef = useRef<ResizeObserver | null>(null);
  const [firstHeight, setFirstHeight] = useState(0);
  const measure = useCallback(() => {
    const el = firstElRef.current;
    const h = el ? Math.round(el.getBoundingClientRect().height) : 0;
    setFirstHeight((prev) => (prev === h ? prev : h));
  }, []);
  // The first subtitle's box is a new element for every line, so the observer moves with it.
  const firstRef = useCallback(
    (el: HTMLDivElement | null) => {
      if (firstElRef.current && roRef.current) roRef.current.unobserve(firstElRef.current);
      firstElRef.current = el;
      if (!el) return;
      if (!roRef.current && typeof ResizeObserver !== "undefined") roRef.current = new ResizeObserver(measure);
      roRef.current?.observe(el);
    },
    [measure],
  );
  // After every render: the line, the look or the window may have changed. Measured before
  // the frame is painted, so the second subtitle never shows in the wrong place.
  useLayoutEffect(measure);
  useEffect(() => () => roRef.current?.disconnect(), []);

  const first = (
    <SubtitleOverlay
      text={showFirst ? snap.subText : ""}
      startSec={snap.subStartSec}
      scale={pipMode ? 0.45 : 1}
      placement={undefined}
      boxRef={showSecond ? firstRef : undefined}
    />
  );
  if (!showSecond) return first;

  const look1 = firstSubLook(settings);
  const look2 = resolveSecondLook(settings);
  const mode = secondPlacementMode(settings.sub2Layout, portrait, firstDrawnByPlayer);

  let firstPlacement: SubPlacement = { kind: "bottom" };
  let secondPlacement: SubPlacement;
  if (mode === "top") {
    secondPlacement = { kind: "top" };
  } else if (mode === "own") {
    const secondLang = snap.subtitleTracks.find((t) => t.secondarySelected)?.lang;
    const firstLang = snap.subtitleTracks.find((t) => t.selected)?.lang;
    const firstRight = firstSubOnRight(firstLang, secondLang, settings.sub2SwapSides);
    firstPlacement = { kind: "half", side: firstRight ? "right" : "left" };
    secondPlacement = { kind: "half", side: firstRight ? "left" : "right" };
  } else {
    const margin1 = Math.max(0, Number(look1.subMarginY) || 0);
    const gap = Math.max(4, Math.round((Number(look1.subFontSize) || 32) * 0.2));
    if (!showFirst) {
      // The first subtitle is hidden (syncing the second): the second takes its place.
      secondPlacement = { kind: "above", bottom: `${margin1}%` };
    } else if (margin1 > 50) {
      // The first subtitle was moved near the top: the second goes just under it, on screen.
      secondPlacement = { kind: "below", top: `calc(${100 - margin1}% + ${gap}px)` };
    } else {
      // Between two lines of the first subtitle the second stays where a one-line first
      // subtitle would push it, instead of dropping to the bottom and jumping back up.
      const below = firstHeight > 0 ? firstHeight : oneLineHeight(look1);
      secondPlacement = { kind: "above", bottom: `calc(${margin1}% + ${below + gap}px)` };
    }
  }

  return (
    <>
      <SubtitleOverlay
        text={showFirst ? snap.subText : ""}
        startSec={snap.subStartSec}
        scale={pipMode ? 0.45 : 1}
        placement={firstPlacement}
        boxRef={firstRef}
      />
      <SubtitleOverlay text={snap.secondarySubText} startSec={0} look={look2} placement={secondPlacement} />
    </>
  );
}
