import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/playlist.dart';
import 'auth_http_client.dart';
import 'media_exceptions.dart';

class ApiService {
  final String baseUrl;
  final AuthHttpClient _client;

  ApiService({String? baseUrl, AuthHttpClient? client})
      : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        _client = client ?? AuthHttpClient.shared;

  /// Audio elements cannot set bearer headers in browsers. Resolve a private,
  /// short-lived media capability only at the point the audio source is loaded.
  /// Callers keep the canonical URL, never this returned capability, in state.
  Future<String> authorizeMediaUrl(String url) async {
    final canonical = canonicalMediaUrl(url, baseUrl: baseUrl);
    if (!isProtectedMediaUrl(canonical, baseUrl: baseUrl)) return canonical;
    final path = Uri.parse(canonical).path;
    final response = await _client.post(
      Uri.parse('$baseUrl/media/authorize'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'path': path}),
    );
    if (response.statusCode != 200) {
      if ((response.statusCode == 404 || response.statusCode == 410) &&
          path.startsWith('/downloads/')) {
        throw const DownloadUnavailableException();
      }
      throw StateError('Could not authorize media (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final value = data['url'];
    if (value is! String) throw StateError('Invalid media authorization');
    final authorized = Uri.parse(baseUrl).resolve(value);
    if (!isProtectedMediaUrl(authorized.toString(), baseUrl: baseUrl) ||
        _mediaIdentity(authorized.path) != _mediaIdentity(path) ||
        authorized.fragment.isNotEmpty ||
        (authorized.queryParameters['media_token'] ?? '').isEmpty) {
      throw StateError('Invalid media authorization');
    }
    return authorized.toString();
  }

  static String _mediaIdentity(String path) {
    final decoded = Uri.decodeComponent(path);
    if (!decoded.startsWith('/stream/')) return decoded;
    final sourceUrl =
        _canonicalYouTubeUrl(decoded.substring('/stream/'.length));
    return sourceUrl == null
        ? decoded
        : '/stream/${Uri.parse(sourceUrl).queryParameters['v']}';
  }

  /// Resolve supported YouTube aliases or a same-origin backend stream to the
  /// exact canonical source. This never searches or retains media credentials.
  static String? canonicalYouTubeSource(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return youtubeSourceFromMediaUrl(value) ?? _canonicalYouTubeUrl(value);
    } on FormatException {
      return null;
    }
  }

