import 'dart:async';
import 'package:flutter/material.dart';
import '../services/discovery_service.dart';
import '../services/auth_http_client.dart';

Future<void> showArtistPicker(BuildContext context,
        {required DiscoveryService service,
        Future<void> Function()? onSaved}) =>
    showDialog<void>(
        context: context,
        builder: (_) => ArtistPickerDialog(service: service, onSaved: onSaved));

class ArtistPickerDialog extends StatefulWidget {
  final DiscoveryService service;
  final Future<void> Function()? onSaved;
  const ArtistPickerDialog({super.key, required this.service, this.onSaved});

  @override
  State<ArtistPickerDialog> createState() => _ArtistPickerDialogState();
}

class _ArtistPickerDialogState extends State<ArtistPickerDialog> {
  final _query = TextEditingController();
  late final Map<String, DiscoveryArtist> _selected;
  List<DiscoveryArtist> _results = [];
  Timer? _debounce;
  int _request = 0;
  bool _loading = false;
  bool _saving = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = {
      for (final artist in widget.service.preferences.seedArtists)
        artist.id: artist
    };
  }

  void _changed(String query) {
    _debounce?.cancel();
    _request++;
    setState(() {
      _results = [];
      _error = null;
      _searched = false;
      _loading = query.trim().isNotEmpty;
    });
    if (query.trim().isNotEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), _search);
    }
  }

  Future<void> _search() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.service.searchArtists(_query.text);
      if (!mounted || request != _request) return;
      setState(() {
        _results = results;
        _searched = true;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() => _error = 'Artist search is unavailable. Please retry.');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _toggle(DiscoveryArtist artist) {
    if (_saving) return;
    setState(() {
      if (_selected.containsKey(artist.id)) {
        _selected.remove(artist.id);
      } else if (_selected.length < 5) {
        _selected[artist.id] = artist;
      }
    });
  }

  Future<void> _save({bool skip = false}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.save(
          onboardingCompleted: true,
          seedArtists: skip ? null : _selected.values.toList());
      if (!mounted) return;
      final callback = widget.onSaved;
      Navigator.of(context).pop();
      if (callback != null) await callback();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save your artists. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _request++;
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Choose artists you love'),
        content: SizedBox(
            width: 480,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.55),
              child: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Pick up to 5 artists to shape your recommendations. You can change them anytime.'),
                  const SizedBox(height: 12),
                  if (_selected.isNotEmpty) ...[
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      for (final artist in _selected.values)
                        InputChip(
                            label: Text(artist.name),
                            onDeleted: _saving ? null : () => _toggle(artist)),
                    ]),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                      controller: _query,
                      onChanged: _changed,
                      enabled: !_saving,
                      maxLength: 100,
                      decoration: const InputDecoration(
                          labelText: 'Search artists',
                          prefixIcon: Icon(Icons.search))),
                  Text('${_selected.length} of 5 selected'),
                  if (_loading)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: LinearProgressIndicator()),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!),
                    if (!_saving && _query.text.trim().isNotEmpty)
                      TextButton.icon(
                          onPressed: _search,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry search')),
                  ],
                  if (!_loading && _searched && _results.isEmpty)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('No artists found. Try another name.')),
                  for (final artist in _results)
                    CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.trailing,
                        value: _selected.containsKey(artist.id),
                        onChanged: _saving ||
                                (!_selected.containsKey(artist.id) &&
                                    _selected.length >= 5)
                            ? null
                            : (_) => _toggle(artist),
                        secondary: artist.thumbnail?.isNotEmpty == true
                            ? ClipOval(
                                child: Image.network(artist.thumbnail!,
                                    width: 36,
                                    height: 36,
                                    fit: BoxFit.cover,
                                    headers: AuthHttpClient.shared
                                        .authHeadersForUrl(artist.thumbnail!),
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.person_outline)))
                            : const Icon(Icons.person_outline),
                        title: Text(artist.name)),
                ],
              )),
            )),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          if (!widget.service.preferences.onboardingCompleted)
            TextButton(
                onPressed: _saving ? null : () => _save(skip: true),
                child: const Text('Skip for now')),
          FilledButton(
              onPressed: _saving ||
                      (_selected.isEmpty &&
                          !widget.service.preferences.onboardingCompleted)
                  ? null
                  : _save,
              child: Text(_saving ? 'Saving…' : 'Save artists')),
        ],
      );
}
