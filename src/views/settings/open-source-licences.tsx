import { t } from "@/lib/i18n/translate";

// What ships inside the app besides Harbor's own (MIT) code. Keep in step with
// THIRD_PARTY_NOTICES.md at the repository root.
const GROUPS: Array<{ title: string; items: Array<[name: string, licence: string]> }> = [
  {
    title: "Android app",
    items: [
      ["AndroidX Core, Activity, WebKit", "Apache-2.0"],
      ["AndroidX Media3 (ExoPlayer, HLS, DASH, UI, Session)", "Apache-2.0"],
      ["Jellyfin Media3 FFmpeg decoder", "GPL-3.0"],
      ["FFmpeg", "LGPL-2.1+ / GPL"],
      ["Kotlin, kotlinx.coroutines", "Apache-2.0"],
    ],
  },
  {
    title: "Interface",
    items: [
      ["React, React DOM", "MIT"],
      ["react-markdown, remark-gfm, rehype-raw", "MIT"],
      ["hls.js", "Apache-2.0"],
      ["mpegts.js", "Apache-2.0"],
      ["lucide-react", "ISC"],
      ["lottie-web, parse-torrent-title, gifenc", "MIT"],
      ["Tailwind CSS", "MIT"],
    ],
  },
  {
    title: "Fonts",
    items: [
      ["Sentient, Switzer, General Sans, Cabinet Grotesk", "ITF Free Font License"],
      ["Fraunces, Inter, IBM Plex Sans, Plus Jakarta Sans", "SIL OFL 1.1"],
    ],
  },
];

export function OpenSourceLicences() {
  return (
    <details className="group rounded-2xl border border-edge-soft bg-canvas/30 p-5">
      <summary className="cursor-pointer list-none text-[10.5px] font-bold uppercase tracking-[0.22em] text-ink-subtle">
        {t("Open-source licences")}
      </summary>
      <p className="mt-2 text-[12px] leading-relaxed text-ink-muted">
        {t("Harbor's own code is MIT. The app also includes these components, each under its own licence.")}
      </p>
      {GROUPS.map((g) => (
        <div key={g.title} className="mt-3">
          <div className="text-[11.5px] font-semibold text-ink">{t(g.title)}</div>
          <ul className="mt-1 flex flex-col gap-1">
            {g.items.map(([name, licence]) => (
              <li key={name} className="flex items-baseline justify-between gap-3 text-[12px] text-ink-muted">
                <span dir="ltr" className="min-w-0">{name}</span>
                <span dir="ltr" className="shrink-0 font-mono text-[11px] text-ink-subtle">{licence}</span>
              </li>
            ))}
          </ul>
        </div>
      ))}
      <p className="mt-3 text-[11.5px] leading-relaxed text-ink-subtle">
        {t("The FFmpeg decoder (AC3, E-AC3, DTS and TrueHD audio) is published under GPL-3.0. Its source is public at github.com/jellyfin/jellyfin-androidx-media.")}
      </p>
    </details>
  );
}