  static String? _canonicalYouTubeUrl(String value) {
    final source = Uri.tryParse(value);
    if (source == null ||
        source.userInfo.isNotEmpty ||
        !const ['http', 'https'].contains(source.scheme) ||
        (source.hasPort &&
            source.port != (source.scheme == 'https' ? 443 : 80))) {
      return null;
    }
    String? videoId;
    if (source.host == 'youtu.be') {
      videoId =
          source.pathSegments.length == 1 ? source.pathSegments.first : null;
    } else if (const [
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com'
    ].contains(source.host)) {
      if (source.path == '/watch') {
        videoId = source.queryParameters['v'];
      } else if (source.pathSegments.length == 2 &&
          const ['shorts', 'embed', 'live']
              .contains(source.pathSegments.first)) {
        videoId = source.pathSegments.last;
      }
    }
    return videoId != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)
        ? 'https://www.youtube.com/watch?v=$videoId'
        : null;
  }

  static bool isProtectedMediaUrl(String url, {String? baseUrl}) {
    final uri = Uri.tryParse(url);
    final backend = Uri.parse(baseUrl ?? AppConfig.apiBaseUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.scheme != backend.scheme ||
        uri.host != backend.host ||
        uri.port != backend.port) {
      return false;
    }
    return uri.path.startsWith('/downloads/') ||
        uri.path.startsWith('/stream/');
  }

  /// Discard expired media capabilities from old persisted URLs before reuse.
  static String canonicalMediaUrl(String url, {String? baseUrl}) {
    final backend = Uri.parse(baseUrl ?? AppConfig.apiBaseUrl);
    var uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (!uri.hasAuthority && uri.path.startsWith('/')) {
      uri = backend.resolveUri(uri);
    }
    if (!isProtectedMediaUrl(uri.toString(), baseUrl: baseUrl)) return url;
    return uri.toString().split('?').first.split('#').first;
  }

  /// Recover the exact source from a canonical backend stream for later saving.
  static String? youtubeSourceFromMediaUrl(String url) {
    final canonical = canonicalMediaUrl(url);
    if (!isProtectedMediaUrl(canonical)) return null;
    final identity = _mediaIdentity(Uri.parse(canonical).path);
    final match = RegExp(r'^/stream/([A-Za-z0-9_-]{11})$').firstMatch(identity);
    return match == null ? null : 'https://www.youtube.com/watch?v=${match[1]}';
  }

  /// A non-secret account scope for ignoring responses from an earlier login.
  String get sessionScope => _client.cacheScope;

  /// Resolve metadata through the account's saved source choice and the
  /// backend's recording-aware matcher. Existing YouTube sources still consult
  /// the saved choice, so correcting a recording also fixes older playlist rows.
  Future<String?> resolveToYouTubeUrl(
    String? url,
    String title,
    String? artist, {
    String? album,
    double? duration,
    String? spotifyId,
  }) async {
    if (title.trim().isEmpty) return canonicalYouTubeSource(url);
    try {
      final session = sessionScope;
      final response = await _client
          .post(
            Uri.parse('$baseUrl/search/resolve'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(_sourceIdentity(
              title: title,
              artist: artist,
              album: album,
              duration: duration,
              spotifyId: spotifyId,
              url: url,
            )),
          )
          .timeout(const Duration(seconds: 20));
      _checkSourceResponse(response, session);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return canonicalYouTubeSource(data['url'] as String?);
    } catch (_) {
      return null;
    }
  }

  Future<SourceCandidates> sourceCandidates({
    required String title,
    String? artist,
    String? album,
    double? duration,
    String? spotifyId,
    String? url,
  }) async {
    final session = sessionScope;
    final response = await _client
        .post(
          Uri.parse('$baseUrl/search/candidates'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(_sourceIdentity(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            spotifyId: spotifyId,
            url: url,
          )),
        )
        .timeout(const Duration(seconds: 20));
    _checkSourceResponse(response, session);
    return SourceCandidates.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> rememberSource({
    required String title,
    required String url,
    String? artist,
    String? album,
    double? duration,
    String? spotifyId,
  }) async {
    final canonical = canonicalYouTubeSource(url);
    if (canonical == null) {
      throw const SourceMatchException('Choose a valid YouTube recording.');
    }
    final session = sessionScope;
    final response = await _client
        .put(
          Uri.parse('$baseUrl/search/source'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(_sourceIdentity(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            spotifyId: spotifyId,
            url: canonical,
          )),
        )
        .timeout(const Duration(seconds: 20));
    _checkSourceResponse(response, session);
  }

  Future<void> resetSource({
    required String title,
    String? artist,
    String? album,
    double? duration,
    String? spotifyId,
  }) async {
    final session = sessionScope;
    final response = await _client
        .delete(
          Uri.parse('$baseUrl/search/source'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(_sourceIdentity(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            spotifyId: spotifyId,
          )),
        )
        .timeout(const Duration(seconds: 20));
    _checkSourceResponse(response, session);
  }

  static String? spotifyTrackId(String? url, {String? id}) {
    if (id?.startsWith('track_') == true) id = id!.substring('track_'.length);
    if (id != null && RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(id)) return id;
    final uri = Uri.tryParse(url ?? '');
    if (uri?.scheme == 'spotify' &&
        RegExp(r'^track:[A-Za-z0-9]{22}$').hasMatch(uri!.path)) {
      return uri.path.substring('track:'.length);
    }
    if (uri?.host == 'open.spotify.com' &&
        uri!.pathSegments.length == 2 &&
        uri.pathSegments.first == 'track' &&
        RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(uri.pathSegments.last)) {
      return uri.pathSegments.last;
    }
    return null;
  }

  Map<String, dynamic> _sourceIdentity({
    required String title,
    String? artist,
    String? album,
    double? duration,
    String? spotifyId,
    String? url,
  }) =>
      {
        'title': title.trim(),
        'artist': artist?.trim() ?? '',
        if (album?.trim().isNotEmpty == true) 'album': album!.trim(),
        if (duration != null && duration.isFinite && duration > 0)
          'duration': duration,
        if (spotifyId?.isNotEmpty == true || spotifyTrackId(url) != null)
          'spotify_id':
              spotifyId?.isNotEmpty == true ? spotifyId : spotifyTrackId(url),
        if (url?.isNotEmpty == true) 'url': url,
      };

  void _checkSourceResponse(http.Response response, String session) {
    if (session != sessionScope) {
      throw const SourceMatchException(
          'Your account changed. Open the recording picker again.');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    String message = 'Could not load recording choices. Please try again.';
    try {
      final detail = jsonDecode(response.body)['detail'];
      if (detail is String && detail.isNotEmpty) message = detail;
    } catch (_) {}
    throw SourceMatchException(message);
  }

  Future<List<VideoInfo>> searchYoutube(String query) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/search'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': query,
          'duration_min': 0,
          'duration_max': 600,
        }),
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((item) => VideoInfo.fromJson(item)).toList();
      } else {
        throw Exception('Failed to search: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Search error: $e');
    }
  }

  Future<StreamResult> getStreamingUrl({
    required String url,
    required String title,
    String artist = '',
  }) async {
    try {
      // Encode the YouTube URL for use in the proxy endpoint
      final encodedUrl = Uri.encodeComponent(url);
      // Return the proxied streaming URL (backend will handle the actual streaming)
      return StreamResult(
        success: true,
        streamingUrl: '$baseUrl/stream/$encodedUrl',
        title: title,
        artist: artist,
      );
    } catch (e) {
      throw Exception('Stream error: $e');
    }
  }

  /// Resolve song metadata from YouTube title via the backend's multi-layered
  /// strategy (yt-dlp structured metadata, Spotify validation, regex fallback).
  Future<Map<String, String>> cleanMetadata({
    required String title,
    String uploader = '',
    String videoId = '',
    String videoUrl = '',
  }) async {
    try {
      final uri =
          Uri.parse('$baseUrl/clean-metadata').replace(queryParameters: {
        'title': title,
        if (uploader.isNotEmpty) 'uploader': uploader,
        if (videoId.isNotEmpty) 'video_id': videoId,
        if (videoUrl.isNotEmpty) 'video_url': videoUrl,
      });
      final response = await _client.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'title': data['title'] as String? ?? title,
          'artist': data['artist'] as String? ?? uploader,
          'album': data['album'] as String? ?? '',
          'spotify_id': data['spotify_id'] as String? ?? '',
          'thumbnail': data['thumbnail'] as String? ?? '',
          'source': data['source'] as String? ?? '',
        };
      }
    } catch (_) {}
    return {'title': title, 'artist': uploader};
  }

  Future<DownloadResult> downloadAudio({
    required String url,
    required String title,
    String artist = '',
    String album = '',
    String outputFormat = 'm4a',
    bool embedThumbnail = false,
    String? spotifyId,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'url': url,
          'title': title,
          'artist': artist,
          'album': album,
          'output_format': outputFormat,
          'embed_thumbnail': embedThumbnail,
          if (spotifyId != null) 'spotify_id': spotifyId,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return DownloadResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Download failed');
      }
    } catch (e) {
      throw Exception('Download error: $e');
    }
  }

  Future<List<DownloadedFile>> listDownloads() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/downloads'));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> files = data['files'];
        return files.map((item) => DownloadedFile.fromJson(item)).toList();
      } else {
        throw Exception('Failed to list downloads: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('List downloads error: $e');
    }
  }

  Future<void> deleteDownload(String filename) async {
    try {
      final encodedFilename = Uri.encodeComponent(filename);
      final response = await _client
          .delete(Uri.parse('$baseUrl/downloads/$encodedFilename'));

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Delete failed');
      }
    } catch (e) {
      throw Exception('Delete error: $e');
    }
  }

  Future<Map<String, dynamic>> startBatchDownload(
      List<Map<String, dynamic>> downloads) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/downloads/batch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'downloads': downloads,
        }),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Batch download failed');
      }
    } catch (e) {
      throw Exception('Batch download error: $e');
    }
  }

  Future<DownloadProgress> getDownloadProgress(String downloadId) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/downloads/progress/$downloadId'));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return DownloadProgress.fromJson(data);
      } else {
        throw Exception('Failed to get progress: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Get download progress error: $e');
    }
  }

  // CSV Upload and Conversion
  Future<CsvUploadResult> uploadCsv(String filePath) async {
    try {
      final file = await http.MultipartFile.fromPath('file', filePath);
      final request =
          _client.multipartRequest('POST', Uri.parse('$baseUrl/csv/upload'));
      request.files.add(file);
      final response = await _client.sendMultipart(request);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvUploadResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Upload failed');
      }
    } catch (e) {
      throw Exception('CSV upload error: $e');
    }
  }

  Future<CsvUploadResult> uploadCsvBytes(
      List<int> fileBytes, String filename) async {
    try {
      final file = http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: filename,
      );
      final request =
          _client.multipartRequest('POST', Uri.parse('$baseUrl/csv/upload'));
      request.files.add(file);
      final response = await _client.sendMultipart(request);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvUploadResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Upload failed');
      }
    } catch (e) {
      throw Exception('CSV upload error: $e');
    }
  }

  Future<CsvProgress> getCsvProgress(String filename) async {
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/csv/progress/$filename'));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvProgress.fromJson(data);
      } else {
        throw Exception('Failed to get progress: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Get progress error: $e');
    }
  }

  Future<CsvConversionResult> convertCsv(
    String filename, {
    int durationMin = 0,
    double durationMax = 600,
    bool excludeInstrumentals = false,
    List<String> variants = const [],
  }) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/csv/convert/$filename'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'duration_min': durationMin,
          'duration_max': durationMax,
          'exclude_instrumentals': excludeInstrumentals,
          'variants': variants,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvConversionResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Conversion failed');
      }
    } catch (e) {
      throw Exception('CSV conversion error: $e');
    }
  }

  Future<void> addSongToPlaylist(
      String playlistId, Map<String, dynamic> songData) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/playlists/$playlistId/songs'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(songData),
      );

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to add song');
      }
    } catch (e) {
      throw Exception('Add song error: $e');
    }
  }

  Future<List<CsvConvertedFile>> listCsvFiles(String playlistName) async {
    try {
      final encodedName = Uri.encodeComponent(playlistName);
      final response =
          await _client.get(Uri.parse('$baseUrl/csv/files/$encodedName'));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> files = data['files'];
        return files.map((item) => CsvConvertedFile.fromJson(item)).toList();
      } else {
        throw Exception('Failed to list CSV files: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('List CSV files error: $e');
    }
  }

  /// Get album artwork URL from a downloaded file
  String getFileArtworkUrl(String filename) {
    final encodedFilename = Uri.encodeComponent(filename);
    return '$baseUrl/downloads/$encodedFilename/artwork';
  }

  /// Fetch album cover URL from iTunes API based on track metadata
  Future<String?> fetchAlbumCover({
    required String title,
    String artist = '',
    String album = '',
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/album-cover').replace(queryParameters: {
        'title': title,
        if (artist.isNotEmpty) 'artist': artist,
        if (album.isNotEmpty) 'album': album,
      });

      final response = await _client.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['artwork_url'] as String?;
      } else {
        return null;
      }
    } catch (e) {
      print('Error fetching album cover: $e');
      return null;
    }
  }
}

