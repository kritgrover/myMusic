import 'package:flutter/material.dart';
import '../services/queue_service.dart';

class PlaybackSettingsSheet extends StatelessWidget {
  final QueueService queue;
  const PlaybackSettingsSheet({super.key, required this.queue});

  String _durationLabel(double seconds) => seconds == 0
      ? 'Off'
      : '${seconds.round()} ${seconds.round() == 1 ? 'second' : 'seconds'}';

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ListenableBuilder(
            listenable: queue,
            builder: (context, _) {
              final seconds = queue.crossfadeDuration.inMilliseconds / 1000;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Expanded(
                      child: Text('Playback settings',
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                        tooltip: 'Close playback settings',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close)),
                  ]),
                  const SizedBox(height: 24),
                  Row(children: [
                    const Icon(Icons.graphic_eq),
                    const SizedBox(width: 12),
                    const Expanded(
                        child: Text('Crossfade',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600))),
                    Text(_durationLabel(seconds)),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                      seconds == 0
                          ? 'Let tracks flow into each other with gapless playback.'
                          : 'Blend the end of each track into the next. Short tracks use a shorter fade.',
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  Semantics(
                    label: 'Crossfade duration',
                    child: Slider(
                      value: seconds.clamp(0, 12),
                      min: 0,
                      max: 12,
                      divisions: 12,
                      label: _durationLabel(seconds),
                      semanticFormatterCallback: (value) => value == 0
                          ? 'Off, gapless playback'
                          : _durationLabel(value),
                      onChanged: (value) => queue.setCrossfadeDuration(
                          Duration(seconds: value.round())),
                    ),
                  ),
                  const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [Text('Off'), Text('12 seconds')]),
                  const SizedBox(height: 16),
                ],
              );
            },
          ),
        ),
      );
}
