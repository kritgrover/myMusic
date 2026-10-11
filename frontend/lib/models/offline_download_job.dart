import 'queue_item.dart';

enum OfflineDownloadStatus {
  queued,
  preparing,
  downloading,
  failed,
  cancelled,
  complete,
}

class OfflineDownloadJob {
  final String id;
  final QueueItem track;
  final OfflineDownloadStatus status;
  final double? progress;
  final String? error;

  const OfflineDownloadJob(
      {required this.id,
      required this.track,
      required this.status,
      this.progress,
      this.error});
}