class VideoInfo {
  final String id;
  final String title;
  final String uploader;
  final double duration;
  final String url;
  final String thumbnail;
  final String? filename;
  final String? album;
  final String? recordingType;
  final String? recordingLabel;

  VideoInfo({
    required this.id,
    required this.title,
    required this.uploader,
    required this.duration,
    required this.url,
    required this.thumbnail,
    this.filename,
    this.album,
    this.recordingType,
    this.recordingLabel,
  });

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    return VideoInfo(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      uploader: json['uploader'] ?? '',
      duration: (json['duration'] ?? 0).toDouble(),
      url: json['url'] ?? '',
      thumbnail: json['thumbnail'] ?? '',
      filename: json['filename'] as String?,
      album: json['album'] as String?,
      recordingType: json['recording_type'] as String?,
      recordingLabel: json['recording_label'] as String?,
    );
  }

  factory VideoInfo.fromPlaylistTrack(PlaylistTrack track) => VideoInfo(
        id: track.id,
        title: track.title,
        uploader: track.artist ?? 'Unknown',
        duration: track.duration ?? 0,
        url: track.url ?? '',
        thumbnail: track.thumbnail ?? '',
        filename: track.filename.isEmpty ? null : track.filename,
        album: track.album,
      );

  String get formattedDuration {
    final minutes = (duration / 60).floor();
    final seconds = (duration % 60).floor();
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
  }

  String get recordingDescription =>
      recordingLabel ??
      recordingTypeLabel(
          recordingType ?? inferRecordingType('$title ${album ?? ''}'));

  /// Labels describe explicit metadata only; an unmarked video is not proof of
  /// a studio recording. Keep that distinction visible in the recording picker.
  static String inferRecordingType(String value) {
    const patterns = {
      'live':
          r'(?:\blive\s+(?:at|from|in|on|version|performance|session|recording)\b|[\[(\-–—]\s*live\b|\blive\s*[\])]|\bin concert\b)',
      'remix':
          r'\b(?:remix(?:ed)?|rework|sped up|slowed(?: down)?|nightcore)\b',
      'acoustic': r'\b(?:acoustic|unplugged)\b',
      'instrumental': r'\binstrumental\b',
      'karaoke': r'\bkaraoke\b',
      'cover': r'\bcover(?:ed by| version)?\b',
      'studio': r'\bstudio (?:version|recording)\b',
    };
    for (final entry in patterns.entries) {
      if (RegExp(entry.value, caseSensitive: false).hasMatch(value)) {
        return entry.key;
      }
    }
    return 'unspecified';
  }

  static String recordingTypeLabel(String type) =>
      const {
        'live': 'Live',
        'remix': 'Remix',
        'acoustic': 'Acoustic',
        'instrumental': 'Instrumental',
        'cover': 'Cover',
        'karaoke': 'Karaoke',
        'studio': 'Studio',
        'original': 'Original release',
        'unspecified': 'Version unverified',
      }[type] ??
      'Version unverified';
}

