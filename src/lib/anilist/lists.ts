import { AnilistApiError, anilistRequest } from "./client";
import type { AnilistListGroup, AnilistMediaEntry, MediaListStatus } from "./types";
import { validateAnilistSession } from "./validate";

const COLLECTION_QUERY = `query ($userId: Int) {
  MediaListCollection(userId: $userId, type: ANIME) {
    lists {
      status
      isCustomList
      entries {
        id
        status
        progress
        score
        media {
          id
          idMal
          title { romaji english native userPreferred }
          coverImage { extraLarge large medium }
          bannerImage
          format
          episodes
          averageScore
          seasonYear
        }
      }
    }
  }
}`;

type RawGroup = {
  status: MediaListStatus | null;
  isCustomList: boolean;
  entries: AnilistMediaEntry[];
};

type CollectionResponse = { MediaListCollection: { lists: RawGroup[] } | null };

export async function fetchMediaListCollection(userId: number): Promise<AnilistListGroup[]> {
  const data = await anilistRequest<CollectionResponse>(COLLECTION_QUERY, { userId }).catch((e) => {
    if (e instanceof AnilistApiError && e.status === 401) void validateAnilistSession();
    return null;
  });
  const lists = data?.MediaListCollection?.lists ?? [];
  const byStatus = new Map<MediaListStatus, AnilistMediaEntry[]>();
  const seen = new Set<number>();
  for (const group of lists) {
    if (group.isCustomList || !group.status) continue;
    const bucket = byStatus.get(group.status) ?? [];
    for (const entry of group.entries) {
      if (seen.has(entry.media.id)) continue;
      seen.add(entry.media.id);
      bucket.push(entry);
    }
    byStatus.set(group.status, bucket);
  }
  return Array.from(byStatus.entries()).map(([status, entries]) => ({ status, entries }));
}
