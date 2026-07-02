import 'package:flutter/material.dart';

/// The shared top bar shown above the content on every destination: a pill search
/// field on the left and an account avatar menu (Profile / Friends / Log out) on
/// the right. The search field is the single search entry point for both Home and
/// Search — focusing it routes to the Search destination.
class AppTopBar extends StatelessWidget {
  final TextEditingController searchController;
  final VoidCallback onSearchTap;
  final ValueChanged<String> onSearchSubmitted;
  final ValueChanged<String> onSearchChanged;
  final String? username;
  final VoidCallback onProfile;
  final VoidCallback onFriends;
  final VoidCallback onLogout;

  const AppTopBar({
    super.key,
    required this.searchController,
    required this.onSearchTap,
    required this.onSearchSubmitted,
    required this.onSearchChanged,
    required this.username,
    required this.onProfile,
    required this.onFriends,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: searchController,
              onTap: onSearchTap,
              onSubmitted: onSearchSubmitted,
              onChanged: onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search for a song, artist or album',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: 'Clear',
                        onPressed: () {
                          searchController.clear();
                          onSearchChanged('');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: scheme.primary, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _AccountMenu(
            username: username,
            onProfile: onProfile,
            onFriends: onFriends,
            onLogout: onLogout,
          ),
        ],
      ),
    );
  }
}

class _AccountMenu extends StatelessWidget {
  final String? username;
  final VoidCallback onProfile;
  final VoidCallback onFriends;
  final VoidCallback onLogout;

  const _AccountMenu({
    required this.username,
    required this.onProfile,
    required this.onFriends,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = (username ?? '').trim();
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return PopupMenuButton<String>(
      tooltip: 'Account',
      offset: const Offset(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onSelected: (value) {
        switch (value) {
          case 'profile':
            onProfile();
            break;
          case 'friends':
            onFriends();
            break;
          case 'logout':
            onLogout();
            break;
        }
      },
      itemBuilder: (context) => [
        if (name.isNotEmpty)
          PopupMenuItem<String>(
            enabled: false,
            child: Text(
              name,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        if (name.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'profile',
          child: Row(children: [Icon(Icons.person_outline, size: 20), SizedBox(width: 12), Text('Profile')]),
        ),
        const PopupMenuItem(
          value: 'friends',
          child: Row(children: [Icon(Icons.people_outline, size: 20), SizedBox(width: 12), Text('Friends')]),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'logout',
          child: Row(children: [Icon(Icons.logout, size: 20), SizedBox(width: 12), Text('Log out')]),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (name.isNotEmpty) ...[
              Text(name, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(width: 6),
            ],
            CircleAvatar(
              radius: 13,
              backgroundColor: scheme.primary,
              child: Text(
                letter,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
