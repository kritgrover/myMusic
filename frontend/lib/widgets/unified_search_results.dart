import 'package:flutter/material.dart';

import '../models/search_results.dart';
import '../services/auth_http_client.dart';
import '../services/unified_search_controller.dart';

/// Shared grouped search surface; navigation and playback belong to the host.
class UnifiedSearchResults extends StatefulWidget {
  final UnifiedSearchController controller;
  final ValueChanged<String> onSearch;
  final ValueChanged<SearchEntry> onOpen;
  final Widget Function(SearchEntry) trackBuilder;
  final Widget browse;

  const UnifiedSearchResults(
      {super.key,
      required this.controller,
      required this.onSearch,
      required this.onOpen,
      required this.trackBuilder,
      required this.browse});

  @override
  State<UnifiedSearchResults> createState() => _UnifiedSearchResultsState();
}

class _UnifiedSearchResultsState extends State<UnifiedSearchResults> {
  String _filter = 'All';
  static const _categories = [
    'Songs',
    'Artists',
    'Albums',
    'Playlists',
    'Your Library'
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final state = widget.controller;
          if (state.query.isEmpty) {
            return Column(children: [
              if (state.recent.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                              child: Text('Recent searches',
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                          TextButton(
                              onPressed: state.clearHistory,
                              child: const Text('Clear all')),
                        ]),
                        SizedBox(
                            height: 40,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: state.recent.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, index) {
                                final query = state.recent[index];
                                return InputChip(
                                    avatar: const Icon(Icons.history, size: 17),
                                    label: Text(query),
                                    onPressed: () => widget.onSearch(query),
                                    deleteButtonTooltipMessage:
                                        'Remove $query from recent searches',
                                    onDeleted: () => state.removeRecent(query));
                              },
                            )),
                      ]),
                ),
              Expanded(child: widget.browse),
            ]);
          }
          final groups = <String, List<SearchEntry>>{
            'Songs': state.results.songs,
            'Artists': state.results.artists,
            'Albums': state.results.albums,
            'Playlists': state.results.playlists,
            'Your Library': state.results.library,
          };
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(
                      children: ['All', ..._categories]
                          .map((category) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                    label: Text(category),
                                    selected: _filter == category,
                                    onSelected: (_) =>
                                        setState(() => _filter = category)),
                              ))
                          .toList()),
                ),
                if (state.suggestions.isNotEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    child: Wrap(spacing: 8, runSpacing: 4, children: [
                      ...state.suggestions.map((suggestion) => ActionChip(
                            avatar: const Icon(Icons.north_west, size: 15),
                            label: Text(suggestion,
                                overflow: TextOverflow.ellipsis),
                            tooltip: 'Search $suggestion',
                            onPressed: () => widget.onSearch(suggestion),
                          )),
                    ]),
                  ),
                if (state.isSearching)
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                    child: state.error != null
                        ? _message(Icons.wifi_off, 'Search is unavailable',
                            state.error!, retry: true)
                        : state.isSearching &&
                                (state.results.isEmpty ||
                                    (_filter != 'All' &&
                                        groups[_filter]!.isEmpty))
                            ? _message(Icons.search, 'Searching music…',
                                'Songs, artists, albums, playlists and your library')
                            : ListView(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 12, 20, 100),
                                children: [
                                    if (state.results.warnings.isNotEmpty)
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        margin:
                                            const EdgeInsets.only(bottom: 16),
                                        decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                        child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Icon(Icons.info_outline,
                                                  size: 20),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                  child: Text(state
                                                      .results.warnings
                                                      .join(' '))),
                                              TextButton(
                                                  onPressed: state.retry,
                                                  child: const Text('Retry')),
                                            ]),
                                      ),
                                    if (state.results.isEmpty ||
                                        (_filter != 'All' &&
                                            groups[_filter]!.isEmpty))
                                      Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 48),
                                          child: _message(
                                              Icons.search_off,
                                              _filter == 'All'
                                                  ? 'No results for “${state.query}”'
                                                  : 'No ${_filter.toLowerCase()} found',
                                              'Try another spelling, an artist name, or a shorter search.')),
                                    for (final category in _categories)
                                      if ((_filter == 'All' ||
                                              _filter == category) &&
                                          groups[category]!.isNotEmpty) ...[
                                        Padding(
                                            padding: const EdgeInsets.only(
                                                top: 8, bottom: 8),
                                            child: Row(children: [
                                              Expanded(
                                                  child: Text(category,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleLarge
                                                          ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700))),
                                              if (_filter == 'All' &&
                                                  groups[category]!.length > 5)
                                                TextButton(
                                                    onPressed: () => setState(
                                                        () =>
                                                            _filter = category),
                                                    child:
                                                        const Text('Show all')),
                                            ])),
                                        ...(_filter == 'All'
                                                ? groups[category]!.take(5)
                                                : groups[category]!)
                                            .map((entry) {
                                          final isTrack = category == 'Songs' ||
                                              (category == 'Your Library' &&
                                                  entry.kind == 'track');
                                          if (isTrack) {
                                            return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  if (entry.origin.isNotEmpty)
                                                    Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .only(
                                                                left: 12,
                                                                top: 6),
                                                        child: Text(
                                                            _origin(
                                                                entry.origin),
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .labelSmall)),
                                                  widget.trackBuilder(entry),
                                                ]);
                                          }
                                          return _entity(entry, category);
                                        }),
                                        const SizedBox(height: 20),
                                      ],
                                  ])),
              ]);
        });
  }

  String _origin(String origin) => switch (origin) {
        'device' => 'On this device',
        'saved' => 'Saved in your library',
        'download' => 'Downloaded',
        'playlist' => 'In your playlists',
        _ => 'Your library',
      };

  Widget _entity(SearchEntry entry, String category) {
    final kind =
        category == 'Your Library' ? entry.kind : category.toLowerCase();
    final icon = switch (kind) {
      'artist' || 'artists' => Icons.person,
      'album' || 'albums' => Icons.album,
      _ => Icons.queue_music,
    };
    final date = (entry.data['release_date'] ?? '').toString();
    final details = [
      if (entry.artist.isNotEmpty) entry.artist,
      if (date.isNotEmpty) date.split('-').first,
      if (entry.origin.isNotEmpty)
        _origin(entry.origin)
      else if (entry.provider == 'local')
        'Your playlist'
      else if (kind == 'artists')
        'Artist'
      else if (kind == 'albums')
        (entry.data['type'] ?? 'Album').toString(),
    ].where((text) => text.isNotEmpty).join(' · ');
    final image = entry.thumbnail;
    return Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          leading: ClipRRect(
              borderRadius:
                  BorderRadius.circular(icon == Icons.person ? 28 : 6),
              child: image != null && image.isNotEmpty
                  ? Image.network(AuthHttpClient.shared.cacheScopedUrl(image),
                      headers: AuthHttpClient.shared.authHeadersForUrl(image),
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder(icon))
                  : _placeholder(icon)),
          title:
              Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: details.isEmpty
              ? null
              : Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => widget.onOpen(entry),
        ));
  }

  Widget _placeholder(IconData icon) => Container(
      width: 52,
      height: 52,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(icon));

  Widget _message(IconData icon, String title, String text,
          {bool retry = false}) =>
      Center(
        child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon,
                  size: 44, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(text, textAlign: TextAlign.center),
              if (retry)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: FilledButton.icon(
                        onPressed: widget.controller.retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'))),
            ])),
      );
}
