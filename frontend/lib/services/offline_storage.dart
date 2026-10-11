import 'offline_storage_stub.dart'
    if (dart.library.io) 'offline_storage_native.dart' as platform;

typedef OfflineStorageFactory = Future<OfflineStorage> Function(String scope);

Future<OfflineStorage> createOfflineStorage(String scope) =>
    platform.createOfflineStorage(scope);

bool get offlineStorageSupported => platform.offlineStorageSupported;

class OfflineStoredFile {
  final int bytes;
  final String checksum;
  const OfflineStoredFile(this.bytes, this.checksum);
}

class OfflineCancelled implements Exception {
  const OfflineCancelled();
}

abstract class OfflineStorage {
  Future<List<Map<String, dynamic>>> readIndex();
  Future<void> writeIndex(List<Map<String, dynamic>> entries);
  Future<void> cleanTemporaryFiles();
  Future<OfflineStoredFile> writeStream(
    String name,
    Stream<List<int>> stream, {
    int? expectedBytes,
    required bool Function() isCancelled,
    void Function(int bytes)? onProgress,
  });
  Future<void> rename(String from, String to);
  Future<bool> validate(String name, int bytes, String checksum);
  Future<bool> exists(String name);
  Future<void> delete(String name);
  String fileUrl(String name);
}
