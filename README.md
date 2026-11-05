<div align="center">

<img src="docs/media/harbor-mark.svg" width="72" alt="Harbor">

# Harbor

A Stremio client for Android and the web.

<a href="https://github.com/Sultan-it-1/harbor-/releases/latest/download/harbor-android.apk"><img alt="Download for Android" src="https://img.shields.io/badge/Download-Android%20APK-3DDC84?style=for-the-badge&logo=android&logoColor=white"></a>

<sub><a href="https://github.com/Sultan-it-1/harbor-/releases">All releases</a> · <a href="https://github.com/Sultan-it-1/harbor-/actions/workflows/android-build.yml">Builds</a> · <a href="https://github.com/Sultan-it-1/harbor-/issues">Issues</a></sub>

</div>

## Android app

- Native player (ExoPlayer) with FFmpeg audio, so Dolby / DTS tracks play with sound.
- Addon subtitles with adjustable size, background, colour, position and delay.
- Phone layout with a bottom tab bar, pinch to fill the screen while watching.
- Downloads run in the background (movies, episodes and whole seasons) and play offline, with their subtitles.
- Search inside any "View all" list: forgives typos, understands Arabic and English, and also finds titles by year, genre or initials ("got" finds Game of Thrones).
- A small check on the posters and episodes you've watched, following Harbor's history, your Stremio library and Trakt (switch it off in Settings).
- Runs at the screen's highest refresh rate; video uses a judder-free rate and hardware decoding.
- Signed releases: each new APK installs over the previous one.

### Install

1. Download [`harbor-android.apk`](https://github.com/Sultan-it-1/harbor-/releases/latest/download/harbor-android.apk) on your phone.
2. Open it and allow "install from unknown sources" when asked.

Every push to `main` builds a new APK and publishes it under [Releases](https://github.com/Sultan-it-1/harbor-/releases).

## Development

```bash
pnpm install
pnpm dev            # web UI at http://localhost:1420
pnpm build && pnpm start   # production web build served on :1421
```

Android APK (needs the Android SDK and JDK 17):

```bash
pnpm build
cd android && ./gradlew assembleRelease
```

| Path | What |
| --- | --- |
| `src/` | React UI (shared by web, desktop and Android) |
| `android/` | Android shell: WebView, native player, subtitles |
| `src-tauri/` | Desktop app (Tauri) |
| `server.js` | Web server and API proxy |

## Disclaimer

Harbor hosts no media and ships no content addons. You choose which addons and sources to use and are responsible for complying with the laws where you live. Not affiliated with Stremio.

## License

Harbor's own code is [MIT](./LICENSE). The Android APK also bundles third-party libraries and
fonts under their own licences, including the Media3 FFmpeg decoder from Jellyfin, which is
published under GPL-3.0. See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).
