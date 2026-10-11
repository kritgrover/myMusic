import 'offline_storage.dart';

const bool offlineStorageSupported = false;

Future<OfflineStorage> createOfflineStorage(String scope) =>
    Future.error(UnsupportedError('Device downloads require the native app.'));
