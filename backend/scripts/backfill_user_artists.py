"""
Backfill user_artists table from existing history.
Run once to populate Spotify artist IDs for users with listening history.
"""
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.dirname(SCRIPT_DIR)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from database import db  # noqa: E402
from spotify_service import spotify_service  # noqa: E402


def main():
    user_ids = db.get_user_ids_with_history()
    if not user_ids:
        print("No users with history found.")
        return

    total_upserted = 0
    for user_id in user_ids:
        top_artists = db.get_top_artists(user_id, limit=30)
        for artist_row in top_artists:
            artist_name = artist_row["artist"]
            track_info = spotify_service.search_track("", artist_name)
            if track_info and track_info.get("artist_id"):
                db.upsert_user_artist(
                    user_id,
                    track_info.get("artist", artist_name),
                    track_info.get("artist_id"),
                    track_info.get("thumbnail"),
                )
                total_upserted += 1
                print(f"  Backfilled: {artist_name} -> {track_info['artist_id']}")

    print(f"Backfill complete. Upserted {total_upserted} artist mappings.")


if __name__ == "__main__":
    main()
