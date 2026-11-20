import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/server_download_service.dart';
import 'download_progress_bar.dart';

class ServerDownloadPanel extends StatelessWidget {
  final ServerDownloadService service;
  const ServerDownloadPanel({super.key, required this.service});

  static String label(DownloadProgress job) {
    if (job.isCancelling) return 'Cancelling';
    if (job.isCancelled) return 'Cancelled';
    if (job.isCompleted) {
      return job.failed > 0 ? 'Finished with failures' : 'Completed';
    }
    if (job.state == 'queued') return 'Queued';
    return 'Downloading';
  }

  Future<void> _openJobs(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Server downloads'),
          content: SizedBox(
              width: 480,
              child: ListenableBuilder(
                listenable: service,
                builder: (context, _) => ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView(shrinkWrap: true, children: [
                    if (service.message != null)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(service.message!)),
                    if (service.jobs.isEmpty)
                      const Text('No server downloads yet.'),
                    for (final job in service.jobs)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${label(job)} · ${job.total} ${job.total == 1 ? 'track' : 'tracks'}',
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                              if (job.title.isNotEmpty)
                                Text(job.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(value: job.progress),
                              const SizedBox(height: 6),
                              Text(
                                  '${job.processed} downloaded, ${job.failed} failed'),
                              if (job.isActive)
                                Text(job.status,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                              for (final result in job.downloads
                                  .where((row) => row['success'] == false)
                                  .take(3))
                                if (result['title'] is String)
                                  Text('Could not download: ${result['title']}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
                              Wrap(spacing: 8, children: [
                                if (job.isActive && !job.isCancelling)
                                  TextButton.icon(
                                      onPressed: service
                                              .isUpdating(job.downloadId)
                                          ? null
                                          : () =>
                                              service.cancel(job.downloadId),
                                      icon: const Icon(Icons.cancel_outlined),
                                      label: const Text('Cancel download')),
                                if (job.canRetry && !job.isActive)
                                  TextButton.icon(
                                      onPressed: service
                                              .isUpdating(job.downloadId)
                                          ? null
                                          : () => service.retry(job.downloadId),
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Retry unfinished')),
                              ]),
                              const Divider(),
                            ]),
                      ),
                  ]),
                ),
              )),
          actions: [
            TextButton(
                onPressed: service.refresh, child: const Text('Refresh')),
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final job = service.featuredJob;
          if (job != null) {
            return DownloadProgressBar(
              processed: job.processed,
              failed: job.failed,
              total: job.total,
              status:
                  service.message ?? (job.isActive ? job.status : label(job)),
              progress: job.progress,
              heading: 'Server downloads',
              onShowJobs: () => _openJobs(context),
            );
          }
          if (service.jobs.isEmpty && !service.hasPendingJob) {
            return const SizedBox.shrink();
          }
          return Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _openJobs(context),
                icon: const Icon(Icons.download_done),
                label: Text(service.hasPendingJob
                    ? 'Connecting to server downloads…'
                    : 'Server downloads'),
              ));
        },
      );
}
