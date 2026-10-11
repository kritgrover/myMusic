import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_storage.dart';

const bool offlineStorageSupported = true;

Future<OfflineStorage> createOfflineStorage(String scope) async =>
    NativeOfflineStorage.open(
        Directory('${(await getApplicationSupportDirectory()).path}'
            '${Platform.pathSeparator}offline${Platform.pathSeparator}$scope'));

/// File names are opaque hashes, never backend paths or user input.
class NativeOfflineStorage implements OfflineStorage {
  final Directory directory;
  final Map<String, (int, DateTime, DateTime, String)> _validated = {};
  NativeOfflineStorage._(this.directory);

  static Future<NativeOfflineStorage> open(Directory directory) async {
    await directory.create(recursive: true);
    return NativeOfflineStorage._(directory);
  }

  File _file(String name) {
    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name) ||
        name == '.' ||
        name == '..') {
      throw const FormatException('Invalid offline file name');
    }
    return File('${directory.path}${Platform.pathSeparator}$name');
  }

  @override
  Future<List<Map<String, dynamic>>> readIndex() async {
    final file = _file('index.json');
    if (!await file.exists()) return [];
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['version'] != 1) return [];
      return (data['tracks'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    }
  }

  @override
  Future<void> writeIndex(List<Map<String, dynamic>> entries) async {
    final temp = _file('index.json.part');
    await temp.writeAsString(jsonEncode({'version': 1, 'tracks': entries}),
        flush: true);
    await temp.rename(_file('index.json').path);
  }

  @override
  Future<void> cleanTemporaryFiles() async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.part')) {
        try {
          await entity.delete();
        } on FileSystemException {/* In use. */}
      }
    }
  }

  @override
  Future<OfflineStoredFile> writeStream(
    String name,
    Stream<List<int>> stream, {
    int? expectedBytes,
    required bool Function() isCancelled,
    void Function(int bytes)? onProgress,
  }) async {
    final file = _file(name);
    final sink = file.openWrite();
    var count = 0;
    try {
      await sink.addStream(stream.map((chunk) {
        if (isCancelled()) throw const OfflineCancelled();
        count += chunk.length;
        onProgress?.call(count);
        return chunk;
      }));
      await sink.flush();
      await sink.close();
      if (isCancelled()) throw const OfflineCancelled();
      if (count == 0 || (expectedBytes != null && count != expectedBytes)) {
        throw const FormatException('Incomplete download. Please retry.');
      }
      final digest = await sha256.bind(file.openRead()).first;
      if (isCancelled()) throw const OfflineCancelled();
      return OfflineStoredFile(count, digest.toString());
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    await _file(from).rename(_file(to).path);
  }

  @override
  Future<bool> validate(String name, int bytes, String checksum) async {
    try {
      final file = _file(name);
      final stat = await file.stat();
      if (bytes <= 0 ||
          checksum.isEmpty ||
          stat.type != FileSystemEntityType.file ||
          stat.size != bytes) {
        _validated.remove(name);
        return false;
      }
      final modified = await file.lastModified();
      final signature = (bytes, modified, stat.changed, checksum);
      // Some file systems round timestamps to seconds. Rehash during that
      // timestamp bucket so a same-size rewrite cannot reuse a stale result.
      final stableTimestamp =
          DateTime.now().difference(modified) > const Duration(seconds: 2);
      if (_validated[name] == signature && stableTimestamp) return true;
      final valid =
          (await sha256.bind(file.openRead()).first).toString() == checksum;
      if (valid) _validated[name] = signature;
      return valid;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  @override
  Future<bool> exists(String name) async => _file(name).exists();

  @override
  Future<void> delete(String name) async {
    _validated.remove(name);
    final file = _file(name);
    if (await file.exists()) await file.delete();
  }

  @override
  String fileUrl(String name) => _file(name).uri.toString();
}
