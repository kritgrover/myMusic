# Music Downloader Flutter App

A Flutter mobile app for searching YouTube, downloading music, and playing audio files.

## Features

- 🔍 **Search**: Search YouTube for music videos
- ⬇️ **Download**: Download audio from YouTube videos
- 🎵 **Player**: Built-in audio player with playback controls
- 📥 **Downloads**: View and manage downloaded files

## Requirements

- Flutter SDK 3.0.0 or higher
- Dart SDK 3.0.0 or higher
- Backend API running (see backend README)

## Setup

1. Install Flutter dependencies:
```bash
flutter pub get
```

2. Make sure the backend API is running on `http://localhost:8000`

3. For Android/iOS, you may need to update the API URL in `lib/services/api_service.dart`:
```dart
ApiService({this.baseUrl = 'http://YOUR_IP:8000'});
```

## Running the App

```bash
flutter run
```

## Project Structure

```
lib/
├── main.dart                 # App entry point
├── screens/
│   ├── home_screen.dart      # Main navigation screen
│   ├── search_screen.dart    # YouTube search interface
│   ├── downloads_screen.dart # Downloaded files list
│   └── player_screen.dart    # Audio player interface
├── services/
│   ├── api_service.dart     # Backend API client
│   └── audio_player_service.dart # Audio playback service
└── widgets/
    └── video_card.dart       # Video result card widget
```

## Dependencies

- `http`: HTTP client for API calls
- `audioplayers`: Audio playback functionality
- `path_provider`: File system access
- `permission_handler`: Request permissions (for file access)

## Notes

- The app connects to the backend API for search and download functionality
- Downloaded files are managed by the backend
- Audio playback streams from the backend server
- Make sure to configure network permissions for Android/iOS


