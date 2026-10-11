import 'api_service.dart';
import 'offline_download_service.dart';

/// Keep canonical URLs in queues and history; resolve device paths only when
/// loading audio. A downloaded recording never needs a server capability.
class OfflineMediaResolver {
  final Future<String?> Function(String) _localUrl;
  final Future<String> Function(String) _remoteUrl;

  OfflineMediaResolver({
    Future<String?> Function(String)? localUrl,
    Future<String> Function(String)? remoteUrl,
  })  : _localUrl = localUrl ?? OfflineDownloadService.shared.localUrlFor,
        _remoteUrl = remoteUrl ?? ApiService().authorizeMediaUrl;

  Future<String> resolve(String canonicalUrl) async {
    final local = await _localUrl(canonicalUrl);
    return local ?? await _remoteUrl(canonicalUrl);
  }
}
