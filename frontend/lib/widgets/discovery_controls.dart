import 'package:flutter/material.dart';
import '../services/discovery_service.dart';
import 'artist_picker_dialog.dart';

class DiscoveryControls extends StatelessWidget {
  final DiscoveryService service;
  final Future<void> Function()? onChanged;
  const DiscoveryControls({super.key, required this.service, this.onChanged});

  Future<void> _save({String? mode, bool? autoplay, bool? skip}) async {
    try {
      await service.save(
          mode: mode, autoplay: autoplay, onboardingCompleted: skip);
      if (autoplay == null) await onChanged?.call();
    } catch (_) {
      // The service retains the confirmed choice and exposes a retry message.
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (!service.isLoaded) {
          if (service.error == null) return const SizedBox.shrink();
          return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(service.error!),
                    TextButton(
                        onPressed: service.isLoading
                            ? null
                            : () => service.load(force: true),
                        child: const Text('Retry settings')),
                  ]));
        }
        final prefs = service.preferences;
        final busy = service.isSaving;
        return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Make it yours',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        const Text(
                            'Choose the balance for your recommendations.'),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 6, children: [
                          for (final choice in const [
                            ('familiar', 'Familiar'),
                            ('balanced', 'Balanced'),
                            ('discover', 'Discover')
                          ])
                            ChoiceChip(
                                label: Text(choice.$2),
                                selected: prefs.mode == choice.$1,
                                onSelected: busy
                                    ? null
                                    : (selected) {
                                        if (selected) _save(mode: choice.$1);
                                      }),
                        ]),
                        SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Keep the music going'),
                            subtitle: const Text(
                                'Play suggested songs after your queue ends.'),
                            value: prefs.autoplay,
                            onChanged: busy
                                ? null
                                : (value) => _save(autoplay: value)),
                        if (!prefs.onboardingCompleted) ...[
                          const Divider(),
                          Text('Start with artists you love',
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 4),
                          const Text(
                              'A few favorites help us find music for you, even before your first listen.'),
                          Wrap(spacing: 8, children: [
                            FilledButton.tonalIcon(
                                onPressed: busy
                                    ? null
                                    : () => showArtistPicker(context,
                                        service: service, onSaved: onChanged),
                                icon: const Icon(Icons.person_add_alt),
                                label: const Text('Choose artists')),
                            TextButton(
                                onPressed:
                                    busy ? null : () => _save(skip: true),
                                child: const Text('Skip for now')),
                          ]),
                        ] else ...[
                          if (prefs.seedArtists.isNotEmpty)
                            Text(
                                'Inspired by ${prefs.seedArtists.map((artist) => artist.name).join(', ')}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                          Wrap(spacing: 8, children: [
                            TextButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => showArtistPicker(context,
                                        service: service, onSaved: onChanged),
                                icon: const Icon(Icons.tune),
                                label: const Text('Choose artists')),
                          ]),
                        ],
                        TextButton.icon(
                            onPressed: () => showDialog<void>(
                                context: context,
                                builder: (_) => _HiddenRecommendationsDialog(
                                    service: service, onChanged: onChanged)),
                            icon: const Icon(Icons.visibility_off_outlined),
                            label: const Text('Hidden recommendations')),
                        if (service.error != null)
                          Text(service.error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        if (busy) const LinearProgressIndicator(),
                      ],
                    ))));
      });
}

class _HiddenRecommendationsDialog extends StatefulWidget {
  final DiscoveryService service;
  final Future<void> Function()? onChanged;
  const _HiddenRecommendationsDialog({required this.service, this.onChanged});
  @override
  State<_HiddenRecommendationsDialog> createState() =>
      _HiddenRecommendationsDialogState();
}

class _HiddenRecommendationsDialogState
    extends State<_HiddenRecommendationsDialog> {
  List<DiscoveryFeedback> _entries = [];
  bool _loading = true;
  String? _error;
  final Set<String> _saving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.service.getFeedback();
      if (mounted) setState(() => _entries = rows);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Could not load hidden recommendations. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restore(DiscoveryFeedback row) async {
    if (!_saving.add(row.id)) return;
    setState(() => _error = null);
    try {
      await widget.service.undoFeedback(row.id);
      if (!mounted) return;
      setState(() => _entries.removeWhere((entry) => entry.id == row.id));
      await widget.onChanged?.call();
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Could not restore this recommendation. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _saving.remove(row.id));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Hidden recommendations'),
        content: SizedBox(
            width: 480,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.6),
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    '“Less like this” keeps these songs out of your recommendations. Your saved music is unchanged.'),
                const SizedBox(height: 12),
                if (_loading) const LinearProgressIndicator(),
                if (!_loading && _entries.isEmpty && _error == null)
                  const Text('No hidden recommendations.'),
                if (_error != null) ...[
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('Retry'))
                ],
                for (final row in _entries)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(row.track.displayTitle),
                      subtitle: Text(row.track.artist ?? ''),
                      trailing: TextButton(
                          onPressed: _saving.contains(row.id)
                              ? null
                              : () => _restore(row),
                          child: const Text('Undo'))),
              ])),
            )),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'))
        ],
      );
}
