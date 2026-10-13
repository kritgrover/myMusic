# myMusic

A full-stack application for searching YouTube, downloading music, playing audio files, and discovering new music through personalized recommendations. Built with Flutter (frontend) and Python FastAPI (backend), with Spotify integration for recommendations.

## Project Structure

```
.
├── frontend/                    # Flutter app (web/desktop/mobile)
│   ├── lib/
│   │   ├── screens/             # App screens
│   │   │   ├── home_screen.dart           # Main navigation with recommendations
│   │   │   ├── search_screen.dart         # YouTube search interface
│   │   │   ├── downloads_screen.dart      # Downloaded files management
│   │   │   ├── playlists_screen.dart      # Playlist management
│   │   │   ├── playlist_detail_screen.dart
│   │   │   ├── genre_screen.dart          # Genre-based music browsing
│   │   │   ├── made_for_you_screen.dart   # Personalized recommendations
│   │   │   ├── spotify_playlist_screen.dart
│   │   │   ├── csv_upload_screen.dart     # CSV playlist import
│   │   │   └── lyrics_screen.dart         # Lyrics display with sync
│   │   ├── services/            # API and state management
│   │   │   ├── api_service.dart           # Backend API client
│   │   │   ├── recommendation_service.dart # Spotify recommendations
│   │   │   ├── player_state_service.dart  # Audio playback state
│   │   │   ├── queue_service.dart         # Queue management
│   │   │   ├── saved_music_service.dart   # Account library state
│   │   │   ├── playback_session_service.dart # Paused session restoration
│   │   │   ├── listening_session_service.dart # Measured listening events
│   │   │   ├── playlist_service.dart      # Playlist operations
│   │   │   ├── recently_played_service.dart
│   │   │   ├── lyrics_service.dart        # Lyrics fetching and management
│   │   │   └── album_cover_cache.dart
│   │   ├── models/              # Data models (Playlist, QueueItem, Lyrics)
│   │   └── widgets/             # Reusable UI components
│   │       ├── horizontal_song_list.dart
│   │       ├── genre_card.dart
│   │       ├── bottom_player.dart
│   │       └── ...
├── backend/                     # Python FastAPI server
│   ├── app.py                   # Main API server
│   ├── spotify_service.py       # Spotify Web API integration
│   ├── download_service.py      # YouTube download handling
│   ├── lyrics_service.py        # LRCLIB lyrics API integration
│   ├── database.py              # SQLite accounts, playlists, library, history/cache
│   ├── listening_history.py     # Cumulative listening event validation
│   ├── recommendation_ranking.py # Listening, likes, follows and fallback ranking
│   ├── source_security.py       # Individual YouTube URL validation
│   ├── stream_cache.py          # Bounded fallback audio cache
│   ├── config.py                # Configuration (Spotify credentials)
│   ├── downloads/               # Downloaded audio files
│   └── music_app.db             # Persistent SQLite data
```

## Features

### Core Features
- 🔍 **Unified Search**: Separate Songs, Artists, Albums, Playlists, and Your Library results, with autocomplete suggestions and recent searches
- ⬇️ **Audio Download**: Download audio from YouTube videos (M4A/MP3)
- 🎵 **Media Player**: Built-in audio player with playback controls
- 📥 **Downloads Management**: View and manage downloaded files
- 🏷️ **Metadata**: Automatic metadata embedding (title, artist, album)
- 🌐 **Streaming**: Stream tracks directly from YouTube without downloading

### Playlist Features
- 📋 **Playlists**: Create, manage, and organize playlists
  - Create, rename, and delete playlists
  - Add songs from search results or downloads
  - Download tracks directly from playlists
  - Play tracks (downloaded or streamed from YouTube)
- 🎧 **Queue Management**: Build and manage playback queues
  - Add individual tracks or entire playlists to queue
  - Shuffle playlists before adding to queue
  - Auto-play next track in queue
  - Shuffle upcoming tracks without interrupting playback, restore their order, and drag to reorder
  - Repeat all or repeat one; manual Next still advances when repeat one is enabled
  - Clear upcoming tracks while keeping the current song
  - Previous restarts the current song after three seconds
