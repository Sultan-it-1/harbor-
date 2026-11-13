import { useEffect, useRef } from "react";

/** How long the left button stays down on the video before the press counts as a hold. */
const HOLD_DELAY_MS = 400;

type Press = {
  /** Stops listening for this press, with no click and no hold left on. */
  finish: () => void;
  /** Ends a hold, or keeps one from starting, and leaves a plain press alone. */
  abortHold: () => void;
};

export function DragClickStage(props: {
  drawMode: boolean;
  pipMode: boolean;
  onClick: () => void;
  onDoubleClick: () => void;
  onWheelVolume?: (deltaY: number) => void;
  onSeekStep?: (delta: number) => void;
  /** Holding the left button on the video plays faster until it is let go. */
  onHoldStart?: () => void;
  onHoldEnd?: () => void;
  /** Asked once the button has been down long enough. False (not playing, seeking, ...) keeps
   *  the press a plain click. */
  canHold?: () => boolean;
}) {
  const { drawMode, pipMode, onClick, onDoubleClick, onWheelVolume, onSeekStep } = props;
  // A press can outlive the render it started in, so it reads the newest values from here.
  const latest = useRef(props);
  latest.current = props;
  // Whether the last two presses were holds: a double-click made with a hold is not one.
  const heldRef = useRef({ held: false, prevHeld: false });
  const pressRef = useRef<Press | null>(null);

  // Picture-in-picture or drawing turned on mid-hold: back to the normal speed.
  useEffect(() => {
    if (drawMode || pipMode) pressRef.current?.abortHold();
  }, [drawMode, pipMode]);
  // The player closed mid-press: nothing of it may run afterwards.
  useEffect(() => () => pressRef.current?.finish(), []);

  return (
    <div
      className="pointer-events-auto absolute inset-0 z-[3]"
      onWheel={(e) => {
        if (drawMode || pipMode) return;
        if (e.ctrlKey || e.metaKey) return;
        onWheelVolume?.(e.deltaY);
      }}
      onMouseDown={(e) => {
        if (e.target !== e.currentTarget) return;
        if (drawMode || pipMode) return;
        if (e.button !== 0) return;
        // A press whose button-up never reached us is over now.
        pressRef.current?.finish();
        const held = heldRef.current;
        held.prevHeld = held.held;
        held.held = false;
        const startX = e.clientX;
        const startY = e.clientY;
        const startTime = Date.now();
        let dragStarted = false;
        let holding = false;
        let holdTimer: number | null = null;
        const cancelTimer = () => {
          if (holdTimer != null) {
            window.clearTimeout(holdTimer);
            holdTimer = null;
          }
        };
        const finish = () => {
          cancelTimer();
          window.removeEventListener("mousemove", onMove);
          window.removeEventListener("mouseup", onUp);
          window.removeEventListener("blur", onBlur);
          if (pressRef.current === press) pressRef.current = null;
          if (holding) {
            holding = false;
            latest.current.onHoldEnd?.();
          }
        };
        const abortHold = () => {
          if (holding) finish();
          else cancelTimer();
        };
        const onMove = (ev: MouseEvent) => {
          if (holding) {
            // The button came up outside the window, where its mouseup didn't reach us.
            if ((ev.buttons & 1) === 0) finish();
            // No window dragging while the video plays faster.
            return;
          }
          if (dragStarted) return;
          if (Date.now() - startTime < 150) return;
          const dx = Math.abs(ev.clientX - startX);
          const dy = Math.abs(ev.clientY - startY);
          if (dx > 8 || dy > 8) {
            dragStarted = true;
            finish();
            import("@tauri-apps/api/window")
              .then(({ getCurrentWindow }) => getCurrentWindow().startDragging())
              .catch(() => {});
          }
        };
        const onUp = () => {
          const wasHolding = holding;
          finish();
          // A hold sped the video up; it is not also a click (no play/pause).
          if (!dragStarted && !wasHolding) onClick();
        };
        // Switching to another app mid-hold ends it (its button-up goes to that app).
        // A plain press keeps working as before.
        const onBlur = () => abortHold();
        const press: Press = { finish, abortHold };
        pressRef.current = press;
        if (latest.current.onHoldStart) {
          holdTimer = window.setTimeout(() => {
            holdTimer = null;
            const p = latest.current;
            if (dragStarted || p.drawMode || p.pipMode) return;
            if (p.canHold && !p.canHold()) return;
            holding = true;
            held.held = true;
            p.onHoldStart?.();
          }, HOLD_DELAY_MS);
        }
        window.addEventListener("mousemove", onMove);
        window.addEventListener("mouseup", onUp);
        window.addEventListener("blur", onBlur);
      }}
      onDoubleClick={(e) => {
        if (e.target !== e.currentTarget) return;
        if (drawMode || pipMode) return;
        // One of the two presses was a hold, which sped the video up instead of clicking.
        if (heldRef.current.held || heldRef.current.prevHeld) return;

        const isMobileOrTouch = window.innerWidth <= 768 || navigator.maxTouchPoints > 0;
        if (isMobileOrTouch && onSeekStep) {
          const third = window.innerWidth / 3;
          if (e.clientX < third) {
            onSeekStep(-10);
            return;
          } else if (e.clientX > third * 2) {
            onSeekStep(10);
            return;
          }
        }

        onDoubleClick();
      }}
    />
  );
}
