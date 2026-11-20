import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'listening_event_store.dart';

Future<ListeningEventStore> createStore(String scope) async =>
    NativeListeningEventStore(() async => Directory(
        '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}'
        'listening-history${Platform.pathSeparator}$scope'));

/// One small atomic file per occurrence; offline history has no lossy event cap.
class NativeListeningEventStore implements ListeningEventStore {
  final Future<Directory> Function() _directoryProvider;
  Future<Directory>? _directory;
  NativeListeningEventStore(this._directoryProvider);
  NativeListeningEventStore.inDirectory(Directory directory)
      : _directoryProvider = (() async => directory);

  Future<Directory> _folder() async {
    try {
      return await (_directory ??= _directoryProvider().then((folder) async {
        await folder.create(recursive: true);
        return folder;
      }));
    } catch (_) {
      _directory = null;
      rethrow;
    }
  }

  File _eventFile(Directory folder, String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(id)) {
      throw const FormatException('Invalid listening event ID');
    }
    return File('${folder.path}${Platform.pathSeparator}$id.json');
  }

  Future<Map<String, dynamic>?> _readFile(File file) async {
    try {
      if (!await file.exists()) return null;
      if (await file.length() > 16384) return null;
      return decodeStoredListeningEvent(await file.readAsString());
    } on FileSystemException {
      // An overlapping acknowledgement may have removed this file.
      if (!await file.exists()) return null;
      rethrow;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> read() async {
    final folder = await _folder();
    return ListeningStoreLock.run(folder.absolute.path, () async {
      final events = <Map<String, dynamic>>[];
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final event = await _readFile(entry);
        if (event != null &&
            _eventFile(folder, event['event_id']).path == entry.path) {
          events.add(event);
        }
      }
      events.sort((a, b) => (a['started_at'] as String? ?? '')
          .compareTo(b['started_at'] as String? ?? ''));
      return events;
    });
  }

  @override
  Future<void> put(Map<String, dynamic> event) async {
    final valid = validateStoredListeningEvent(event);
    if (valid == null) throw const FormatException('Invalid listening event');
    final folder = await _folder();
    await ListeningStoreLock.run(folder.absolute.path, () async {
      final file = _eventFile(folder, valid['event_id']);
      final existing = await _readFile(file);
      if (existing != null &&
          (existing['sequence'] as int) >= (valid['sequence'] as int)) {
        return;
      }
      final temporary = File('${file.path}.part');
      try {
        await temporary.writeAsString(
            jsonEncode({'version': 1, 'event': valid}),
            flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
  }

  @override
  Future<void> acknowledge(String eventId, int sequence) async {
    final folder = await _folder();
    await ListeningStoreLock.run(folder.absolute.path, () async {
      final file = _eventFile(folder, eventId);
      if ((await _readFile(file))?['sequence'] == sequence) await file.delete();
    });
  }
}