class SourceCandidates {
  final List<VideoInfo> candidates;
  final String? selectedUrl;
  final bool remembered;
  final List<String> warnings;

  const SourceCandidates({
    required this.candidates,
    this.selectedUrl,
    this.remembered = false,
    this.warnings = const [],
  });

  factory SourceCandidates.fromJson(Map<String, dynamic> json) =>
      SourceCandidates(
        candidates: (json['candidates'] as List<dynamic>? ?? [])
            .map((item) => VideoInfo.fromJson(item as Map<String, dynamic>))
            .where(
                (item) => ApiService.canonicalYouTubeSource(item.url) != null)
            .toList(),
        selectedUrl:
            ApiService.canonicalYouTubeSource(json['selected_url'] as String?),
        remembered: json['remembered'] == true,
        warnings: (json['warnings'] as List<dynamic>? ?? [])
            .whereType<String>()
            .toList(),
      );
}

class SourceMatchException implements Exception {
  final String message;
  const SourceMatchException(this.message);

  @override
  String toString() => message;
}

class StreamResult {
  final bool success;
  final String streamingUrl;
  final String title;
  final String artist;

  StreamResult({
    required this.success,
    required this.streamingUrl,
    required this.title,
    required this.artist,
  });

  factory StreamResult.fromJson(Map<String, dynamic> json) {
    return StreamResult(
      success: json['success'] ?? false,
      streamingUrl: json['streaming_url'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
    );
  }
}

class DownloadResult {
  final bool success;
  final String filePath;
  final String filename;
  final String title;
  final String artist;
  final String album;

