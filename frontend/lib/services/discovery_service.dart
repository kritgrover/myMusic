import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/queue_item.dart';
import 'api_service.dart';
import 'auth_http_client.dart';

class DiscoveryArtist {
  final String id;
  final String name;
  final String? thumbnail;
  const DiscoveryArtist({required this.id, required this.name, this.thumbnail});

  factory DiscoveryArtist.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final name = value['name'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) {
      throw const FormatException('Invalid artist');
    }
    return DiscoveryArtist(
        id: id,
        name: name,
        thumbnail: value['thumbnail'] is String ? value['thumbnail'] : null);
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'thumbnail': thumbnail ?? ''};
}

class DiscoveryPreferences {
  static const modes = ['familiar', 'balanced', 'discover'];
  final String mode;
  final bool autoplay;
  final bool onboardingCompleted;
  final List<DiscoveryArtist> seedArtists;
  const DiscoveryPreferences(
      {this.mode = 'balanced',
      this.autoplay = false,
      this.onboardingCompleted = false,
      this.seedArtists = const []});

  factory DiscoveryPreferences.fromJson(Map<String, dynamic> value) {
    if (!modes.contains(value['mode']) ||
        value['autoplay'] is! bool ||
        value['onboarding_completed'] is! bool ||
        value['seed_artists'] is! List) {
      throw const FormatException('Invalid discovery settings');
    }
    final artists = (value['seed_artists'] as List)
        .map((row) =>
            DiscoveryArtist.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
    if (artists.length > 5) throw const FormatException('Too many artists');
    return DiscoveryPreferences(
        mode: value['mode'],
        autoplay: value['autoplay'],
        onboardingCompleted: value['onboarding_completed'],
        seedArtists: List.unmodifiable(artists));
  }
}

class RadioResult {
  final List<QueueItem> tracks;
  final String? message;
  const RadioResult(this.tracks, {this.message});
}

class DiscoveryFeedback {
  final String id;
  final QueueItem track;
  const DiscoveryFeedback(this.id, this.track);
}

class DiscoveryException implements Exception {
  final String message;
  const DiscoveryException(this.message);
  @override
  String toString() => message;
}

/// One account's discovery controls. Writes are serialized and only committed
/// after acknowledgement, so a failed save never changes the displayed choice.
class DiscoveryService extends ChangeNotifier {
  final AuthHttpClient _client;
  final String baseUrl;
  final String _scope;
  final Duration requestTimeout;
  final Duration radioRequestTimeout;
  DiscoveryPreferences _preferences = const DiscoveryPreferences();
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  int _pendingWrites = 0;
  int _revision = 0;
  bool _loaded = false;
  bool _disposed = false;
  String? _error;
  final Map<String, DiscoveryFeedback> _feedback = {};
  int _feedbackRevision = 0;

  DiscoveryService(
      {AuthHttpClient? client,
      String? baseUrl,
      this.requestTimeout = const Duration(seconds: 15),
      this.radioRequestTimeout = const Duration(seconds: 35)})
      : _client = client ?? AuthHttpClient.shared,
        baseUrl = (baseUrl ?? (client ?? AuthHttpClient.shared).baseUrl)
            .replaceFirst(RegExp(r'/+$'), ''),
        _scope = (client ?? AuthHttpClient.shared).cacheScope {
    if (radioRequestTimeout <= Duration.zero) {
      throw ArgumentError.value(radioRequestTimeout, 'radioRequestTimeout',
          'Must be a positive duration.');
    }
  }

  String get sessionScope => _client.cacheScope;
  bool get isCurrent => !_disposed && _scope == sessionScope;
  DiscoveryPreferences get preferences =>
      isCurrent ? _preferences : const DiscoveryPreferences();
  bool get isLoaded => isCurrent && _loaded;
  bool get isLoading => isCurrent && _loading != null;
  bool get isSaving => isCurrent && _pendingWrites > 0;
  String? get error => isCurrent ? _error : null;

  bool isHidden(QueueItem track) {
    if (!isCurrent) return false;
    String normalized(String? value) =>
        (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    for (final hidden in _feedback.values) {
      final leftId = trackJson(track)['spotify_id'];
      final rightId = trackJson(hidden.track)['spotify_id'];
      if (leftId != null && rightId != null) {
        if (leftId == rightId) return true;
        continue;
      }
      if (normalized(track.title) == normalized(hidden.track.title) &&
          normalized(track.artist) == normalized(hidden.track.artist) &&
          trackJson(track)['recording_type'] ==
              trackJson(hidden.track)['recording_type']) {
        return true;
      }
    }
    return false;
  }

  void _check() {
    if (!isCurrent) {
      throw const DiscoveryException(
          'The account changed. Please reopen discovery.');
    }
  }

  void _notify() {
    if (isCurrent) notifyListeners();
  }

  Map<String, dynamic> _object(http.Response response, String failure) {
    _check();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DiscoveryException(failure);
    }
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid discovery response');
    }
    return value;
  }

