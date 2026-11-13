import type { Settings, SubLook } from "@/lib/settings";

/** How high a subtitle can be moved, in percent of the picture from the bottom. "Top" sets it
 *  here; any higher and a two-line subtitle would run off the top of the picture. */
export const SUB_MARGIN_MAX = 80;

/** The second subtitle's colour until the viewer picks one. */
export const SECOND_SUB_COLOR = "#FFE14D";

export type FullSubLook = Required<SubLook>;

const LOOK_KEYS: Array<keyof FullSubLook> = [
  "subFontSize",
  "subFontColor",
  "subBorderColor",
  "subBorderSize",
  "subMarginY",
  "subAlignX",
  "subStyle",
  "subFontFamily",
  "subBold",
  "subBoxOpacity",
  "subBoxColor",
  "subOpacity",
  "subLineSpacing",
];

export function firstSubLook(s: Settings): FullSubLook {
  return {
    subFontSize: s.subFontSize,
    subFontColor: s.subFontColor,
    subBorderColor: s.subBorderColor,
    subBorderSize: s.subBorderSize,
    subMarginY: s.subMarginY,
    subAlignX: s.subAlignX,
    subStyle: s.subStyle,
    subFontFamily: s.subFontFamily,
    subBold: s.subBold,
    subBoxOpacity: s.subBoxOpacity,
    subBoxColor: s.subBoxColor,
    subOpacity: s.subOpacity,
    subLineSpacing: s.subLineSpacing,
  };
}

/** The second subtitle's look: what the viewer set for it, and the first subtitle's look for
 *  the rest, a little smaller (90%) and yellow so the two are easy to tell apart. */
export function resolveSecondLook(s: Settings): FullSubLook {
  const first = firstSubLook(s);
  const own = s.sub2Style ?? {};
  const out: FullSubLook = {
    ...first,
    subFontSize: Math.round((Number(first.subFontSize) || 32) * 0.9),
    subFontColor: SECOND_SUB_COLOR,
  };
  for (const k of LOOK_KEYS) {
    const v = own[k];
    if (v !== undefined && v !== null) (out as Record<string, unknown>)[k] = v;
  }
  return out;
}

/** Only the look keys of a settings change, for storing them as the second subtitle's own. */
export function pickLookKeys(patch: Partial<Settings>): SubLook {
  const out: SubLook = {};
  for (const k of LOOK_KEYS) {
    if (k in patch) (out as Record<string, unknown>)[k] = (patch as Record<string, unknown>)[k];
  }
  return out;
}

// Languages written right to left, as two- or three-letter codes and as the names addons use.
const RTL_LANGS = new Set([
  "ar", "ara", "he", "heb", "iw", "fa", "fas", "per", "ur", "urd", "ps", "pus", "ckb",
  "yi", "yid", "ji", "dv", "div", "ug", "uig", "sd", "snd",
  "arabic", "hebrew", "persian", "farsi", "urdu", "pashto", "sorani", "central kurdish",
  "yiddish", "dhivehi", "divehi", "maldivian", "uyghur", "uighur", "sindhi",
]);
// Script tags (as in "ks-Arab") that are written right to left.
const RTL_SCRIPTS = new Set(["arab", "hebr", "thaa"]);

/** Whether a subtitle's language is written right to left (Arabic, Hebrew, Persian, Urdu…).
 *  A script tag decides when there is one: "pa-Arab" is, "sd-Deva" is not. */
export function isRtlLanguage(code?: string | null): boolean {
  const raw = (code ?? "").trim().toLowerCase();
  if (!raw) return false;
  if (RTL_LANGS.has(raw)) return true;
  const parts = raw.split(/[-_]/);
  const script = parts.slice(1).find((p) => p.length === 4 && /^[a-z]+$/.test(p));
  if (script) return RTL_SCRIPTS.has(script);
  return RTL_LANGS.has(parts[0]);
}

/** Side by side: whether the first subtitle takes the right half. When exactly one of the two
 *  is a right-to-left language it goes on the right (where a reader of it starts); otherwise
 *  the first is on the left. "Swap sides" flips that. */
export function firstSubOnRight(
  firstLang: string | undefined,
  secondLang: string | undefined,
  swap: boolean,
): boolean {
  const firstRtl = isRtlLanguage(firstLang);
  const secondRtl = isRtlLanguage(secondLang);
  const onRight = firstRtl !== secondRtl ? firstRtl : false;
  return swap ? !onRight : onRight;
}
