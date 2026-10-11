"""Temporary UI review server; no project credentials or personal library.

Run with ``py backend/tests/demo_server.py`` and sign in with demo / demo-only.
The database is temporary and is deleted when the server stops. External music
services are disabled; this fixture validates navigation and library UI only.
"""

import uvicorn

from isolated_backend import isolated_backend


if __name__ == "__main__":
    with isolated_backend() as (api, root):
        from auth_utils import hash_password

        user = api.db.create_user("demo", hash_password("demo-only"))
        api.db.update_user_profile(user["id"], "demo", "Temporary UI review account")
        for name, tracks in (
            ("Evening rotation", [("Night Drive", "Demo Artist"), ("City Lights", "Demo Artist")]),
            ("Deep focus", [("First Light", "Studio Fixture"), ("Quiet Hours", "Studio Fixture")]),
            ("Weekend favourites", [("Open Road", "Sample Band")]),
        ):
            playlist = api.db.create_playlist(user["id"], name)
            for title, artist in tracks:
                api.db.add_song_to_playlist(user["id"], playlist["id"], {
                    "id": title.lower().replace(" ", "-"), "title": title, "artist": artist,
                    "filename": "", "duration": 210, "url": "", "thumbnail": "",
                })
        print("ISOLATED DEMO: temporary data, login demo / demo-only; external music disabled.")
        uvicorn.run(api.app, host="127.0.0.1", port=8000)
