# iOS native: plan and checklist

The Android app draws its main screens natively (Kotlin, `android/…/NativeHome.kt` and friends,
about 15,600 lines). The iPhone app gets the same in Swift (UIKit), in `ios/native/App/App/Native/`.

**How:** the same contract as Android, so the web code that builds the screens stays as it is.
The page sends a screen's description (`homeSet(json)`, `screenShow(page, bottom, width)`), the
native side draws it and sends taps back through `window.__harborNativeHome(json)`. The player
already works this way (`HarborPlayer`).

**Builds:** no iOS build runs until every part below is written (the workflow is manual-only).
Then: build, fix what the compiler finds, check every screen in the simulator, IPA.

| Android | Swift (iOS) |
| --- | --- |
| RecyclerView of sections + horizontal rows | UICollectionView (sections) + horizontal UICollectionView rows |
| NativeImages / ImageStore / ImageCache | ImageLoader: memory (NSCache) + disk cache |
| res/drawable (74 Lucide icons) | the same icons, converted to vector assets |
| HomeModel / PickerModel / AddonsModel (JSON) | Swift structs parsed from the same JSON |
| Back button | edge swipe back, the same back handler |

## Phases

- [x] **0. Prep**: iOS builds manual-only; this plan.
- [x] **1. Foundation**: bridge (`homeSet`, `screenShow`, actions back); screen container over
  the web view (above the page, below its tab bar), one screen per page; the three models in
  Swift; image loader + caches; colours / fonts / helpers (Ui.kt); the 74 icons; web side:
  `nativeScreensApi()` so the page feeds iOS like Android.
- [x] **2. Browse screens**: hero (auto-advance), rows and cards (poster, Top 10, Continue
  Watching, tiles, logos, feature, lead, live, channel), header, chips, notes / messages / empty,
  search bar, "See all" grid, customize mode, Critics' Pick, Discovery Queue, award winners.
  Covers Home, Discover, Movies, Shows, Anime, Library, Search, See all, Collections, Awards.
  (Live TV's own card faces in rows come with phase 5; until then those rows show posters.)
- [x] **3. Title pages**: detail, seasons + episodes, list items / actions, person, episode
  detail, "Watch on".
- [x] **4. Overlays**: long-press menus (sheet), toast, prompt, full-screen steps (stage), top
  shade, Back / Watch together buttons, edge swipe back (the page's own Back handler, now
  registered on iOS too), stills full screen, row rename.
- [ ] **5. Calendar, Downloads page, Live TV** (live hero, channels, TV guide ruler and rows),
  **match pages** (match, versus, pitch).
- [ ] **6. Play picker** (pick, quality tiers, streams, drawer, diagnostics, panel, loader).
- [ ] **7. Addons pages** (cards, tiles, hero, community, categories, install, detail, info, doc).
- [ ] **8. Player and system**: downloads engine (background URLSession, pause / resume / retry,
  subtitles saved, offline playback) behind the same `dl*` calls; player extras (source list in
  the player, subtitle style: size / colour / background / position / delay, swipe gestures);
  `stremio://` links; open externally; save file; image cache size / clear.
- [ ] **9. Build and test** (Actions from here on): compile, fix, simulator screenshots of every
  screen in Arabic and English with real data, IPA.
- [ ] **10. Move to Harbor-App.**