  Future<void> load({bool force = false}) {
    if (!isCurrent || (_loaded && !force)) return Future.value();
    if (_loading != null) return _loading!;
    final revision = _revision;
    final work = Future<void>.microtask(() async {
      try {
        final response = await _client
            .get(Uri.parse('$baseUrl/discovery/preferences'))
            .timeout(requestTimeout);
        final next = DiscoveryPreferences.fromJson(_object(
            response, 'Could not load discovery settings. Please retry.'));
        if (isCurrent && revision == _revision && !isSaving) {
          _preferences = next;
          _loaded = true;
          _error = null;
          unawaited(getFeedback().catchError((_) => <DiscoveryFeedback>[]));
        }
      } catch (_) {
        if (isCurrent && revision == _revision) {
          _error = 'Could not load discovery settings. Please retry.';
        }
      } finally {
        _loading = null;
        _notify();
      }
    });
    _loading = work;
    _notify();
    return work;
  }

  Future<void> save(
      {String? mode,
      bool? autoplay,
      bool? onboardingCompleted,
      List<DiscoveryArtist>? seedArtists}) {
    _check();
    if (mode != null && !DiscoveryPreferences.modes.contains(mode)) {
      throw ArgumentError.value(mode, 'mode');
    }
    if (seedArtists != null &&
        (seedArtists.length > 5 ||
            seedArtists.map((artist) => artist.id).toSet().length !=
                seedArtists.length)) {
      throw ArgumentError('Choose up to five different artists.');
    }
    final body = {
      if (mode != null) 'mode': mode,
      if (autoplay != null) 'autoplay': autoplay,
      if (onboardingCompleted != null)
        'onboarding_completed': onboardingCompleted,
      if (seedArtists != null)
        'seed_artists': seedArtists.map((artist) => artist.toJson()).toList(),
    };
    _pendingWrites++;
    _revision++;
    _notify();
    final work = _writes.then((_) async {
      try {
        _check();
        final response = await _client
            .patch(Uri.parse('$baseUrl/discovery/preferences'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(body))
            .timeout(requestTimeout);
        final next = DiscoveryPreferences.fromJson(_object(
            response, 'Could not save discovery settings. Please retry.'));
        _revision++;
        _preferences = next;
        _loaded = true;
        _error = null;
      } catch (_) {
        if (isCurrent) {
          _error = 'Could not save discovery settings. Please retry.';
        }
        throw const DiscoveryException(
            'Could not save discovery settings. Please retry.');
      } finally {
        _pendingWrites--;
        _notify();
      }
    });
    _writes = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  Future<List<DiscoveryArtist>> searchArtists(String query) async {
    _check();
    final clean = query.trim();
    if (clean.isEmpty) return [];
    if (clean.length > 100) {
      throw const DiscoveryException('Use a shorter artist name.');
    }
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/discovery/artists')
              .replace(queryParameters: {'q': clean}))
          .timeout(requestTimeout);
      final value =
          _object(response, 'Artist search is unavailable. Please retry.');
      if (value['artists'] is! List) {
        throw const FormatException('Invalid artist results');
      }
      return (value['artists'] as List)
          .map((row) =>
              DiscoveryArtist.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList();
    } catch (_) {
      throw const DiscoveryException(
          'Artist search is unavailable. Please retry.');
    }
  }

  static String? _filename(String? value) {
    if (value == null || value.isEmpty) return null;
    final clean = value.replaceAll('\\', '/');
    if (clean.startsWith('/') ||
        clean.contains(':') ||
        clean
            .split('/')
            .any((part) => part.isEmpty || part == '..' || part == '.')) {
      return null;
    }
    return clean;
  }

  static String? _source(QueueItem track) {
    for (final value in [track.originalUrl, track.url]) {
      if (value == null) continue;
      final youtube = ApiService.youtubeSourceFromMediaUrl(value) ??
          ApiService.canonicalYouTubeSource(value);
      if (youtube != null) return youtube;
      final spotify = ApiService.spotifyTrackId(value);
      if (spotify != null) return 'https://open.spotify.com/track/$spotify';
    }
    return null;
  }

  /// Send public recording identity and owned relative filenames, never signed
  /// media capabilities, local file URLs, or a device filesystem path.
  static Map<String, dynamic> trackJson(QueueItem track) {
    final spotify =
        ApiService.spotifyTrackId(track.originalUrl, id: track.spotifyId) ??
            ApiService.spotifyTrackId(null, id: track.id);
    final source = _source(track);
    final filename = _filename(track.filename);
    return {
      if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(track.id)) 'id': track.id,
      'title': track.title?.trim().isNotEmpty == true
          ? track.title
          : 'Unknown Track',
      'artist': track.artist?.trim().isNotEmpty == true
          ? track.artist
          : 'Unknown Artist',
      'album': track.album ?? '',
      if (spotify != null) 'spotify_id': spotify,
      if (source != null) 'url': source,
      if (filename != null) 'filename': filename,
      'recording_type': VideoInfo.inferRecordingType(
          '${track.title ?? ''} ${track.album ?? ''}'),
      if (track.duration != null &&
          track.duration!.isFinite &&
          track.duration! >= 0)
        'duration': track.duration,
    };
  }

