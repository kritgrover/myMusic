# myMusic

A full-stack application for searching YouTube, downloading music, and playing audio files. Built with Flutter (frontend) and Python FastAPI (backend).

## Project Structure

```
.
├── frontend/          # Flutter app (web/desktop/mobile)
│   ├── lib/
│   │   ├── screens/   # Main app screens (Search, Downloads, Playlists, CSV Upload)
│   │   ├── services/  # API, playlist, queue, and player services
│   │   ├── models/    # Data models (Playlist, QueueItem)
│   │   └── widgets/   # Reusable UI components
├── backend/           # Python FastAPI server
│   ├── downloads/     # Downloaded audio files
│   └── playlists.json # Playlist storage
```

## Features

- 🔍 **YouTube Search**: Search for music videos with deep search option
- ⬇️ **Audio Download**: Download audio from YouTube videos (M4A/MP3)
- 🎵 **Media Player**: Built-in audio player with playback controls
- 📥 **Downloads Management**: View and manage downloaded files
- 🏷️ **Metadata**: Automatic metadata embedding (title, artist, album)
- 📋 **Playlists**: Create, manage, and organize playlists
  - Create, rename, and delete playlists
  - Add songs from search results or downloads
  - Download tracks directly from playlists
  - Play tracks (downloaded or streamed from YouTube)
- 🎧 **Queue Management**: Build and manage playback queues
  - Add individual tracks or entire playlists to queue
  - Shuffle playlists before adding to queue
  - Auto-play next track in queue
- 🌐 **Streaming**: Stream tracks directly from YouTube without downloading
- 📄 **CSV Import**: Import playlists from CSV files with automatic YouTube search

## Quick Start

### Backend Setup

1. Navigate to the backend directory:
```bash
cd backend
```

2. Install dependencies:
```bash
pip install -r requirements.txt
pip install yt-dlp
```

3. Install ffmpeg:
- **Windows**: Download from https://ffmpeg.org/download.html
- **macOS**: `brew install ffmpeg`
- **Linux**: `sudo apt-get install ffmpeg`

4. Run the server:
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

By default, files are downloaded as M4A. To change to MP3, modify the `outputFormat` parameter in the download requests:
- `frontend/lib/screens/search_screen.dart` (line ~197)
- `frontend/lib/screens/playlist_detail_screen.dart` (lines ~142, ~397)

```dart
outputFormat: 'mp3',  // Change from 'm4a' to 'mp3'
```

## API Endpoints

See `backend/README.md` for detailed API documentation.

## Requirements

### Backend
- Python 3.8+
- yt-dlp
- ffmpeg
- FastAPI
- mutagen

### Frontend
- Flutter 3.0.0+
- Dart 3.0.0+

## Notes

- The backend uses yt-dlp to search and download from YouTube
- Downloaded files are saved in `backend/downloads/`
- Playlists are stored in `backend/playlists.json`
- Audio metadata is automatically embedded using mutagen
- The app supports both local file playback and streaming from YouTube
- The app requires network access to connect to the backend API
- The frontend works on web, desktop (Windows/macOS/Linux), and mobile platforms

## Troubleshooting

### Backend Issues

- **yt-dlp not found**: Make sure yt-dlp is installed and in your PATH
- **ffmpeg not found**: Install ffmpeg and ensure it's accessible
- **Download fails**: Check that yt-dlp and ffmpeg are properly installed

### Frontend Issues

- **Cannot connect to API**: Verify the backend is running and the URL is correct
- **Audio won't play**: Ensure the backend is serving files correctly
- **Build errors**: Run `flutter clean` and `flutter pub get`

## License

This project is for educational purposes.


