import 'package:flutter/material.dart';
import '../models/playlist.dart';

/// The persistent left sidebar (medium/expanded widths). Holds the three primary
/// destinations — Home, Search, Your Library — and, when expanded, a shortcut list
/// of the user's playlists. Replaces the old 5-item NavigationRail.
class AppSidebar extends StatelessWidget {
  final int selectedIndex; // 0 Home · 1 Search · 2 Library
  final ValueChanged<int> onSelect;
  final bool expanded;
  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpenPlaylist;
  final VoidCallback onCreate;

  const AppSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.expanded,
    required this.playlists,
    required this.onOpenPlaylist,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 8, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _brand(context),
          const SizedBox(height: 14),
          _navItem(context, index: 0, icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Home'),
          _navItem(context, index: 1, icon: Icons.search, selectedIcon: Icons.search, label: 'Search'),
          _navItem(context, index: 2, icon: Icons.library_music_outlined, selectedIcon: Icons.library_music, label: 'Your Library'),
          if (expanded) ...[
            const SizedBox(height: 10),
            Divider(color: Theme.of(context).dividerColor, height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'PLAYLISTS',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 0.6),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: 'Create playlist or import',
                  onPressed: onCreate,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            Expanded(
              child: playlists.isEmpty
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8, top: 6),
                        child: Text(
                          'No playlists yet',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: playlists.length,
                      itemBuilder: (context, index) => _playlistRow(context, playlists[index]),
                    ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }

  Widget _brand(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!expanded) {
      return Center(child: Icon(Icons.album, color: scheme.primary, size: 26));
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        children: [
          Icon(Icons.album, color: scheme.primary, size: 22),
          const SizedBox(width: 8),
          Text(
            'myMusic',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(
    BuildContext context, {
    required int index,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final selected = selectedIndex == index;
    final color = selected ? scheme.onSurface : Theme.of(context).textTheme.labelMedium?.color;
    final content = expanded
        ? Row(
            children: [
              Icon(selected ? selectedIcon : icon, size: 22, color: selected ? scheme.primary : color),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          )
        : Center(child: Icon(selected ? selectedIcon : icon, size: 24, color: selected ? scheme.primary : color));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => onSelect(index),
          borderRadius: BorderRadius.circular(8),
          child: Tooltip(
            message: expanded ? '' : label,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: expanded ? 10 : 4, vertical: 10),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  Widget _playlistRow(BuildContext context, Playlist playlist) {
    final cover = playlist.coverImage;
    final hasHttp = cover != null && (cover.startsWith('http://') || cover.startsWith('https://'));
    return InkWell(
      onTap: () => onOpenPlaylist(playlist),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: hasHttp
                  ? Image.network(
                      cover,
                      width: 38,
                      height: 38,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _cover(context),
                    )
                  : _cover(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: const Icon(Icons.queue_music, size: 18),
    );
  }
}
