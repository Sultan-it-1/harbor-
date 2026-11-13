import { LoaderCircle, SquareArrowOutUpRight } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useT } from "@/lib/i18n";
import {
  externalPlayerLabel,
  knownExternalPlayers,
  listExternalPlayers,
  readLastExternalPlayer,
  type ExternalPlayer,
  type ExternalPlayerId,
} from "@/lib/external-player";
import { Tooltip } from "./tooltip";

/**
 * "Open in another player": lists the media players installed on this computer and the
 * system's default app. The same menu serves both player layouts, in the top bar or the
 * bottom one, so it opens towards the middle of the screen from wherever the button is.
 */
export function ExternalPlayerMenu({
  onOpen,
  onOpenChange,
  stremio,
}: {
  onOpen: (player: ExternalPlayer) => void | Promise<void>;
  onOpenChange?: (open: boolean) => void;
  /** Stremio layout: its larger square buttons. */
  stremio?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [players, setPlayers] = useState<ExternalPlayer[] | null>(() => knownExternalPlayers());
  const [busy, setBusy] = useState<ExternalPlayerId | null>(null);
  const [atTop, setAtTop] = useState(false);
  const [onLeft, setOnLeft] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const onOpenChangeRef = useRef(onOpenChange);
  onOpenChangeRef.current = onOpenChange;
  const last = open ? readLastExternalPlayer() : null;

  useEffect(() => {
    onOpenChange?.(open);
  }, [open, onOpenChange]);
  // If the button goes away while the menu is open (the window got narrow), the player
  // must not keep its controls up for a menu nobody can see.
  useEffect(() => () => onOpenChangeRef.current?.(false), []);

  useLayoutEffect(() => {
    const r = wrap.current?.getBoundingClientRect();
    if (!r) return;
    setAtTop(r.top + r.height / 2 < window.innerHeight / 2);
    setOnLeft(r.left + r.width / 2 < window.innerWidth / 2);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    let alive = true;
    // Looked up again each time, so a player installed meanwhile shows up.
    void listExternalPlayers().then((list) => {
      if (alive) setPlayers(list);
    });
    const close = (e: MouseEvent) => {
      if (!wrap.current?.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener("mousedown", close);
    return () => {
      alive = false;
      window.removeEventListener("mousedown", close);
    };
  }, [open]);

  const pick = async (p: ExternalPlayer) => {
    if (busy) return;
    setBusy(p.id);
    try {
      await onOpen(p);
    } finally {
      setBusy(null);
      setOpen(false);
    }
  };

  const label = t("Open in another player");
  const triggerClass = stremio
    ? `pointer-events-auto flex h-16 w-16 items-center justify-center rounded-xl transition-colors duration-150 ${
        open ? "bg-white/[0.08] text-white" : "text-white/90 hover:bg-white/[0.05]"
      }`
    : `flex h-11 min-w-11 items-center justify-center rounded-full px-2 transition-[background-color,color] ${
        open ? "bg-white/22 text-white hover:bg-white/30" : "text-white/85 hover:bg-white/10 hover:text-white"
      }`;
  const onlySystem = players != null && players.every((p) => p.id === "system");
  // The player picked last time comes first, so opening there again is the top row.
  const ordered =
    players == null || last == null
      ? players
      : [...players.filter((p) => p.id === last), ...players.filter((p) => p.id !== last)];

  return (
    <div ref={wrap} className="relative">
      <Tooltip label={label} side={atTop ? "bottom" : "top"}>
        <button type="button" onClick={() => setOpen((o) => !o)} aria-label={label} className={triggerClass}>
          <SquareArrowOutUpRight size={stremio ? 26 : 21} strokeWidth={1.9} />
        </button>
      </Tooltip>
      {open && (
        <div
          className={`absolute z-30 w-[260px] max-w-[calc(100vw-32px)] overflow-hidden rounded-2xl border border-edge bg-elevated shadow-[0_24px_60px_-18px_rgba(0,0,0,0.8)] backdrop-blur-xl ${
            atTop ? "top-[calc(100%+10px)]" : "bottom-[calc(100%+10px)]"
          } ${onLeft ? "left-0" : "right-0"}`}
        >
          <div className="p-2">
            <div className="px-3 pb-1.5 pt-1 text-[10.5px] font-semibold uppercase tracking-[0.18em] text-ink-subtle">
              {label}
            </div>
            <div className="flex flex-col gap-0.5">
              {ordered == null ? (
                <div className="flex h-10 items-center gap-2 px-3 text-[13px] text-ink-subtle">
                  <LoaderCircle size={14} strokeWidth={2.2} className="animate-spin" />
                  {t("Looking for players…")}
                </div>
              ) : (
                ordered.map((p) => {
                  const isLast = p.id === last;
                  return (
                    <button
                      key={p.id}
                      type="button"
                      title={p.path}
                      disabled={busy != null}
                      onClick={() => void pick(p)}
                      className={`flex h-10 w-full items-center justify-between gap-3 rounded-lg px-3 text-start text-[14px] transition-colors disabled:cursor-default ${
                        isLast ? "bg-elevated text-ink ring-1 ring-edge" : "text-ink-muted hover:bg-canvas/55 hover:text-ink"
                      }`}
                    >
                      <span className={`truncate ${isLast ? "font-medium" : ""}`}>{externalPlayerLabel(p, t)}</span>
                      {busy === p.id ? (
                        <LoaderCircle size={14} strokeWidth={2.2} className="shrink-0 animate-spin text-ink-subtle" />
                      ) : isLast ? (
                        <span className="shrink-0 text-[10.5px] font-semibold uppercase tracking-[0.16em] text-ink-subtle">
                          {t("last used")}
                        </span>
                      ) : null}
                    </button>
                  );
                })
              )}
            </div>
            {onlySystem && (
              <p className="px-3 pb-1 pt-2 text-[12px] leading-snug text-ink-subtle">
                {t("No other player found. Install VLC or mpv and it shows up here.")}
              </p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
