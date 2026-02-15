import argparse
import json
import os
import sys
import uuid

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.dirname(SCRIPT_DIR)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from database import db  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Migrate legacy playlists.json into user-scoped SQLite playlists.")
    parser.add_argument("--username", required=True, help="Target username that will own migrated playlists")
    parser.add_argument(
        "--playlists-file",
        default=os.path.join(BACKEND_DIR, "playlists.json"),
        help="Path to legacy playlists.json",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print migration summary without writing")
    args = parser.parse_args()

    user = db.get_user_by_username(args.username.strip())
    if not user:
        raise SystemExit(f"User '{args.username}' does not exist. Create it first.")

    if not os.path.isfile(args.playlists_file):
        raise SystemExit(f"Playlists file not found: {args.playlists_file}")

    with open(args.playlists_file, "r", encoding="utf-8") as f:
        playlists = json.load(f)

    migrated_playlists = 0
    migrated_songs = 0
    skipped_existing = 0

    for playlist_id, playlist in playlists.items():
        playlist_name = (playlist.get("name") or "").strip() or "Imported Playlist"
        existing = db.get_playlist(user["id"], playlist_id)
        if existing:
            skipped_existing += 1
            continue

        if args.dry_run:
            migrated_playlists += 1
            migrated_songs += len(playlist.get("songs", []))
            continue

        db.create_playlist(
            user_id=user["id"],
            name=playlist_name,
            playlist_id=playlist_id,
            cover_image=playlist.get("coverImage"),
        )
        migrated_playlists += 1

        for song in playlist.get("songs", []):
            song_payload = {
                "id": song.get("id") or str(uuid.uuid4()),
                "title": song.get("title") or "Unknown",
                "artist": song.get("artist") or "",
                "album": song.get("album") or "",
                "filename": song.get("filename") or "",
                "file_path": song.get("file_path") or "",
                "url": song.get("url") or "",
                "thumbnail": song.get("thumbnail") or "",
                "duration": song.get("duration") or 0.0,
            }
            db.add_song_to_playlist(user["id"], playlist_id, song_payload)
            migrated_songs += 1

    print(f"Target user: {user['username']} (id={user['id']})")
    print(f"Migrated playlists: {migrated_playlists}")
    print(f"Migrated songs: {migrated_songs}")
    print(f"Skipped existing playlists: {skipped_existing}")
    if args.dry_run:
        print("Dry run mode: no database writes performed.")


if __name__ == "__main__":
    main()
