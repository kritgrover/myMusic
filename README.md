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
│   │   │   └── csv_upload_screen.dart     # CSV playlist import
│   │   ├── services/            # API and state management
│   │   │   ├── api_service.dart           # Backend API client
│   │   │   ├── recommendation_service.dart # Spotify recommendations
│   │   │   ├── player_state_service.dart  # Audio playback state
│   │   │   ├── queue_service.dart         # Queue management
│   │   │   ├── playlist_service.dart      # Playlist operations
│   │   │   ├── recently_played_service.dart
│   │   │   └── album_cover_cache.dart
│   │   ├── models/              # Data models (Playlist, QueueItem)
│   │   └── widgets/             # Reusable UI components
│   │       ├── horizontal_song_list.dart
│   │       ├── genre_card.dart
│   │       ├── bottom_player.dart
│   │       └── ...
├── backend/                     # Python FastAPI server
│   ├── app.py                   # Main API server
│   ├── spotify_service.py       # Spotify Web API integration
│   ├── download_service.py      # YouTube download handling
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
- 📄 **CSV Import**: Import playlists from CSV files with automatic YouTube search

### Spotify Integration & Recommendations
- 🎯 **Songs for You**: Personalized recommendations based on your listening history
- 🎸 **Genre Browsing**: Explore music by genre (Pop, Rock, Hip Hop, Electronic, Jazz, Classical, Indie, Metal, and many more)
- 📊 **Listening History**: Tracks play history to improve recommendations
- 🎼 **Genre Preferences**: Learns your favorite genres over time
- 🖼️ **Album Artwork**: Automatic album cover fetching from iTunes and Spotify

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

4. Configure Spotify API (optional, for recommendations):
   - Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
   - Create a new application
   - Copy your Client ID and Client Secret
   - Create a `.env` file in the `backend/` directory:
   ```env
   CLIENT_ID=your_spotify_client_id_here
   CLIENT_SECRET=your_spotify_client_secret_here
   ```

5. Run the server:
```bash
python app.py
```

The API will be available at `http://localhost:8000`

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

### Other Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/album-cover` | Fetch album cover from iTunes |
| POST | `/csv/upload` | Upload a CSV file for playlist import |
| POST | `/csv/convert/{filename}` | Convert CSV to playlist |

## Requirements

### Backend
- Python 3.8+
- yt-dlp
- ffmpeg
- FastAPI
- mutagen
- spotipy (for Spotify integration)
- python-dotenv

### Frontend
- Flutter 3.0.0+
- Dart 3.0.0+

## Notes

- The backend uses yt-dlp to search and download from YouTube
- Downloaded files are saved in `backend/downloads/`
- Playlists are stored in `backend/playlists.json`
- Listening history and Spotify cache are stored in `backend/music_app.db` (SQLite)
- Audio metadata is automatically embedded using mutagen
- The app supports both local file playback and streaming from YouTube
- The app requires network access to connect to the backend API
- The frontend works on web, desktop (Windows/macOS/Linux), and mobile platforms
- Spotify integration is optional but enables personalized recommendations

## Troubleshooting

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

## License

This project is for educational purposes.
