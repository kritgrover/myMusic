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
│   ├── database.py              # SQLite database for history/cache
│   ├── config.py                # Configuration (Spotify credentials)
│   ├── downloads/               # Downloaded audio files
│   └── playlists.json           # Playlist storage
```

## Features

### Core Features
- 🔍 **YouTube Search**: Search for music videos with deep search option
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
- Responsive now-playing controls, seek bar, mute with volume restoration, and a compact queue overlay
- Search as you type, with retry and protection against stale search results
- Search your playlists by playlist name, song title, or artist; sort by recent update, name, or track count
- Saved playlist shortcuts on Home, including when recommendations are unavailable
- `Ctrl+K` / `Cmd+K` focuses music search
- Safe download matching preserves stored playlist tracks and order

### Spotify Integration & Recommendations
- 🎯 **Songs for You**: Personalized recommendations based on your listening history
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

4. Configure authentication (required):
   - Generate a random signing secret:
   ```bash
   python -c "import secrets; print(secrets.token_urlsafe(48))"
   ```
   - Save it in `backend/.env` or the process environment as `JWT_SECRET_KEY`.
   - Keep the same secret between restarts. Changing it invalidates existing sessions.
   - Startup rejects missing, blank, or known-default secrets.

5. Configure Spotify API (optional, for recommendations):
   - Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
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

### Backend API URL

If running on a different machine or port, update the API URL in `frontend/lib/config.dart`:

```dart
static const String apiBaseUrl = 'http://YOUR_IP:8000';
```

For Android emulator, use `http://10.0.2.2:8000`. For iOS simulator or web, use `http://localhost:8000`.

### Download Format

By default, files are downloaded as M4A. To change to MP3, modify the `outputFormat` parameter in the download requests.

### Spotify API (Recommendations)

The Spotify integration requires API credentials. Without them, the app will still work but recommendations will be disabled. To enable:

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
| GET | `/downloads` | List all downloaded files |
| GET | `/downloads/{filename}` | Serve/stream a downloaded file |
| DELETE | `/downloads/{filename}` | Delete a downloaded file |
| GET | `/stream/{encoded_url}` | Stream audio directly from YouTube |

### Playlist Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/playlists` | Get all playlists |
| POST | `/playlists` | Create a new playlist |
| GET | `/playlists/{id}` | Get a specific playlist |
| PUT | `/playlists/{id}` | Update playlist (rename) |
| DELETE | `/playlists/{id}` | Delete a playlist |
| POST | `/playlists/{id}/songs` | Add song to playlist |
| DELETE | `/playlists/{id}/songs/{song_id}` | Remove song from playlist |

### Recommendation Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/history` | Log a song play to history |
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
- Playlists are stored in `backend/playlists.json`
- Listening history, Spotify cache, and lyrics cache are stored in `backend/music_app.db` (SQLite)
- Audio metadata is automatically embedded using mutagen
- The app supports both local file playback and streaming from YouTube
- The app requires network access to connect to the backend API
- The frontend works on web, desktop (Windows/macOS/Linux), and mobile platforms
- Spotify integration is optional but enables personalized recommendations
- Lyrics are fetched from LRCLIB API and cached for 7 days to reduce API calls
- Synced lyrics (LRC format) enable real-time highlighting and click-to-seek functionality

## Troubleshooting

### Verification

Run the backend regression suite from the repository root:

```bash
python -m unittest discover -s backend/tests -v
```

The backend tests use temporary databases and media files and replace external
service configuration; they do not read or modify your personal library or `.env`.
For a temporary UI test library, run `python backend/tests/demo_server.py` and
sign in with `demo` / `demo-only`. This local test server disables external music
services and deletes its temporary database on shutdown. It is intended for
navigation and layout checks, not Spotify or YouTube playback validation.

Run frontend checks from `frontend/`:

```bash
flutter test
flutter analyze
flutter build web
```

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
- **Recommendations not loading**: Check that Spotify is configured in the backend
- **Lyrics not loading**: Ensure the backend has network access to reach LRCLIB API
- **Synced lyrics not working**: Verify the track has synced lyrics available and the player is actively playing

## License

This project is for educational purposes.