- 📄 **CSV Import**: Import playlists from CSV files with automatic YouTube search

### Library and Player Experience
- Native apps have **Your Library → On this device** for audio stored on the current phone or computer. Use **Save on this device** from Server files, **Download for offline** on a playlist, or Download from catalog/search track actions.
- Completed device downloads include persistent track metadata, playlist membership/order, and available artwork. Search and play this collection without the backend; removing a device copy keeps the server copy and account library intact.
- Device playback checks local files before requesting server media authorization. Queues and playback history retain canonical track references, while local storage is isolated by account and backend.
- A previously signed-in account can reopen its offline library during network outages. Explicitly rejected credentials still require signing in again.
- This first offline implementation transfers while the app is running, with progress, cancellation and retry. Interrupted files are never listed as complete. OS-managed mobile background downloads, automatic playlist synchronization, Wi-Fi-only rules and file export are follow-up work. Browser builds continue to use server downloads and do not claim device-offline support.
- Liked Songs, saved albums, and followed artists persist in your account. Save from track rows or the player, then search, sort, and play your collection in Your Library.
- Saving the same song from different screens shares one like; failed saves are rolled back with a retryable error.
- Private audio and embedded artwork are restricted to their owner's account. Browser playback uses short-lived, file-scoped media links that are never stored in playback history.
- Responsive now-playing controls, seek bar, mute with volume restoration, and a compact queue overlay
- Search as you type, with retry and protection against stale search results. Recent searches are stored on this device per account and backend; remove individual entries or clear them all.
- Recording labels distinguish original, studio, live, remix, acoustic, instrumental, cover, and karaoke versions when the source metadata identifies them. Unlabeled video recordings remain “Unspecified.”
- Use **More actions → Change recording** on a streaming track to compare sources or paste a specific YouTube video link. **Use and remember** saves the choice to your account; **Use automatic match** resets it. Existing downloaded audio remains the downloaded recording.
- Artist pages show the available discography with Albums, Singles & EPs, Compilations, and Appears on filters, release years, and newest/oldest sorting. Release and album-track pagination fetches the full available result, with retry on incomplete provider responses.
- Search your playlists by playlist name, song title, or artist; sort by recent update, name, or track count
- Saved playlist shortcuts on Home, including when recommendations are unavailable
- `Ctrl+K` / `Cmd+K` focuses music search
- Safe download matching preserves stored playlist tracks and order

### Spotify Integration & Recommendations
- 🎯 **Songs for You**: Personalized recommendations based on your listening history
- Qualified listening time, repeat plays, likes and followed artists influence ranking; intentional early skips reduce preference
- Owned downloads and playlist or liked tracks remain available in personalized shelves when catalogue providers fail
- 🎸 **Genre Browsing**: Explore music by genre (Pop, Rock, Hip Hop, Electronic, Jazz, Classical, Indie, Metal, and many more)
- 📊 **Listening History**: Tracks play history to improve recommendations
- 🎼 **Genre Preferences**: Learns your favorite genres over time
- 🖼️ **Album Artwork**: Automatic album cover fetching from iTunes and Spotify

### Lyrics Integration
- 🎤 **Lyrics Display**: View lyrics for currently playing tracks
- ⏱️ **Synced Lyrics**: Real-time synchronized lyrics that highlight as the song plays (LRC format)
- 🎯 **Clickable Lyrics**: Tap on any lyric line to seek to that timestamp in the song
- 📝 **Plain Lyrics**: Fallback to plain text lyrics when synced lyrics aren't available
- 🔄 **Auto-fetch**: Lyrics are automatically fetched when opening the lyrics view
- 💾 **Caching**: Lyrics are cached for 7 days to improve performance
- 🎹 **Instrumental Detection**: Detects and displays when a track is instrumental
- 🌐 **LRCLIB Integration**: Powered by the LRCLIB API for comprehensive lyrics database

## Quick Start

### Backend Setup

