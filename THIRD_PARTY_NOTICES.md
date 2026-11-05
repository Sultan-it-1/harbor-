# Third-party notices

Harbor's own code is under the [MIT License](./LICENSE). The apps also ship code, fonts and
libraries made by others, each under its own licence. This list covers what goes into the
Android APK and the web UI it runs.

## Android app

| Component | Licence | Notes |
| --- | --- | --- |
| AndroidX Core, Activity, WebKit | Apache-2.0 | android.googlesource.com |
| AndroidX Media3 (ExoPlayer, HLS, DASH, UI, Session) | Apache-2.0 | github.com/androidx/media |
| Jellyfin Media3 FFmpeg decoder (`org.jellyfin.media3:media3-ffmpeg-decoder`) | **GPL-3.0** | github.com/jellyfin/jellyfin-androidx-media. Bundles FFmpeg (`libffmpegJNI.so`) for AC3, E-AC3, DTS and TrueHD audio. |
| FFmpeg (inside the decoder above) | LGPL-2.1-or-later, or GPL when built with GPL parts | ffmpeg.org |
| Kotlin standard library, kotlinx.coroutines | Apache-2.0 | kotlinlang.org |

**About the FFmpeg decoder.** Its published POM declares GPL-3.0. An APK that includes it is
distributed with a GPL-3.0 component, so that component's source must be available to anyone who
gets the APK (it is public at the address above) and its licence terms apply to it. If the
project's own licence or distribution needs to stay MIT-only, the decoder can be removed from
`android/app/build.gradle.kts`: playback still works, but those audio formats then play only on
phones that decode them in hardware. This note is technical information, not legal advice.

## Web UI (bundled in the APK and served by the web build)

| Component | Licence |
| --- | --- |
| React, React DOM | MIT |
| react-markdown, remark-gfm, rehype-raw | MIT |
| hls.js | Apache-2.0 |
| mpegts.js | Apache-2.0 |
| lucide-react (icons) | ISC |
| lottie-web | MIT |
| parse-torrent-title | MIT |
| gifenc | MIT |
| Tailwind CSS | MIT |

## Fonts (public/fonts)

| Font | Licence |
| --- | --- |
| Sentient, Switzer, General Sans, Cabinet Grotesk (Fontshare, Indian Type Foundry) | ITF Free Font License |
| Fraunces, Inter, IBM Plex Sans, Plus Jakarta Sans (Google Fonts) | SIL Open Font License 1.1 |

Desktop-only parts (Tauri, libmpv, the Express server of the hosted web build) are not in the
Android APK and are covered by their own licences.