  DownloadResult({
    required this.success,
    required this.filePath,
    required this.filename,
    required this.title,
    required this.artist,
    required this.album,
  });

  factory DownloadResult.fromJson(Map<String, dynamic> json) {
    return DownloadResult(
      success: json['success'] ?? false,
      filePath: json['file_path'] ?? '',
      filename: json['filename'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
      album: json['album'] ?? '',
    );
  }
}

class DownloadedFile {
  final String filename;
  final String filePath;
  final int size;
  final String? title;
  final String? artist;

  DownloadedFile({
    required this.filename,
    required this.filePath,
    required this.size,
    this.title,
    this.artist,
  });

  factory DownloadedFile.fromJson(Map<String, dynamic> json) {
    return DownloadedFile(
      filename: json['filename'] ?? '',
      filePath: json['file_path'] ?? '',
      size: json['size'] ?? 0,
      title: json['title'],
      artist: json['artist'],
    );
  }

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class CsvUploadResult {
  final bool success;
  final String filename;
  final String filePath;

  CsvUploadResult({
    required this.success,
    required this.filename,
    required this.filePath,
  });

  factory CsvUploadResult.fromJson(Map<String, dynamic> json) {
    return CsvUploadResult(
      success: json['success'] ?? false,
      filename: json['filename'] ?? '',
      filePath: json['file_path'] ?? '',
    );
  }
}

class CsvConversionResult {
  final bool success;
  final List<Map<String, dynamic>> tracks;
  final List<Map<String, dynamic>> notFound;
  final int total;
  final int successCount;
  final String? playlistId;
  final String? playlistName;
  final bool playlistCreated;

