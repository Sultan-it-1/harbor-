import { useEffect, useMemo } from "react";
import { useSettings } from "@/lib/settings";
import { getThemeById } from "@/lib/theme";
import { useView } from "@/lib/view";
import type { CustomTheme } from "@/lib/custom-themes";
import { isPhoneLayout } from "@/lib/platform";

// Android app: a theme (downloaded or imported from a file) may style the app, but its own
// JavaScript would run with the app's full rights: sign-in tokens, debrid keys and the device
// bridge. On the phone only the user's own custom code runs; theme scripts are skipped and theme
// HTML is stripped of scripts and event handlers.
const PHONE = isPhoneLayout();

function stripActiveContent(html: string): string {
  if (!html || typeof DOMParser === "undefined") return html;
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html");
  doc.querySelectorAll("script, iframe, object, embed, link, meta, base, form").forEach((n) => n.remove());
  doc.querySelectorAll("*").forEach((el) => {
    for (const a of [...el.attributes]) {
      const name = a.name.toLowerCase();
      if (name.startsWith("on") || /^\s*javascript:/i.test(a.value) || ((name === "href" || name === "src") && /^\s*data:text\/html/i.test(a.value))) {
        el.removeAttribute(a.name);
      }
    }
  });
  return doc.body.innerHTML;
}

const STYLE_ID = "harbor-custom-css";
const THEME_STYLE_ID = "harbor-theme-css";
const OVERLAY_ID = "harbor-custom-overlay";

function runThemeCleanup(key: "__harborCustomCleanup" | "__harborThemeCleanup") {
  const w = window as unknown as Record<string, unknown>;
  const fn = w[key];
  if (typeof fn === "function") {
    try {
      (fn as () => void)();
    } catch {
      void 0;
    }
  }
  w[key] = undefined;
}

export function CustomCodeMount() {
  const { settings } = useSettings();
  const { player } = useView();

  const themeExt = useMemo(() => {
    if (settings.theme.preset === "custom") return null;
    const t = getThemeById(settings.theme.preset) as CustomTheme | null;
    if (!t) return null;
    return {
      css: t.css ?? "",
      js: t.js ?? "",
      html: t.html ?? "",
    };
  }, [settings.theme.preset]);

  useEffect(() => {
    if (typeof document === "undefined") return;
    let el = document.getElementById(STYLE_ID) as HTMLStyleElement | null;
    if (!el) {
      el = document.createElement("style");
      el.id = STYLE_ID;
      document.head.appendChild(el);
    }
    el.textContent = settings.customCss ?? "";
    return () => {
      if (el && !settings.customCss) el.textContent = "";
    };
  }, [settings.customCss]);

  useEffect(() => {
    if (typeof document === "undefined") return;
    let el = document.getElementById(THEME_STYLE_ID) as HTMLStyleElement | null;
    if (!el) {
      el = document.createElement("style");
      el.id = THEME_STYLE_ID;
      document.head.appendChild(el);
    }
    el.textContent = themeExt?.css ?? "";
  }, [themeExt?.css]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const code = (settings.customJs ?? "").trim();
    if (!code) return;
    try {
      new Function(code)();
    } catch (err) {
      console.warn("[harbor-custom-js] error:", err);
    }
    return () => runThemeCleanup("__harborCustomCleanup");
  }, [settings.customJs]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const code = (themeExt?.js ?? "").trim();
    if (!code) return;
    if (PHONE) {
      console.info("[harbor-theme-js] skipped on Android: themes can't run scripts in the app");
      return;
    }
    try {
      new Function(code)();
    } catch (err) {
      console.warn("[harbor-theme-js] error:", err);
    }
    return () => runThemeCleanup("__harborThemeCleanup");
  }, [themeExt?.js]);

  const themeHtml = PHONE ? stripActiveContent(themeExt?.html ?? "") : (themeExt?.html ?? "");
  const html = `${settings.customHtml ?? ""}${themeHtml}`;
  return (
    <div
      id={OVERLAY_ID}
      aria-hidden
      className={`pointer-events-none fixed inset-0 z-[100] ${player ? "hidden" : ""}`}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
