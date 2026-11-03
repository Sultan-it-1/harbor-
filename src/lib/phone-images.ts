// Image loading tuned for the Android app (phone screens, mobile data). The app also keeps the
// images it shows on the phone (android/…/ImageCache.kt) and caps TMDB "original" at 1280px.
import { useEffect, useState, type RefObject } from "react";
import { isPhoneLayout } from "@/lib/platform";

const PHONE = isPhoneLayout();

/** TMDB size for episode stills. Phones show them small, so 500px is plenty (instead of the
 *  full-size original, 10-20× the bytes). */
export function stillSize(hd: boolean): string {
  if (PHONE) return "w500";
  return hd ? "original" : "w300";
}

/** On phones, images off screen wait until you get near them, so what you see loads first. */
export const phoneLazy: "lazy" | undefined = PHONE ? "lazy" : undefined;

/**
 * Phones: true once the element is about to scroll into view (about a screen below/above,
 * a couple of posters to either side in a row), so the posters you see load first instead
 * of the whole page's posters at once. Elsewhere (or without IntersectionObserver): always true.
 */
export function useNearViewport(ref: RefObject<Element | null>): boolean {
  const [near, setNear] = useState(!PHONE);
  useEffect(() => {
    if (near) return;
    const el = ref.current;
    if (!el || typeof IntersectionObserver === "undefined") {
      setNear(true);
      return;
    }
    // The pages scroll inside their own containers (and rows sideways), whose edges would cut
    // the margin off: scrollMargin widens every container on the way (current WebViews; older
    // ones ignore it and load posters as they come into view).
    const opts = { rootMargin: "800px 120px", scrollMargin: "800px 360px" } as IntersectionObserverInit;
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        setNear(true);
        io.disconnect();
      }
    }, opts);
    io.observe(el);
    return () => io.disconnect();
  }, [near, ref]);
  return near;
}
