class Lyrics {
  final String? plainLyrics;
  final String? syncedLyrics; // Preserved for future syncing
  final bool instrumental;
  final String trackName;
  final String artistName;
  final String? albumName;
  final String source;

  Lyrics({
    required this.plainLyrics,
    this.syncedLyrics,
    required this.instrumental,
    required this.trackName,
    required this.artistName,
    this.albumName,
    required this.source,
  });

  factory Lyrics.fromJson(Map<String, dynamic> json) {
    return Lyrics(
      plainLyrics: json['plainLyrics'] as String?,
      syncedLyrics: json['syncedLyrics'] as String?,
      instrumental: json['instrumental'] as bool? ?? false,
      trackName: json['trackName'] as String? ?? '',
      artistName: json['artistName'] as String? ?? '',
      albumName: json['albumName'] as String?,
      source: json['source'] as String? ?? 'lrclib',
    );
  }

  bool get hasLyrics => plainLyrics != null && plainLyrics!.isNotEmpty;
  bool get hasSyncedLyrics => syncedLyrics != null && syncedLyrics!.isNotEmpty;
}
