# Music Downloader App

A full-stack application for searching YouTube, downloading music, and playing audio files. Built with Flutter (frontend) and Python FastAPI (backend).

## Project Structure

```
.
├── frontend/          # Flutter mobile app
├── backend/           # Python FastAPI server
└── spotify2media.py   # Original script (reference)
```

## Features

- 🔍 **YouTube Search**: Search for music videos with deep search option
- ⬇️ **Audio Download**: Download audio from YouTube videos (M4A/MP3)
- 🎵 **Media Player**: Built-in audio player with playback controls
- 📥 **Downloads Management**: View and manage downloaded files
- 🏷️ **Metadata**: Automatic metadata embedding (title, artist, album)

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

If running on a different machine or port, update the API URL in `frontend/lib/services/api_service.dart`:

```dart
ApiService({this.baseUrl = 'http://YOUR_IP:8000'});
```

### Download Format

By default, files are downloaded as M4A. To change to MP3, modify the download request in `frontend/lib/screens/search_screen.dart`:

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
- Audio metadata is automatically embedded using mutagen
- The app requires network access to connect to the backend API

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