  QueueItem _track(Map<String, dynamic> row) {
    final title = row['title'];
    if (title is! String || title.trim().isEmpty) {
      throw const FormatException('Invalid radio track');
    }
    final raw = QueueItem(
        id: row['id'] is String ? row['id'] : '',
        title: title,
        artist: row['artist'] is String ? row['artist'] : null,
        url: row['url'] is String ? row['url'] : null,
        spotifyId: row['spotify_id'] is String ? row['spotify_id'] : null);
    final art = row['thumbnail'];
    final artwork = art is String && art.startsWith('/')
        ? Uri.parse(baseUrl).resolve(art).toString()
        : art;
    return QueueItem(
        id: raw.id,
        title: title,
        artist: raw.artist,
        album: row['album'] is String ? row['album'] : null,
        filename: _filename(row['filename'] is String ? row['filename'] : null),
        originalUrl: _source(raw) ?? '',
        spotifyId: ApiService.spotifyTrackId(null, id: raw.spotifyId),
        thumbnail: artwork is String ? artwork : null,
        duration: row['duration'] is num &&
                (row['duration'] as num).isFinite &&
                row['duration'] >= 0
            ? (row['duration'] as num).toDouble()
            : null);
  }

  Future<RadioResult> radio(QueueItem seed,
      {List<QueueItem> exclude = const [], int limit = 20}) async {
    _check();
    try {
      final response = await _client
          .post(Uri.parse('$baseUrl/discovery/radio'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'seed': trackJson(seed),
                'exclude': exclude.take(100).map(trackJson).toList(),
                'limit': limit.clamp(1, 30),
              }))
          .timeout(radioRequestTimeout);
      final value =
          _object(response, 'Could not start song radio. Please retry.');
      if (value['tracks'] is! List) {
        throw const FormatException('Invalid radio response');
      }
      final tracks = (value['tracks'] as List)
          .map((row) => _track(Map<String, dynamic>.from(row as Map)))
          .toList();
      return RadioResult(List.unmodifiable(tracks),
          message: value['message'] is String ? value['message'] : null);
    } catch (_) {
      throw const DiscoveryException(
          'Could not load song radio. Please retry.');
    }
  }

  Future<String> lessLikeThis(QueueItem track) async {
    _check();
    _feedbackRevision++;
    try {
      final response = await _client
          .post(Uri.parse('$baseUrl/discovery/feedback'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(
                  {'track': trackJson(track), 'action': 'less_like_this'}))
          .timeout(requestTimeout);
      final value =
          _object(response, 'Could not save your feedback. Please retry.');
      if (value['feedback_id'] is! String ||
          (value['feedback_id'] as String).isEmpty) {
        throw const FormatException('Invalid feedback response');
      }
      final id = value['feedback_id'] as String;
      _feedbackRevision++;
      _feedback[id] = DiscoveryFeedback(id, track);
      _notify();
      return id;
    } catch (_) {
      throw const DiscoveryException(
          'Could not save your feedback. Please retry.');
    }
  }

  Future<List<DiscoveryFeedback>> getFeedback() async {
    _check();
    final revision = _feedbackRevision;
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/discovery/feedback'))
          .timeout(requestTimeout);
      final value = _object(
          response, 'Could not load hidden recommendations. Please retry.');
      if (value['feedback'] is! List) {
        throw const FormatException('Invalid feedback response');
      }
      final entries = (value['feedback'] as List).map((entry) {
        final row = Map<String, dynamic>.from(entry as Map);
        if (row['feedback_id'] is! String) {
          throw const FormatException('Invalid feedback identity');
        }
        return DiscoveryFeedback(row['feedback_id'],
            _track(Map<String, dynamic>.from(row['track'] as Map)));
      }).toList();
      if (revision == _feedbackRevision) {
        _feedback
          ..clear()
          ..addEntries(entries.map((entry) => MapEntry(entry.id, entry)));
        _notify();
      }
      return _feedback.values.toList();
    } catch (_) {
      throw const DiscoveryException(
          'Could not load hidden recommendations. Please retry.');
    }
  }

  Future<void> undoFeedback(String id) async {
    _check();
    _feedbackRevision++;
    try {
      final response = await _client
          .delete(Uri.parse(
              '$baseUrl/discovery/feedback/${Uri.encodeComponent(id)}'))
          .timeout(requestTimeout);
      _check();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const DiscoveryException(
            'Could not restore this recommendation. Please retry.');
      }
      _feedbackRevision++;
      _feedback.remove(id);
      _notify();
    } catch (_) {
      throw const DiscoveryException(
          'Could not restore this recommendation. Please retry.');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
