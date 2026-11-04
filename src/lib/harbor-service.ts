// Harbor's own servers (harbor.site: bug reports, the theme store, AniList sign-in, the public
// Together relay) announced their shutdown. Where JSON is expected they now answer with a
// "Harbor is Sunsetting" web page and status 200, which the app used to take as success
// ("report sent") or choke on (res.json() on HTML). Anything that isn't a JSON answer is treated
// as the service being gone, and the user is told so.

export class HarborServiceGone extends Error {
  constructor(message: string) {
    super(message);
    this.name = "HarborServiceGone";
  }
}

export function isJsonResponse(res: Response): boolean {
  return /\bjson\b/i.test(res.headers.get("content-type") ?? "");
}

/** The JSON body, or a HarborServiceGone with [goneMessage] when the answer isn't JSON. */
export async function harborJson<T>(res: Response, goneMessage: string): Promise<T> {
  if (!isJsonResponse(res)) throw new HarborServiceGone(goneMessage);
  return (await res.json()) as T;
}

export const REPORTS_GONE = "Harbor's report server has shut down, so this report wasn't sent.";
export const THEME_STORE_GONE = "The community theme store has shut down.";
export const ANILIST_SIGNIN_GONE = "AniList sign-in went through Harbor's server, which has shut down, so it can't work right now.";