1. Navigate to the backend directory:
```bash
cd backend
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

3. Install ffmpeg:
- **Windows**: Download from https://ffmpeg.org/download.html
- **macOS**: `brew install ffmpeg`
- **Linux**: `sudo apt-get install ffmpeg`

   YouTube playback also needs **Node.js 22+** or **Deno 2.3+** on `PATH`.
   The backend detects and enables that runtime automatically. The pinned
   `yt-dlp[default]` dependency includes the matching JavaScript solver package;
   installing plain `yt-dlp` alone can leave playback unable to resolve audio.
   See the [yt-dlp JavaScript setup guide](https://github.com/yt-dlp/yt-dlp/wiki/EJS).

   If YouTube playback starts failing after a provider change, update the
   extractor and its solver together, then restart the backend:
   ```bash
   python -m pip install --upgrade "yt-dlp[default]"
   ```
   After verifying playback, update the version pin in `backend/requirements.txt`
   so a fresh installation uses the verified version too. Public playback does
   not automatically read cookies from your browser.

4. Configure authentication (required):
   - Generate a random signing secret:
   ```bash
   python -c "import secrets; print(secrets.token_urlsafe(48))"
   ```
   - Save it in `backend/.env` or the process environment as `JWT_SECRET_KEY`.
   - Keep the same secret between restarts. Changing it invalidates existing sessions.
   - Startup rejects missing, blank, or known-default secrets.

5. Configure Spotify API (optional, for external catalogue recommendations):
   - Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
   - Development-mode apps require an active Spotify Premium subscription on the
     account that owns the API app. Without it, Spotify rejects catalog requests
     with HTTP 403; video search and your local library remain available. See
     [Spotify's development-mode requirements](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
   - Create a new application
   - Copy your Client ID and Client Secret
   - Create a `.env` file in the `backend/` directory:
   ```env
   CLIENT_ID=your_spotify_client_id_here
   CLIENT_SECRET=your_spotify_client_secret_here
   ```

6. Run the server:
```bash
python app.py
```

The API will be available at `http://localhost:8000`

On Windows, `py app.py` can be used when the Python launcher is installed.
Create accounts with the local `backend/scripts/create_user.py` administrative
script; use its `--help` for the supported arguments. The isolated browser test
server below supplies disposable accounts without creating production users.

The default SQLite database is always `backend/music_app.db`, even when the
server is launched from another directory. Set `DATABASE_URL` to use another
SQLite database, preferably an absolute URL such as
`sqlite:///E:/myMusic/backend/music_app.db` on Windows.

### Frontend Setup

1. Navigate to the frontend directory:
```bash
cd frontend
```

2. Install Flutter dependencies:
```bash
flutter pub get
```

3. Run the app:
```bash
flutter run
```

For a local browser session:

```bash
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 8080
```

## Configuration

### Private media and streaming storage

Media requests require an authenticated account. The frontend obtains a scoped
playback link from `POST /media/authorize` immediately before loading audio;
ordinary API requests and private artwork use the account's bearer token.
Authorization takes `{"path":"/downloads/<encoded filename>"}` or
`{"path":"/stream/<encoded YouTube URL>"}` and returns a relative `url` plus
`expires_at`. Media tokens only authorize `GET`/`HEAD` for that exact normalized
audio path. They cannot authenticate other API calls. Download requests recheck
the account's active status and file ownership, including after link creation.
Downloading, streaming, and metadata extraction accept individual YouTube video
URLs only, canonicalized to a video ID; playlist URLs, arbitrary remote hosts,
local paths and command-like sources are rejected. Text searches remain supported.

The stream fallback cache defaults to a 24-hour lifetime, 512 MiB total, and
64 MiB per track. Configure `STREAM_CACHE_TTL_SECONDS`,
`STREAM_CACHE_MAX_BYTES`, and `STREAM_CACHE_MAX_FILE_BYTES` in the backend
environment. The effective per-track cap cannot exceed the total cap. Cache
fills are coordinated within the server process, reuse the same canonical
source, and protect files in active responses from eviction. Failed partial
files are cleaned up; fallback downloads have a three-minute process timeout and
a temporary-file byte limit. Run one API worker per cache directory.
`MEDIA_TOKEN_SECONDS` controls playback-link lifetime (two hours by default,
clamped to 60 seconds–6 hours).

