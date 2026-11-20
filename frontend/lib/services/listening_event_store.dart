import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'listening_event_store_preferences.dart'
    if (dart.library.io) 'listening_event_store_native.dart' as platform;

/// Stable account storage deliberately excludes access tokens/session revisions.
Future<ListeningEventStore> createListeningEventStore({
  required int userId,
  required String baseUrl,
}) async {
  if (userId < 1 || baseUrl.trim().isEmpty) {
    throw ArgumentError(
        'A backend and account are required for listening history.');
  }
  return platform
      .createStore(listeningEventScope(userId: userId, baseUrl: baseUrl));
}

String listeningEventScope({required int userId, required String baseUrl}) =>
    '${sha256.convert(utf8.encode(baseUrl.replaceFirst(RegExp(r'/+$'), '')))}_$userId';

abstract class ListeningEventStore {
  Future<List<Map<String, dynamic>>> read();
  Future<void> put(Map<String, dynamic> event);

  /// Remove exactly the acknowledged checkpoint, never a newer one.
  Future<void> acknowledge(String eventId, int sequence);
}

/// Shared by storage instances during logout/relogin in one running app.
/// Mutations compare event sequences inside this lock, not in a stale snapshot.
class ListeningStoreLock {
  static final Map<String, Future<void>> _tails = {};

  static Future<T> run<T>(String key, Future<T> Function() action) {
    final previous = _tails[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tails[key] = tail;
    unawaited(tail.then((_) {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }));
    return result;
  }
}

Map<String, dynamic>? validateStoredListeningEvent(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['event_id'];
  final sequence = raw['sequence'];
  final title = raw['song_title'];
  final artist = raw['artist'];
  final reason = raw['end_reason'];
  if (id is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(id) ||
      sequence is! int ||
      sequence < 1 ||
      sequence > 2147483647 ||
      title is! String ||
      artist is! String ||
      title.trim().isEmpty ||
      artist.trim().isEmpty ||
      title.runes.length > 300 ||
      artist.runes.length > 300 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(title + artist) ||
      !const {'ongoing', 'paused', 'completed', 'skipped', 'stopped', 'error'}
          .contains(reason)) {
    return null;
  }
  final result = <String, dynamic>{
    'event_id': id,
    'sequence': sequence,
    'song_title': title,
    'artist': artist,
    'end_reason': reason,
  };
  for (final field in ['duration_seconds', 'listened_seconds']) {
    final value = raw[field];
    if (value is! num || !value.isFinite || value < 0 || value > 86400) {
      return null;
    }
    result[field] = value;
  }
  final source = raw['source_url'];
  if (source != null && source != '') {
    if (source is! String ||
        !RegExp(r'^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$')
            .hasMatch(source)) {
      return null;
    }
    result['source_url'] = source;
  }
  final spotify = raw['spotify_id'];
  if (spotify != null && spotify != '') {
    if (spotify is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(spotify)) {
      return null;
    }
    result['spotify_id'] = spotify;
  }
  final started = raw['started_at'];
  if (started != null) {
    if (started is! String ||
        started.length > 64 ||
        !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(started)) {
      return null;
    }
    final time = DateTime.tryParse(started);
    if (time == null || time.toUtc().year < 1970 || time.toUtc().year > 9999) {
      return null;
    }
    result['started_at'] = time.toUtc().toIso8601String();
  }
  return Map.unmodifiable(result);
}

Map<String, dynamic>? decodeStoredListeningEvent(String text) {
  try {
    if (text.length > 16384) return null;
    final raw = jsonDecode(text);
    return raw is Map && raw['version'] == 1
        ? validateStoredListeningEvent(raw['event'])
        : null;
  } on FormatException {
    return null;
  }
}

/// Used by callers that deliberately do not enable persistent account storage.
class MemoryListeningEventStore implements ListeningEventStore {
  final Map<String, Map<String, dynamic>> _events = {};
  @override
  Future<List<Map<String, dynamic>>> read() async => _events.values.toList();
  @override
  Future<void> put(Map<String, dynamic> event) async {
    final valid = validateStoredListeningEvent(event);
    if (valid == null) throw const FormatException('Invalid listening event');
    final existing = _events[valid['event_id']];
    if (existing == null ||
        (existing['sequence'] as int) < (valid['sequence'] as int)) {
      _events[valid['event_id']] = valid;
    }
  }

  @override
  Future<void> acknowledge(String eventId, int sequence) async {
    if (_events[eventId]?['sequence'] == sequence) _events.remove(eventId);
  }
}
