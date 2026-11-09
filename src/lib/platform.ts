function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function isWeb(): boolean {
  return typeof window !== "undefined" && !("__TAURI_INTERNALS__" in window);
}

export function isLinuxDesktop(): boolean {
  if (!isTauri()) return false;
  const ua = (navigator.userAgent || "").toLowerCase();
  const plat = (navigator.platform || "").toLowerCase();
  if (ua.includes("android")) return false;
  if (ua.includes("windows") || ua.includes("macintosh") || ua.includes("mac os")) return false;
  return ua.includes("linux") || plat.includes("linux");
}

export function isMacDesktop(): boolean {
  if (!isTauri()) return false;
  const ua = (navigator.userAgent || "").toLowerCase();
  const plat = (navigator.platform || "").toLowerCase();
  return ua.includes("macintosh") || ua.includes("mac os") || plat.includes("mac");
}

export function isWindowsDesktop(): boolean {
  if (!isTauri()) return false;
  return (navigator.userAgent || "").toLowerCase().includes("windows");
}

export function isMobileDevice(): boolean {
  if (typeof navigator === "undefined" || typeof window === "undefined") return false;
  const ua = navigator.userAgent || "";
  if (/Android|webOS|iPhone|iPod|BlackBerry|IEMobile|Opera Mini|iPad/i.test(ua)) return true;
  if (/Macintosh/i.test(ua) && (navigator.maxTouchPoints ?? 0) > 1) return true;
  if ((navigator.maxTouchPoints ?? 0) > 0 && Math.min(window.innerWidth, window.innerHeight) < 640) {
    return true;
  }
  return false;
}

/** The iPhone app: Harbor's web UI in the iOS shell (it adds "HarborIOS/" to the user agent). */
export function isIOSApp(): boolean {
  return typeof navigator !== "undefined" && /\bHarborIOS\//.test(navigator.userAgent || "");
}

/** Native-app phone layout (the Android or iPhone shell): bottom tab bar, device-width viewport. */
export function isPhoneLayout(): boolean {
  return typeof window !== "undefined" && ("HarborAndroid" in window || isIOSApp());
}