Existing download files are preserved during the one-time ownership migration.
Ownership is taken from existing playlist references; an installation with
exactly one user also assigns its unreferenced legacy downloads to that user.
In a multi-user installation, unreferenced legacy files remain on disk without
being exposed to arbitrary accounts. Copying a public playlist shares its source
metadata and strips private file/artwork references. Deleting a shared legacy
download removes only the caller's claim; its bytes remain while another owner
still has a claim. Matching playlist links are cleared by exact relative path.
Liked tracks remain saved and can use their original source after local deletion.

### Search and recording choices

`GET /search/unified?q=...&limit=20` returns `songs`, `artists`, `albums`,
`playlists`, `library`, `suggestions`, and `warnings`. Catalog metadata comes
from Spotify's US market; playlists include the caller's own playlists.
Your Library searches saved music, owned downloads, and tracks in owned playlists.
The app loads `GET /search/library` independently so owned music appears while
catalog providers are still responding.
Only public provider results are cached. Account results are read separately on
each request. Spotify access and market availability determine catalog coverage;
when it is unavailable, search returns available YouTube sources and account
results with an explanatory notice. Search currently returns the provider's first
10 catalog results per category, plus up to 20 video fallback results.

`POST /search/candidates` and `POST /search/resolve` accept `title`, `artist`,
optional `album`, `duration` (seconds), `spotify_id`, and an existing `url`.
The resolver first honors an account's remembered choice, then an explicit
source, otherwise ranks sources by title, artist, duration, and recording version.
An uncertain automatic match returns an error so the user can choose a source.
`PUT /search/source` remembers an individual YouTube URL for that recording;
`DELETE /search/source` with the recording identity restores automatic selection.
Choices persist in SQLite per account and never change another user's matches.
Version detection uses text metadata, not audio fingerprinting.

### Saved account library

`GET /library` returns `{tracks: [...], albums: [...], artists: [...]}`. Save or
replace an item with `PUT /library/{kind}/{item_id}`; remove it with `DELETE` at
the same path. Both operations are idempotent per account, kind and ID. Items
persist in SQLite and are ordered by latest save. Encode the entire item ID as
one URL path component when it contains `/`, `%`, `?` or `#`.

Track metadata accepts `title`, `artist`, `album`, `filename`, `url`, `thumbnail`,
`duration`, `source_id` and `spotify_id`; an optional original `id` is preserved
as `source_id` when different from the saved item key. Albums accept `title`,
`artist`, `thumbnail`; artists accept `name`, `thumbnail`. A title/name is required.
Text labels are limited to 300 characters, item/source IDs to 512, filenames to
1024 and URLs to 2048. Track duration is finite and within 0–86400 seconds.
Unknown fields and control characters are rejected. Files must already belong
to the caller; saving a like does not grant file ownership. Canonical YouTube
sources and public HTTPS artwork are accepted; private artwork references must
be owned. Signed media links and credential-bearing metadata are rejected.

### Listening history and recommendation ranking

The player measures elapsed time while audio is playing and ready, excluding
paused/buffering time and seek jumps. It reports cumulative progress every five
seconds and on pause or track completion/change. Each playback occurrence has
one event ID; pause/resume keeps the same event, while replay creates another.
Each report has a five-second delivery timeout so a stalled request cannot
indefinitely hold up logout. Retries coalesce the latest report per event, with
at most 32 pending events in memory. Pending reports are scoped to the authenticated session and are not an
offline durable journal; closing the app during an outage can lose unsent time.

Authenticated `POST /history/listening` accepts, for example:

```json
{
  "event_id": "playback_occurrence_001",
  "sequence": 3,
  "song_title": "Track title",
  "artist": "Artist name",
  "source_url": "https://www.youtube.com/watch?v=abcdefghijk",
  "duration_seconds": 180,
  "listened_seconds": 35.5,
  "end_reason": "paused"
}
```

