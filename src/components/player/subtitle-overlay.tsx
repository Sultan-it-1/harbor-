import type { Ref } from "react";
import { useSettings } from "@/lib/settings";
import { SUB_MARGIN_MAX, type FullSubLook } from "@/lib/player/dual-subs";

/** Where a subtitle sits. "bottom" is the usual place (its own distance from the bottom).
 *  The others are used when a second subtitle shows with the first one. */
export type SubPlacement =
  | { kind: "bottom" }
  | { kind: "above"; bottom: string }
  | { kind: "below"; top: string }
  | { kind: "top" }
  | { kind: "half"; side: "left" | "right" };

type Props = {
  text: string;
  startSec: number;
  scale?: number;
  /** The look to draw with; the first subtitle's settings when left out. */
  look?: FullSubLook;
  placement?: SubPlacement;
  boxRef?: Ref<HTMLDivElement>;
};

export function SubtitleOverlay({ text, startSec, scale = 1, look, placement, boxRef }: Props) {
  const { settings } = useSettings();
  if (!text) return null;

  const s = look ?? settings;
  const fontSize = Math.round(clamp(s.subFontSize, 16, 120) * scale);
  const marginY = clamp(s.subMarginY, 0, SUB_MARGIN_MAX);
  const fontColor = s.subFontColor || "#FFFFFF";
  const align = s.subAlignX || "center";
  const family = fontFamilyFor(s.subFontFamily);
  const style = s.subStyle ?? "shadow";
  const lines = text.split("\n");

  const justify = align === "left" ? "justify-start" : align === "right" ? "justify-end" : "justify-center";

  const baseTextStyle: React.CSSProperties = {
    color: fontColor,
    fontFamily: family,
    fontWeight: s.subBold ? 700 : 400,
    fontSize: `${fontSize}px`,
    lineHeight: 1.2,
    letterSpacing: `${(-0.005 + (s.subLineSpacing ?? 0) * 0.06).toFixed(3)}em`,
    whiteSpace: "pre-wrap",
    textAlign: align as "left" | "center" | "right",
  };

  if (style === "outline") {
    const borderSize = clamp(s.subBorderSize, 1, 6) || 2;
    const borderColor = s.subBorderColor || "#000000";
    baseTextStyle.textShadow = buildOutline(borderColor, borderSize);
  } else if (style === "shadow") {
    baseTextStyle.textShadow =
      "0 1px 2px rgba(0,0,0,0.95), 0 2px 6px rgba(0,0,0,0.85), 0 0 18px rgba(0,0,0,0.55)";
  }

  const boxOpacity = clamp(s.subBoxOpacity, 0, 1);
  const boxRgb = hexToRgb(s.subBoxColor || "#000000");
  const boxStyle: React.CSSProperties | undefined =
    style === "box"
      ? {
          backgroundColor: `rgba(${boxRgb.r}, ${boxRgb.g}, ${boxRgb.b}, ${boxOpacity})`,
          padding: `${Math.round(fontSize * 0.18)}px ${Math.round(fontSize * 0.5)}px`,
          borderRadius: `${Math.round(fontSize * 0.25)}px`,
          backdropFilter: "blur(2px)",
        }
      : undefined;

  const opacity = clamp(s.subOpacity ?? 1, 0.1, 1);

  const where = placement ?? { kind: "bottom" };
  const half = where.kind === "half";
  const rowStyle: React.CSSProperties =
    where.kind === "above"
      ? { bottom: where.bottom, opacity }
      : where.kind === "below"
        ? { top: where.top, opacity }
        : where.kind === "top"
          ? { top: "5%", opacity }
          : where.kind === "half"
            ? {
                bottom: `${marginY}%`,
                opacity,
                left: where.side === "left" ? 0 : "50%",
                right: where.side === "left" ? "50%" : 0,
              }
            : { bottom: `${marginY}%`, opacity };

  return (
    <div
      key={startSec}
      ref={boxRef}
      className={
        half
          ? `pointer-events-none absolute z-10 flex ${justify} px-[3%]`
          : `pointer-events-none absolute inset-x-0 z-10 flex ${justify} px-[6%]`
      }
      style={rowStyle}
    >
      <div className={half ? "max-w-full" : "max-w-[80%]"} style={boxStyle}>
        <div style={baseTextStyle}>
          {lines.map((line, i) => (
            <div key={i}>{line}</div>
          ))}
        </div>
      </div>
    </div>
  );
}

/** The height of one line of a subtitle in this look, box padding included: where a second
 *  subtitle sits above the first while the first has no line on screen. */
export function oneLineHeight(look: FullSubLook): number {
  const fontSize = Math.round(clamp(look.subFontSize, 16, 120));
  const pad = look.subStyle === "box" ? 2 * Math.round(fontSize * 0.18) : 0;
  return Math.round(fontSize * 1.2) + pad;
}

function fontFamilyFor(family: string | undefined): string {
  if (family?.startsWith("custom:")) {
    return `"harbor-font-${family.slice("custom:".length)}", "Inter", system-ui, sans-serif`;
  }
  switch (family) {
    case "system":
      return '-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif';
    case "serif":
      return '"Fraunces", Georgia, "Times New Roman", serif';
    case "rounded":
      return '"SF Pro Rounded", "Nunito", "Quicksand", system-ui, sans-serif';
    case "inter":
    default:
      return '"Inter", -apple-system, system-ui, sans-serif';
  }
}

function buildOutline(color: string, size: number): string {
  const offsets: [number, number][] = [];
  for (let dx = -size; dx <= size; dx++) {
    for (let dy = -size; dy <= size; dy++) {
      const r = Math.sqrt(dx * dx + dy * dy);
      if (r > size + 0.1 || r < 0.1) continue;
      offsets.push([dx, dy]);
    }
  }
  return offsets.map(([dx, dy]) => `${dx}px ${dy}px 0 ${color}`).join(", ");
}

function clamp(n: number, lo: number, hi: number): number {
  if (!Number.isFinite(n)) return lo;
  return Math.max(lo, Math.min(hi, n));
}

function hexToRgb(hex: string): { r: number; g: number; b: number } {
  const m = (hex || "").replace(/^#/, "");
  if (m.length !== 6) return { r: 0, g: 0, b: 0 };
  return {
    r: parseInt(m.slice(0, 2), 16) || 0,
    g: parseInt(m.slice(2, 4), 16) || 0,
    b: parseInt(m.slice(4, 6), 16) || 0,
  };
}