  CsvConversionResult({
    required this.success,
    required this.tracks,
    required this.notFound,
    required this.total,
    required this.successCount,
    this.playlistId,
    this.playlistName,
    this.playlistCreated = false,
  });

  factory CsvConversionResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> tracksList = json['tracks'] ?? [];
    return CsvConversionResult(
      success: json['success'] ?? false,
      tracks: List<Map<String, dynamic>>.from(tracksList),
      notFound: List<Map<String, dynamic>>.from(json['not_found'] ?? []),
      total: json['total'] ?? 0,
      successCount: json['success_count'] ?? 0,
      playlistId: json['playlist_id'],
      playlistName: json['playlist_name'],
      playlistCreated: json['playlist_created'] ?? false,
    );
  }
}

class CsvConvertedFile {
  final String filename;
  final String filePath;
  final int size;
  final String downloadUrl;

  CsvConvertedFile({
    required this.filename,
    required this.filePath,
    required this.size,
    required this.downloadUrl,
  });

  factory CsvConvertedFile.fromJson(Map<String, dynamic> json) {
    return CsvConvertedFile(
      filename: json['filename'] ?? '',
      filePath: json['file_path'] ?? '',
      size: json['size'] ?? 0,
      downloadUrl: json['download_url'] ?? '',
    );
  }

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class CsvProgress {
  final int current;
  final int total;
  final String status;
  final int processed;
  final int notFound;

  CsvProgress({
    required this.current,
    required this.total,
    required this.status,
    required this.processed,
    required this.notFound,
  });

  factory CsvProgress.fromJson(Map<String, dynamic> json) {
    return CsvProgress(
      current: json['current'] ?? 0,
      total: json['total'] ?? 0,
      status: json['status'] ?? '',
      processed: json['processed'] ?? 0,
      notFound: json['not_found'] ?? 0,
    );
  }

  bool get isCompleted => status == 'completed';
  bool get hasError => status.startsWith('error');
  double get progress => total > 0 ? current / total : 0.0;
}

class BatchDownloadRequest {
  final List<Map<String, dynamic>> downloads;

  BatchDownloadRequest({required this.downloads});

  Map<String, dynamic> toJson() {
    return {
      'downloads': downloads,
    };
  }
}

class DownloadProgress {
  final int current;
  final int total;
  final String status;
  final int processed;
  final int failed;
  final List<Map<String, dynamic>> downloads;

  DownloadProgress({
    required this.current,
    required this.total,
    required this.status,
    required this.processed,
    required this.failed,
    required this.downloads,
  });

  factory DownloadProgress.fromJson(Map<String, dynamic> json) {
    return DownloadProgress(
      current: json['current'] ?? 0,
      total: json['total'] ?? 0,
      status: json['status'] ?? '',
      processed: json['processed'] ?? 0,
      failed: json['failed'] ?? 0,
      downloads: List<Map<String, dynamic>>.from(json['downloads'] ?? []),
    );
  }

  bool get isCompleted => status == 'completed';
  bool get hasError => status.startsWith('error');
  double get progress => total > 0 ? current / total : 0.0;
}