`event_id` is 8–128 ASCII letters, digits, underscores or hyphens; `sequence` is
an integer from 1 through 2147483647. Title and artist are required, at most 300
characters. `source_url` is optional and must be a canonicalizable YouTube video
URL; optional `spotify_id` is an opaque ID of at most 128 letters, digits,
underscores or hyphens. Both duration fields must be finite within 0–86400
seconds. Listening time may exceed track duration when a listener seeks back.
Reasons are `ongoing`, `paused`, `completed`, `skipped`, `stopped` or `error`.

The response includes `accepted`, stored `sequence`, `listened_seconds`,
`qualified` and `closed`. SQLite atomically keeps one row per account/event,
ignores stale or repeated sequences, and never decreases cumulative time.
Completed/skipped/stopped/error events are terminal and cannot reopen. Track
identity and an already known source cannot change within an event (HTTP 409).
Validation failures return HTTP 400. Ingestion performs no provider requests.

A play qualifies after 30 seconds or half a known track's duration, whichever
is shorter. Unknown-duration tracks require 30 seconds. Completing after a seek
does not bypass this threshold. An intentional `skipped` event below 10 seconds
or one quarter of a known track, whichever is shorter, reduces preference;
playback errors and stops do not create that penalty. Ranking uses up to 3000
events from the last 90 days with a 30-day recency half-life, full-listen and
repeat signals, liked tracks, saved albums and followed artists. Provider
results are deduplicated with owned download/playlist/liked-track metadata.
When providers fail or return nothing, these local candidates remain playable;
plain downloads use embedded title/artist metadata or their filename as a title.
New releases and artist shelves can fall back to saved albums/artists.

`GET /analytics/recap?period=weekly|monthly` uses rolling 7-/30-day UTC windows.
Plays, top tracks and unique artists count qualified events; minutes sum actual
reported listening time, including short sessions. Existing history is retained,
but old zero-duration click records do not inflate plays or recommendations.
Date comparisons support both old SQLite timestamps and ISO timestamps with
offsets. Legacy `POST /history` remains compatible; new clients should use the
idempotent listening endpoint. Recap genres use cached catalogue enrichment and
can be empty without provider data.

### Isolated browser fixture

For isolated browser regression, run `python backend/tests/demo_server.py --port 8002`
and build the frontend with
`flutter build web --dart-define=API_BASE_URL=http://localhost:8002`.
Serve the resulting `frontend/build/web` directory locally. The test server
uses temporary data and generated audio, with accounts `demo` / `demo-only`
and `other` / `other-only`. It does not read your music database or credentials.
Its catalogue providers are deterministic fixtures; account, library, and media
requests use the real application routes.
Only this test server exposes `POST /__test/provider-state` with
`{"available":false}` to simulate catalogue failure. Sign in as `demo` and send
its bearer token. `{"available":true}` or `POST /__test/reset` restores providers;
reset also restores the fixture library. YouTube fixture search and local audio
remain available during the simulated catalogue outage.

### Backend API URL

Set the API URL at frontend build/run time; no source edit is needed:

```bash
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 8081 --dart-define=API_BASE_URL=http://localhost:8000
```

The default is `http://localhost:8000`. For Android emulator, pass
`--dart-define=API_BASE_URL=http://10.0.2.2:8000`; for a physical device, use the
backend computer's reachable LAN address.

### Download Format

By default, files are downloaded as M4A. To change to MP3, modify the `outputFormat` parameter in the download requests.

### Spotify API (Recommendations)

The Spotify catalogue integration requires API credentials. Without them,
personalized shelves can still use the account's own library and listening
history. External discovery and catalogue enrichment need working credentials.
To enable:

1. Create a Spotify Developer account at https://developer.spotify.com
2. Create a new application in the dashboard
3. Add your credentials to `backend/.env`:
```env
CLIENT_ID=your_client_id
CLIENT_SECRET=your_client_secret
```

## API Endpoints

### Core Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/search` | Search YouTube for videos |
| POST | `/download` | Download audio from YouTube URL |
| POST | `/media/authorize` | Authorize an exact audio path for temporary playback |
| GET | `/downloads` | List the current account's downloaded files |
| GET/HEAD | `/downloads/{filename}` | Read owned audio, with range/seek support |
| GET | `/downloads/{filename}/artwork` | Read owned artwork using bearer authentication |
| DELETE | `/downloads/{filename}` | Remove an owned download and its matching playlist links |
| GET/HEAD | `/stream/{encoded_url}` | Authenticated YouTube audio streaming |

