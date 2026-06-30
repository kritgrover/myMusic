class AppConfig {
  // Backend URL is set at build time via --dart-define=API_BASE_URL=...
  // so the same source builds for local dev and for the hosted backend:
  //   flutter run                                    -> localhost (default below)
  //   flutter build windows --dart-define=API_BASE_URL=https://music.example.com
  //
  // Local-dev defaults if no --dart-define is passed:
  //   Android emulator: 'http://10.0.2.2:8000'
  //   iOS simulator / desktop: 'http://localhost:8000'
  //   Physical device on LAN: 'http://YOUR_COMPUTER_IP:8000'
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
}


