# Music Downloader Flutter App

A Flutter app for searching YouTube, downloading music, playing audio files, and discovering new music through Spotify-powered recommendations.

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

3. For Android/iOS, you may need to update the API URL in `lib/config.dart`:
```dart
static const String apiBaseUrl = 'http://YOUR_IP:8000';
```

## Running the App

```bash
flutter run
```

## Project Structure

```
lib/
├── main.dart                          # App entry point
├── config.dart                        # App configuration
├── screens/
│   ├── home_screen.dart               # Main navigation with recommendations
│   ├── search_screen.dart             # YouTube search interface
│   ├── downloads_screen.dart          # Downloaded files list
│   ├── playlists_screen.dart          # Playlists list and management
│   ├── playlist_detail_screen.dart    # Individual playlist view
│   ├── add_to_playlist_screen.dart    # Add songs to playlist interface
│   ├── csv_upload_screen.dart         # CSV playlist import
│   ├── player_screen.dart             # Audio player interface
│   ├── genre_screen.dart              # Genre-based music browsing
│   ├── made_for_you_screen.dart       # Personalized recommendations view
│   └── spotify_playlist_screen.dart   # Spotify playlist view
├── services/
│   ├── api_service.dart               # Backend API client
│   ├── playlist_service.dart          # Playlist management service
│   ├── queue_service.dart             # Queue management service
│   ├── player_state_service.dart      # Audio playback state management
│   ├── recommendation_service.dart    # Spotify recommendations client
│   ├── recently_played_service.dart   # Recently played tracking
│   ├── album_cover_cache.dart         # Album artwork caching
│   └── audio_player_service.dart      # Audio player utilities
├── models/
│   ├── playlist.dart                  # Playlist and PlaylistTrack models
│   └── queue_item.dart                # Queue item model
├── widgets/
│   ├── video_card.dart                # Video result card widget
│   ├── bottom_player.dart             # Bottom player widget
│   ├── queue_panel.dart               # Queue management panel
│   ├── album_cover.dart               # Album cover display widget
│   ├── genre_card.dart                # Genre selection card
│   ├── horizontal_song_list.dart      # Horizontal scrolling song list
│   ├── playlist_selection_dialog.dart # Add to playlist dialog
│   ├── csv_progress_bar.dart          # CSV import progress
│   ├── download_progress_bar.dart     # Download progress indicator
│   └── not_found_songs_dialog.dart    # Missing songs notification
└── utils/
    └── song_display_utils.dart        # Utility functions for song display
```

## Dependencies

- `http`: HTTP client for API calls
- `just_audio`: Advanced audio playback with streaming support
- `path_provider`: File system access
- `permission_handler`: Request permissions (for file access)

## Usage

### Home Screen
The home screen shows:
- **Recently Played**: Quick access to tracks you've listened to
- **Songs for You**: Personalized recommendations (requires Spotify setup in backend)
- **Genre Cards**: Browse music by genre

### Playlists
1. Navigate to the Playlists tab
2. Create a new playlist or select an existing one
3. Add songs from Search or Downloads screens
4. Download tracks directly from the playlist
5. Play tracks (downloaded files or stream from YouTube)
6. Add entire playlists to queue with optional shuffle

### Queue Management
1. Add tracks to queue from Search, Downloads, or Playlists
2. Use the queue panel to manage playback order
3. Tracks automatically advance to the next item when finished
4. Add entire playlists to queue (with shuffle option)

### CSV Import
1. Navigate to CSV Upload tab
2. Select a CSV file with columns: Track Name, Artist Name(s), Album Name
3. Configure search options (deep search, duration filters, etc.)
4. The app will search YouTube for each track and create a playlist
5. Download tracks from the created playlist

### Genre Browsing
1. On the home screen, select a genre card
2. Browse tracks in that genre
3. Play, add to queue, or add to playlists

## Notes

- The app connects to the backend API for search, download, streaming, and recommendations
- Downloaded files are managed by the backend and stored in `backend/downloads/`
- Playlists are stored in `backend/playlists.json`
- Audio playback supports both local files and streaming from YouTube
- Make sure to configure network permissions for Android/iOS
- The app works on web, desktop (Windows/macOS/Linux), and mobile platforms
- Recommendations require Spotify API credentials to be configured in the backend