### Saved Library Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/library` | Current account's liked tracks, saved albums and followed artists |
| PUT | `/library/{kind}/{item_id}` | Save/update bounded metadata; returns the saved item |
| DELETE | `/library/{kind}/{item_id}` | Remove one saved item, idempotently |

### Playlist Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/playlists` | Get the current account's playlists |
| POST | `/playlists` | Create a new playlist |
| GET | `/playlists/{id}` | Get a specific playlist |
| PUT | `/playlists/{id}` | Update playlist (rename) |
| DELETE | `/playlists/{id}` | Delete a playlist |
| POST | `/playlists/{id}/songs` | Add song to playlist |
| DELETE | `/playlists/{id}/songs/{song_id}` | Remove song from playlist |

### Recommendation Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/history/listening` | Upsert an idempotent cumulative listening event |
| POST | `/history` | Legacy listening-history ingestion |
| GET | `/history/recent` | Current account's recent events (`limit` 1–100) |
| GET | `/analytics/recap` | Qualified plays and measured minutes over 7 or 30 days |
| GET | `/recommendations/daily` | Get personalized daily mix |
| GET | `/recommendations/for-you` | Get personalized recommendations |
| GET | `/recommendations/genre/{genre}` | Get tracks for a specific genre |
| GET | `/recommendations/genres` | Get list of available genres |
| GET | `/recommendations/browse/new-releases` | Get new album releases |

### Lyrics Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/lyrics` | Get lyrics for a track (query params: `track_name`, `artist_name`, `album_name` (optional), `duration` (optional)) |

### Other Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/album-cover` | Fetch album cover from iTunes |
| POST | `/csv/upload` | Upload a CSV file for playlist import |
| POST | `/csv/convert/{filename}` | Convert CSV to playlist |

## Requirements

### Backend
- Python 3.10+ (required by yt-dlp)
- yt-dlp
- ffmpeg
- FastAPI
- mutagen
- httpx (for lyrics API requests)
- spotipy (for Spotify integration)
- python-dotenv

### Frontend
- Flutter 3.0.0+
- Dart 3.0.0+

## Notes

- The backend uses yt-dlp to search and download from YouTube
- Downloaded files are saved in `backend/downloads/`
- Accounts, playlists, download ownership, saved library, listening history, and caches use `backend/music_app.db` (SQLite)
- Schema changes are additive; old playlist track IDs and history remain usable after restart
- Audio metadata is automatically embedded using mutagen
- The app supports both local file playback and streaming from YouTube
- The app requires network access to connect to the backend API
- The frontend works on web, desktop (Windows/macOS/Linux), and mobile platforms
- Spotify integration is optional and adds external catalogue discovery to recommendations from the account's library
- Lyrics are fetched from LRCLIB API and cached for 7 days to reduce API calls
- Synced lyrics (LRC format) enable real-time highlighting and click-to-seek functionality

## Troubleshooting

### Verification

Run the backend regression suite from the repository root:

```bash
python -m unittest discover -s backend/tests -v
```

On Windows, replace `python` with `py`. Focused checks for these features:

```powershell
py -m unittest discover -s backend/tests -p 'test_private_media.py' -v
py -m unittest discover -s backend/tests -p 'test_saved_library*.py' -v
py -m unittest discover -s backend/tests -p 'test_listening_history.py' -v
py -m unittest discover -s backend/tests -p 'test_recommendation_ranking.py' -v
```

The backend tests use temporary databases and media files and replace external
service configuration; they do not read or modify your personal library or `.env`.
For a temporary UI test library, run `python backend/tests/demo_server.py` and
sign in with `demo` / `demo-only` (or `other` / `other-only` for account isolation).
This local test server generates short audio files, uses real authentication,
private media and library endpoints, and replaces external catalogue providers.
It deletes its temporary database on shutdown. It supports playback regression
checks without downloading music or modifying your personal library; external
Spotify and YouTube integration still needs separate provider verification.
The audio fixture tests require `ffmpeg` on `PATH`; the demo server also accepts
`--ffmpeg <executable path>`. Regression coverage includes account isolation,
signed range playback, revoked access, bounded stream cache failures, old schema
migration, saved-library persistence, stale/concurrent listening retries, UTC
recap boundaries, intentional skip ranking and provider-outage playback.

