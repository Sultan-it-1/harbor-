import { invoke } from "@tauri-apps/api/core";
import { isWeb, isWindowsDesktop } from "@/lib/platform";

/** "system" is the system's default app for the address (the Windows default on Windows). */
export type ExternalPlayerId = "vlc" | "mpv" | "potplayer" | "mpc-hc" | "system";

export type ExternalPlayer = {
  id: ExternalPlayerId;
  /** Product name, shown as is (not translated). Empty for "system". */
  name: string;
  /** Where the program was found, shown as a hint. */
  path?: string;
};

export type ExternalOpenRequest = {
  player: ExternalPlayerId;
  url: string;
  title?: string;
  /** Where to start, when the player supports it. Left out for live streams. */
  startSec?: number;
  headers?: Record<string, string>;
};

const LAST_KEY = "harbor.external-player.last";

export const SYSTEM_PLAYER: ExternalPlayer = { id: "system", name: "" };

/** Starting another app needs the desktop shell: the web build and the Android app have none. */
export function externalPlayersSupported(): boolean {
  return !isWeb();
}

/** Label for the system's default app: Windows users know it as the Windows default. */
export function systemPlayerLabel(t: (key: string) => string): string {
  return isWindowsDesktop() ? t("Windows default") : t("System default");
}

export function externalPlayerLabel(p: ExternalPlayer, t: (key: string) => string): string {
  return p.id === "system" ? systemPlayerLabel(t) : p.name;
}

let lastFound: ExternalPlayer[] | null = null;

/** The last list found, so a menu can show it at once while it looks again. */
export function knownExternalPlayers(): ExternalPlayer[] | null {
  return lastFound ? [...lastFound, SYSTEM_PLAYER] : null;
}

/** Installed players, then the system's default app, which is always there. */
export async function listExternalPlayers(): Promise<ExternalPlayer[]> {
  try {
    lastFound = await invoke<ExternalPlayer[]>("external_players_list");
  } catch {
    lastFound = lastFound ?? [];
  }
  return [...lastFound, SYSTEM_PLAYER];
}

export async function openInExternalPlayer(req: ExternalOpenRequest): Promise<void> {
  await invoke("external_player_open", { args: req });
}

export function readLastExternalPlayer(): ExternalPlayerId | null {
  try {
    const v = localStorage.getItem(LAST_KEY);
    return v === "vlc" || v === "mpv" || v === "potplayer" || v === "mpc-hc" || v === "system" ? v : null;
  } catch {
    return null;
  }
}

export function rememberExternalPlayer(id: ExternalPlayerId): void {
  try {
    localStorage.setItem(LAST_KEY, id);
  } catch {
    /* storage full or blocked: only the "last used" mark is lost */
  }
}
