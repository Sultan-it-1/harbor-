/**
 * SubSyncBar — شريط مزامنة الترجمة الحي
 * ينزل من أعلى الـ player مثل SubStyleBar
 * يتيح التحكم بتأخير/تقديم الترجمة أثناء تشغيل الفيديو مباشرة
 */
import { Check, RotateCcw, Timer, Type, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useT } from "@/lib/i18n";
import { closeSyncBar, useSyncBarOpen } from "@/lib/player/sub-sync";

const IDLE_MS = 12000;
const round = (v: number) => Math.round(v * 100) / 100;

type Target = "primary" | "secondary";

type Props = {
  delaySec: number;
  onDelay: (sec: number) => void;
  onEnterSync?: (target: Target) => void;
  syncAvailable?: boolean;
  /** The second subtitle, when one is on: the bar then works on the one picked in its
   *  First/Second switch. */
  second?: { delaySec: number; onDelay: (sec: number) => void; syncAvailable: boolean } | null;
};

export function SubSyncBar({ delaySec, onDelay, onEnterSync, syncAvailable, second }: Props) {

  const t = useT();
  const open = useSyncBarOpen();
  const [target, setTarget] = useState<Target>("primary");
  const [localDelay, setLocalDelay] = useState(delaySec);
  const savedRef = useRef(delaySec);
  // The second subtitle's delay when the bar opened, for Discard.
  const savedSecondRef = useRef(second?.delaySec ?? 0);
  const secondRef = useRef(second);
  secondRef.current = second;
  const onSecond = target === "secondary" && !!second;

  // Sync external delay into local state when bar opens
  useEffect(() => {
    if (open) {
      setTarget("primary");
      setLocalDelay(delaySec);
      savedRef.current = delaySec;
      savedSecondRef.current = secondRef.current?.delaySec ?? 0;
    }
  }, [open]);

  // The second subtitle went away while the bar was on it: back to the first.
  useEffect(() => {
    if (!second && target === "secondary") {
      setTarget("primary");
      setLocalDelay(delaySec);
    }
  }, [second, target, delaySec]);

  const pickTarget = (next: Target) => {
    if (next === target) return;
    setTarget(next);
    setLocalDelay(next === "secondary" ? (second?.delaySec ?? 0) : delaySec);
  };

  // Auto-close after idle
  useEffect(() => {
    if (!open) return;
    let timer = window.setTimeout(closeSyncBar, IDLE_MS);
    const bump = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(closeSyncBar, IDLE_MS);
    };
    window.addEventListener("pointermove", bump);
    window.addEventListener("pointerdown", bump);
    window.addEventListener("keydown", bump);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("pointermove", bump);
      window.removeEventListener("pointerdown", bump);
      window.removeEventListener("keydown", bump);
    };
  }, [open]);

  // Escape to close
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeSyncBar();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  // Apply delay to player live
  const applyDelay = (sec: number) => {
    const v = round(sec);
    setLocalDelay(v);
    if (onSecond) second?.onDelay(v);
    else onDelay(v);
  };

  // Save = just close (delay is already applied live)
  const handleSave = () => {
    if (onSecond) savedSecondRef.current = localDelay;
    else savedRef.current = localDelay;
    closeSyncBar();
  };

  // Discard = restore saved value (for both subtitles when there are two)
  const handleDiscard = () => {
    onDelay(round(savedRef.current));
    if (second && round(second.delaySec) !== round(savedSecondRef.current)) {
      second.onDelay(round(savedSecondRef.current));
    }
    setLocalDelay(onSecond ? savedSecondRef.current : savedRef.current);
    closeSyncBar();
  };

  const savedForTarget = onSecond ? savedSecondRef.current : savedRef.current;
  const otherDirty = onSecond
    ? round(delaySec) !== round(savedRef.current)
    : !!second && round(second.delaySec) !== round(savedSecondRef.current);
  const isDirty = round(localDelay) !== round(savedForTarget) || otherDirty;
  const isNonZero = localDelay !== 0;
  const textSyncOk = onSecond ? second?.syncAvailable === true : !!syncAvailable;

  if (!open) return null;

  return (
    <div className="pointer-events-none absolute inset-x-0 top-0 z-30 flex justify-center px-6 pt-[68px] animate-in fade-in slide-in-from-top-2 duration-300">
      <div
        role="toolbar"
        aria-label={t("Subtitle sync")}
        className="pointer-events-auto flex items-stretch gap-2.5 rounded-[16px] border border-edge bg-elevated/95 px-2.5 py-2 shadow-[0_24px_64px_rgba(0,0,0,0.8)] backdrop-blur-2xl"
      >
        {/* Left Side: Icon & Text Sync (Fixed width to center the middle section) */}
        <div className="flex w-[240px] items-center gap-1.5">
          {second ? (
            // Two subtitles: which one the bar (and text sync) works on.
            <div
              role="radiogroup"
              aria-label={t("Subtitle sync")}
              className="flex h-10 items-center gap-0.5 rounded-xl bg-raised p-[3px]"
            >
              <Timer size={15} strokeWidth={2} className="mx-1.5 shrink-0 text-ink-muted" />
              {(["primary", "secondary"] as const).map((k) => (
                <button
                  key={k}
                  type="button"
                  role="radio"
                  aria-checked={target === k}
                  onClick={() => pickTarget(k)}
                  className={`flex h-full items-center rounded-[9px] px-2.5 text-[12.5px] font-semibold transition-colors ${
                    target === k ? "bg-elevated text-ink ring-1 ring-edge" : "text-ink-muted hover:text-ink"
                  }`}
                >
                  {k === "primary" ? t("First") : t("Second")}
                </button>
              ))}
            </div>
          ) : (
            <div className="flex h-10 items-center gap-2 rounded-xl bg-raised px-3.5">
              <Timer size={16} strokeWidth={2} className="text-ink-muted" />
              <span className="text-[13px] font-semibold text-ink-muted">{t("Sync")}</span>
            </div>
          )}
          
          {onEnterSync && (
            <button
              type="button"
              onClick={() => {
                closeSyncBar();
                onEnterSync(onSecond ? "secondary" : "primary");
              }}
              disabled={!textSyncOk}
              title={textSyncOk ? t("Sync subtitles via text") : t("Text sync unavailable for embedded tracks")}
              aria-label={t("Sync via text")}
              className={`flex h-10 items-center gap-2 rounded-xl px-3.5 text-[13px] font-semibold transition-all ${
                textSyncOk
                  ? "bg-raised text-ink-muted hover:bg-elevated hover:text-ink active:scale-95"
                  : "bg-raised/40 opacity-60 cursor-not-allowed text-ink-subtle/50"
              }`}
            >
              <Type size={15} strokeWidth={2} />
              <span className="hidden lg:inline">{t("Text Sync")}</span>
            </button>
          )}
        </div>

        {/* Center Side: Sync Controls */}
        <div className="flex items-center gap-[2px] rounded-xl bg-raised p-[2px] shadow-inner">
          <StepBtn
            label="−0.5s"
            onClick={() => applyDelay(localDelay - 0.5)}
            wide
          />
          <StepBtn
            label="−0.1s"
            onClick={() => applyDelay(localDelay - 0.1)}
          />
          
          <div className="mx-1.5 flex h-10 w-[96px] items-center justify-center rounded-lg bg-elevated">
            <DelayDisplay value={localDelay} nonZero={isNonZero} onReset={() => applyDelay(0)} />
          </div>

          <StepBtn
            label="+0.1s"
            onClick={() => applyDelay(localDelay + 0.1)}
          />
          <StepBtn
            label="+0.5s"
            onClick={() => applyDelay(localDelay + 0.5)}
            wide
          />
        </div>

        {/* Right Side: Save & Discard (Fixed width to match left side) */}
        <div className="flex w-[240px] items-center justify-end gap-1.5">
          {isDirty && (
            <button
              type="button"
              onClick={handleDiscard}
              title={t("Discard changes")}
              aria-label={t("Discard changes")}
              className="flex h-10 w-10 items-center justify-center rounded-xl text-ink-muted transition-colors hover:bg-raised hover:text-danger active:scale-95"
            >
              <RotateCcw size={16} strokeWidth={2.2} />
            </button>
          )}

          <button
            type="button"
            onClick={handleSave}
            aria-label={t("Save")}
            className="flex h-10 items-center gap-1.5 rounded-xl bg-accent px-4 text-[13px] font-semibold text-canvas transition-all hover:brightness-110 active:scale-95"
          >
            <Check size={16} strokeWidth={2.6} />
            {t("Done")}
          </button>

          <button
            type="button"
            onClick={closeSyncBar}
            aria-label={t("Close")}
            className="ms-1 flex h-10 w-10 items-center justify-center rounded-xl text-ink-muted transition-colors hover:bg-raised hover:text-ink active:scale-95"
          >
            <X size={18} strokeWidth={2.2} />
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function StepBtn({
  label,
  onClick,
  wide,
}: {
  label: string;
  onClick: () => void;
  wide?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`flex h-[36px] items-center justify-center rounded-[10px] font-mono text-[13px] font-bold tabular-nums text-ink-muted transition-colors hover:bg-elevated hover:text-ink active:scale-95 ${
        wide ? "w-14" : "w-12"
      }`}
    >
      {label}
    </button>
  );
}

function DelayDisplay({
  value,
  nonZero,
  onReset,
}: {
  value: number;
  nonZero: boolean;
  onReset: () => void;
}) {
  const t = useT();
  return (
    <div className="relative flex h-full w-full items-center justify-center">
      <span
        className={`text-center font-mono text-[15px] font-bold tabular-nums transition-colors ${
          nonZero ? "text-accent" : "text-ink-subtle"
        }`}
      >
        {value >= 0 ? "+" : ""}
        {value.toFixed(2)}s
      </span>
      {nonZero && (
        <button
          type="button"
          onClick={onReset}
          aria-label={t("Reset sync")}
          title={t("Reset to 0")}
          className="absolute -end-2 -top-2 flex h-5 w-5 items-center justify-center rounded-full bg-raised text-ink-subtle shadow-sm transition-colors hover:bg-elevated hover:text-danger"
        >
          <RotateCcw size={10} strokeWidth={2.5} />
        </button>
      )}
    </div>
  );
}
