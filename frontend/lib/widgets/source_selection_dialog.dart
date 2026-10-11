import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/api_service.dart';

/// Compare the actual recordings behind a catalog track and save a choice for
/// this account. The dialog does not interrupt a track that is already playing.
class SourceSelectionDialog extends StatefulWidget {
  final PlaylistTrack track;
  final ApiService apiService;

  const SourceSelectionDialog({
    super.key,
    required this.track,
    required this.apiService,
  });

  @override
  State<SourceSelectionDialog> createState() => _SourceSelectionDialogState();
}

class _SourceSelectionDialogState extends State<SourceSelectionDialog> {
  final TextEditingController _urlController = TextEditingController();
  late final String _session;
  SourceCandidates? _result;
  String? _selectedUrl;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _invalidUrl = false;
  int _request = 0;

  String? get _spotifyId => ApiService.spotifyTrackId(
        widget.track.url,
        id: widget.track.id,
      );

  bool get _sameAccount => widget.apiService.sessionScope == _session;

  @override
  void initState() {
    super.initState();
    _session = widget.apiService.sessionScope;
    _load();
  }

  @override
  void dispose() {
    _request++;
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_checkAccount()) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.apiService.sourceCandidates(
        title: widget.track.title,
        artist: widget.track.artist,
        album: widget.track.album,
        duration: widget.track.duration,
        spotifyId: _spotifyId,
        url: widget.track.url,
      );
      if (!mounted || request != _request || !_checkAccount()) return;
      setState(() {
        _result = result;
        _selectedUrl = result.selectedUrl;
        _urlController.clear();
        _invalidUrl = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request || !_checkAccount()) return;
      setState(() {
        _error = error is SourceMatchException
            ? error.message
            : 'Could not load recording choices. Please try again.';
        _loading = false;
      });
    }
  }

  bool _checkAccount() {
    if (_sameAccount) return true;
    if (mounted) {
      setState(() {
        _result = null;
        _selectedUrl = null;
        _loading = false;
        _saving = false;
        _error = 'Your account changed. Close and reopen the recording picker.';
      });
    }
    return false;
  }

  Future<void> _save({bool reset = false}) async {
    if (_saving || !_checkAccount()) return;
    if (!reset && _selectedUrl == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (reset) {
        await widget.apiService.resetSource(
          title: widget.track.title,
          artist: widget.track.artist,
          album: widget.track.album,
          duration: widget.track.duration,
          spotifyId: _spotifyId,
        );
      } else {
        await widget.apiService.rememberSource(
          title: widget.track.title,
          artist: widget.track.artist,
          album: widget.track.album,
          duration: widget.track.duration,
          spotifyId: _spotifyId,
          url: _selectedUrl!,
        );
      }
      if (!mounted || !_checkAccount()) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reset
            ? 'Automatic recording selection restored'
            : 'Recording choice remembered for future playback'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (error) {
      if (!mounted || !_checkAccount()) return;
      setState(() {
        _saving = false;
        _error = error is SourceMatchException
            ? error.message
            : 'Could not save your recording choice. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final candidates = _result?.candidates ?? const <VideoInfo>[];
    return AlertDialog(
      title: const Text('Change recording'),
      content: SizedBox(
        width: 600,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.62,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title,
                    style: Theme.of(context).textTheme.titleMedium),
                if (track.artist?.isNotEmpty == true) Text(track.artist!),
                if (track.album?.isNotEmpty == true)
                  Text(track.album!,
                      style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                const Text(
                  'Compare the version, uploader and length. Your choice is saved '
                  'to your account for future plays, queue additions and downloads.',
                ),
                if (_result?.remembered == true) ...[
                  const SizedBox(height: 8),
                  const Text('You have a remembered recording for this song.'),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  if (_sameAccount && !_saving)
                    TextButton(
                        onPressed: _load, child: const Text('Try again')),
                ],
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (candidates.isEmpty && _error == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No recordings found. Try again in a moment.'),
                  )
                else
                  Column(
                    children: [
                      for (final warning
                          in _result?.warnings ?? const <String>[])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(warning,
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      for (final candidate in candidates)
                        RadioListTile<String>(
                          value: candidate.url,
                          groupValue: _selectedUrl,
                          onChanged: _saving
                              ? null
                              : (value) {
                                  if (_checkAccount()) {
                                    setState(() {
                                      _selectedUrl = value;
                                      _urlController.clear();
                                      _invalidUrl = false;
                                    });
                                  }
                                },
                          contentPadding: EdgeInsets.zero,
                          title: Text(candidate.title),
                          subtitle: Text([
                            candidate.uploader,
                            candidate.recordingDescription,
                            if (candidate.duration > 0)
                              candidate.formattedDuration,
                            if (candidate.url == _result?.selectedUrl)
                              _result!.remembered
                                  ? 'Remembered'
                                  : 'Current source',
                          ].where((part) => part.isNotEmpty).join(' · ')),
                          isThreeLine: true,
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _urlController,
                  enabled: !_saving && !_loading && _sameAccount,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Or paste a YouTube link',
                    hintText: 'Have the exact recording? Paste its link here.',
                    border: const OutlineInputBorder(),
                    errorText: _invalidUrl
                        ? 'Enter a valid YouTube video link.'
                        : null,
                  ),
                  onChanged: (value) {
                    if (!_checkAccount()) return;
                    final canonical =
                        ApiService.canonicalYouTubeSource(value.trim());
                    setState(() {
                      _invalidUrl =
                          value.trim().isNotEmpty && canonical == null;
                      _selectedUrl = canonical;
                    });
                  },
                ),
                if (_urlController.text.isNotEmpty && !_invalidUrl) ...[
                  const SizedBox(height: 8),
                  Text('Selected link: $_selectedUrl',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (_result?.remembered == true)
          TextButton(
            onPressed: _saving ? null : () => _save(reset: true),
            child: const Text('Use automatic match'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _loading || _saving || _selectedUrl == null || !_sameAccount
                  ? null
                  : _save,
          child: Text(_saving ? 'Saving…' : 'Use and remember'),
        ),
      ],
    );
  }
}
