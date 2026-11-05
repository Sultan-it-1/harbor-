import { ANILIST_GRAPHQL_URL } from "./config";

class AnilistApiError extends Error {
  constructor(
    public status: number,
    public body: string,
  ) {
    super(`AniList HTTP ${status}: ${body.slice(0, 200)}`);
  }
}

type GraphqlResponse<T> = { data?: T; errors?: Array<{ message: string }> };

function doFetch(query: string, variables: Record<string, unknown>): Promise<Response> {
  return fetch(ANILIST_GRAPHQL_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ query, variables }),
  });
}

export async function anilistRequest<T>(
  query: string,
  variables: Record<string, unknown> = {},
): Promise<T> {
  let res = await doFetch(query, variables);

  if (res.status === 429) {
    const retry = Number(res.headers.get("retry-after") ?? "1");
    const waitMs = Math.min(Math.max(retry, 1), 30) * 1000;
    await new Promise((r) => setTimeout(r, waitMs));
    res = await doFetch(query, variables);
  }

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new AnilistApiError(res.status, body);
  }

  const json = (await res.json()) as GraphqlResponse<T>;
  if (json.errors && json.errors.length > 0) {
    throw new AnilistApiError(200, json.errors.map((e) => e.message).join("; "));
  }
  return json.data as T;
}
