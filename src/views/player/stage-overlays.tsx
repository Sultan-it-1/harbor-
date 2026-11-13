import { Anime4kIndicator } from "@/components/player/anime4k-indicator";
import { SvpIndicator } from "@/components/player/svp-indicator";
import { StatsOverlay } from "@/components/player/stats-overlay";
import { SubStyleBar } from "@/components/player/sub-style-bar";
import { SubSyncBar } from "@/components/player/sub-sync-bar";
import { DualSubtitles, secondPlacementMode, useTallPlayerArea } from "@/components/player/dual-subtitles";
import type { PlayerSnapshot, TrackInfo } from "@/lib/player/bridge";
import { useSettings } from "@/lib/settings";
import { useT } from "@/lib/i18n";
import type { SyncTarget } from "./hooks/use-text-sync";

// Guided text sync reads the subtitle file, so it needs an external subtitle.
function textSyncable(t: TrackInfo | undefined): boolean {
  if (!t) return false;
  return t.external || !!t.url;
}

export function StageOverlays({
  snap,
  engine,
  pipMode,
  subShowInPip,
  subAssNative,
  firstSubNative,
  secondSubNative,
  syncTarget,
  showStats,
  holdSpeedActive,
  videoFillPill,
  subDropToast,
  onSubDelay,
  onSecondSubDelay,
  onEnterSync,
  chromeVisible,
}: {
  snap: PlayerSnapshot;
  engine: "html5" | "mpv";
  pipMode: boolean;
  subShowInPip: boolean;
  subAssNative: boolean;
  /** The video player draws the first subtitle itself (styled ASS, picture subtitles, HDR). */
  firstSubNative: boolean;
  /** The video player draws the second subtitle itself (the page can't show over the HDR picture). */
  secondSubNative: boolean;
  /** Which subtitle guided text sync is working on (the other one is hidden meanwhile). */
  syncTarget: SyncTarget | null;
  showStats: boolean;
  holdSpeedActive: boolean;
  videoFillPill: string | null;
  subDropToast: string | null;
  onSubDelay: (sec: number) => void;
  onSecondSubDelay?: (sec: number) => void;
  onEnterSync?: (target: SyncTarget) => void;
  chromeVisible: boolean;
}) {
  const t = useT();
  const { settings } = useSettings();
  const tall = useTallPlayerArea();
  const secondTrack = snap.secondarySubTrackId
    ? snap.subtitleTracks.find((x) => x.secondarySelected)
    : undefined;
  const hasSecond = !!snap.secondarySubTrackId;
  const secondOnPage = hasSecond && !secondSubNative;
  const firstTrack = snap.subtitleTracks.find((x) => x.selected);
  return (
    <>
      <DualSubtitles
        snap={snap}
        pipMode={pipMode}
        showFirst={(!pipMode || subShowInPip) && !subAssNative && syncTarget !== "secondary"}
        // Picture-in-picture shows only the first subtitle; the second comes back after.
        showSecond={secondOnPage && !pipMode && syncTarget !== "primary"}
        firstDrawnByPlayer={firstSubNative}
        portrait={tall}
      />
      {showStats && !pipMode && <StatsOverlay snap={snap} engine={engine} />}
      {!pipMode && <Anime4kIndicator engine={engine} chromeVisible={chromeVisible} />}
      {!pipMode && <SvpIndicator engine={engine} chromeVisible={chromeVisible} />}
      {holdSpeedActive && !pipMode && (
        <div className="pointer-events-none absolute left-1/2 top-8 z-30 flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-canvas/85 px-3.5 py-1.5 text-[13px] font-semibold text-ink backdrop-blur-md">
          {snap.rate}x
          <span className="font-normal text-ink-muted">{t("speed")}</span>
        </div>
      )}
      {videoFillPill && !holdSpeedActive && !pipMode && (
        <div className="pointer-events-none absolute left-1/2 top-8 z-30 -translate-x-1/2 rounded-full bg-canvas/85 px-3.5 py-1.5 text-[13px] font-semibold text-ink backdrop-blur-md">
          {videoFillPill}
        </div>
      )}
      {subDropToast && !pipMode && (
        <div className="pointer-events-none absolute bottom-28 left-1/2 z-30 -translate-x-1/2 rounded-full bg-canvas/90 px-4 py-2 text-[13px] font-medium text-ink backdrop-blur-md">
          {subDropToast}
        </div>
      )}
      {!pipMode && (
        <SubStyleBar
          second={
            secondOnPage
              ? { placement: secondPlacementMode(settings.sub2Layout, tall, firstSubNative) }
              : null
          }
        />
      )}
      {!pipMode && (
        <SubSyncBar
          delaySec={snap.subDelaySec}
          onDelay={onSubDelay}
          onEnterSync={onEnterSync}
          syncAvailable={textSyncable(firstTrack)}
          second={
            hasSecond && onSecondSubDelay
              ? {
                  delaySec: snap.secondarySubDelaySec,
                  onDelay: onSecondSubDelay,
                  syncAvailable: textSyncable(secondTrack),
                }
              : null
          }
        />
      )}
    </>
  );
}
