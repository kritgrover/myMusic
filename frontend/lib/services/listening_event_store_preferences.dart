import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'listening_event_store.dart';

Future<ListeningEventStore> createStore(String scope) async =>
    PreferencesListeningEventStore(scope);

/// Browser fallback: independent entries preserve newer checkpoints on replay.
class PreferencesListeningEventStore implements ListeningEventStore {
  final String _prefix;
  final Future<SharedPreferences> Function() _preferences;
  PreferencesListeningEventStore(String scope,
      {Future<SharedPreferences> Function()? preferencesProvider})
      : _prefix = 'listening_outbox_v1_${scope}_',
        _preferences = preferencesProvider ?? SharedPreferences.getInstance;

  String _key(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(id)) {
      throw const FormatException('Invalid listening event ID');
    }
    return '$_prefix$id';
  }

  @override
  Future<List<Map<String, dynamic>>> read() =>
      ListeningStoreLock.run(_prefix, () async {
        final prefs = await _preferences();
        await prefs.reload();
        final events = <Map<String, dynamic>>[];
        for (final key
            in prefs.getKeys().where((key) => key.startsWith(_prefix))) {
          final text = prefs.get(key);
          final event =
              text is String ? decodeStoredListeningEvent(text) : null;
          if (event != null && _key(event['event_id']) == key) {
            events.add(event);
          }
        }
        return events;
      });

  @override
  Future<void> put(Map<String, dynamic> event) =>
      ListeningStoreLock.run(_prefix, () async {
        final valid = validateStoredListeningEvent(event);
        if (valid == null) {
          throw const FormatException('Invalid listening event');
        }
        final prefs = await _preferences();
        await prefs.reload();
        final key = _key(valid['event_id']);
        final text = prefs.get(key);
        final existing =
            text is String ? decodeStoredListeningEvent(text) : null;
        if (existing != null &&
            (existing['sequence'] as int) >= (valid['sequence'] as int)) {
          return;
        }
        if (!await prefs.setString(
            key, jsonEncode({'version': 1, 'event': valid}))) {
          throw StateError('Listening history could not be saved.');
        }
      });

  @override
  Future<void> acknowledge(String eventId, int sequence) =>
      ListeningStoreLock.run(_prefix, () async {
        final prefs = await _preferences();
        await prefs.reload();
        final key = _key(eventId);
        final text = prefs.get(key);
        final existing =
            text is String ? decodeStoredListeningEvent(text) : null;
        if (existing?['sequence'] == sequence && !await prefs.remove(key)) {
          throw StateError(
              'Listening history acknowledgement could not be saved.');
        }
      });
}