Run frontend checks from `frontend/`:

```bash
flutter test
flutter analyze
flutter build web
```

For a Windows decoder check against a real YouTube source, build Windows Release,
start the regular backend, then run this from the repository root:

```powershell
py backend/scripts/check_native_playback.py --username YOUR_USERNAME --youtube-url "https://www.youtube.com/watch?v=VIDEO_ID"
```

The script prompts for your password, authenticates the stream, and decodes two
seconds with the app's bundled libmpv library into a silent output. It leaves the
open app untouched and reports no credentials or signed URLs. This checks the
live provider and native decoder separately from the fixture and widget tests.

For a served fixture build, use separate terminals from the repository root:

```powershell
py backend/tests/demo_server.py --port 8002
```

```powershell
cd frontend
flutter build web --pwa-strategy=none --dart-define=API_BASE_URL=http://localhost:8002
py -m http.server 8081 --bind 127.0.0.1 --directory build/web
```

Open `http://localhost:8081`. After each phase and the final build, exercise both
accounts, library save/reload/remove, queue edits/repeats/shuffle, paused restore,
seek/pause/completion, private download deletion, crossfade and provider outage.
Check measured listening after a pause and a seek rather than inferring it from
the seek bar. The generated tracks make these checks repeatable without touching
personal data.

For repeated browser regression builds, use `flutter build web --pwa-strategy=none`
and a fresh preview origin to avoid an older installed service worker serving a
cached version. Set `--dart-define=API_BASE_URL=http://localhost:8002` when using
the isolated fixture API.

Playback sessions are saved locally per backend and immutable account ID. The
queue, original shuffle order, repeat mode, volume and playback position survive
reopening the app. Restored playback stays paused until Play is pressed; private
media capabilities are fetched again and never stored in the playback snapshot.
Progress is checkpointed every five seconds and on playback or queue changes,
with a final flush on logout and app lifecycle changes.

Playback settings in the player's overflow menu control crossfade from 0 to 12
seconds, saved per account. Zero uses gapless transitions when the next track is
ready. The browser schedules decoded audio on one Web Audio clock; it keeps only
the current and next buffers, limits each encoded file to 64 MiB and the decoded
pair to 192 MiB of retained buffers, and falls back to progressive playback for oversized or
unsupported media. That fallback and a successor that has not finished loading
can have a transition gap. Windows/Linux use the native playlist backend with
prefetching, while crossfade uses two decks. Short tracks shorten the fade to
avoid overlapping their entire duration. Pause, seek, manual track changes and
queue edits invalidate stale transition work.

Download matching in playlist details is deliberately non-destructive: it links
available files in the current view using exact, unambiguous metadata. It does
not delete/re-add stored tracks. Persisting verified links through an atomic
track-update endpoint remains future work.

### Backend Issues

- **yt-dlp not found**: Make sure yt-dlp is installed and in your PATH
- **ffmpeg not found**: Install ffmpeg and ensure it's accessible
- **Download fails**: Check that yt-dlp and ffmpeg are properly installed
- **Spotify recommendations not working**: Verify your `.env` file has valid Spotify credentials
- **"Spotify credentials not set"**: Create `.env` file with `CLIENT_ID` and `CLIENT_SECRET`

### Frontend Issues

- **Cannot connect to API**: Verify the backend is running and the URL is correct
- **Audio won't play**: Ensure the backend is serving files correctly
- **Build errors**: Run `flutter clean` and `flutter pub get`
- **External recommendations not loading**: Check Spotify credentials/network access; owned library recommendations should remain available
- **Lyrics not loading**: Ensure the backend has network access to reach LRCLIB API
- **Synced lyrics not working**: Verify the track has synced lyrics available and the player is actively playing

## License

This project is for educational purposes.
