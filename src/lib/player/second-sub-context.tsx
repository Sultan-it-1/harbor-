import { createContext, useContext } from "react";

/** What the subtitle menu (and the sync bar) call to change the second subtitle. Given by the
 *  player only where a second subtitle is possible (the desktop player, mpv); null elsewhere,
 *  and the menu then has no "Second subtitle" part. */
export type SecondSubControls = {
  onSelect: (id: string | null) => void;
  /** Adds a subtitle file or addon subtitle as the second one; false when it didn't load. */
  onAdd: (url: string, lang?: string, title?: string) => Promise<boolean>;
  onDelay: (sec: number) => void;
};

const SecondSubContext = createContext<SecondSubControls | null>(null);

export const SecondSubProvider = SecondSubContext.Provider;

export function useSecondSubControls(): SecondSubControls | null {
  return useContext(SecondSubContext);
}
