import 'package:flutter/material.dart';

/// Shared Spotify-style profile header: a subtle color-washed banner with a large
/// gradient "initial" avatar, the display name, a counts line (followers /
/// following / public playlists), and one primary action — Edit (self) or
/// Follow/Unfollow (friend). Used by both the own-profile and friend-profile views.
class ProfileHeader extends StatelessWidget {
  final String name;
  final String tagline;
  final int followerCount;
  final int followingCount;
  final int publicPlaylistCount;

  /// Self mode shows an Edit button; friend mode shows Follow/Unfollow.
  final bool isSelf;
  final bool isFollowing;
  final bool actionBusy;
  final VoidCallback? onEdit;
  final VoidCallback? onToggleFollow;
  final VoidCallback? onFollowingTap;

  const ProfileHeader({
    super.key,
    required this.name,
    required this.tagline,
    required this.followerCount,
    required this.followingCount,
    required this.publicPlaylistCount,
    required this.isSelf,
    this.isFollowing = false,
    this.actionBusy = false,
    this.onEdit,
    this.onToggleFollow,
    this.onFollowingTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letter = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.primary.withOpacity(0.35),
            scheme.secondary.withOpacity(0.12),
            Colors.transparent,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _avatar(context, letter),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PROFILE',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
                ),
                const SizedBox(height: 6),
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                      ),
                ),
                if (tagline.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    tagline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurface.withOpacity(0.7)),
                  ),
                ],
                const SizedBox(height: 12),
                _countsRow(context),
                const SizedBox(height: 16),
                _actionButton(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatar(BuildContext context, String letter) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size.width < 600 ? 96.0 : 132.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.secondary],
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 24, offset: const Offset(0, 8)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.44,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _countsRow(BuildContext context) {
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _stat(context, publicPlaylistCount, 'Public playlists'),
        _dot(context),
        _stat(context, followerCount, 'Followers'),
        _dot(context),
        _stat(context, followingCount, 'Following', onTap: onFollowingTap),
      ],
    );
  }

  Widget _dot(BuildContext context) => Text(
        '·',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
      );

  Widget _stat(BuildContext context, int value, String label, {VoidCallback? onTap}) {
    final scheme = Theme.of(context).colorScheme;
    final content = RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.bodyMedium,
        children: [
          TextSpan(
            text: '$value ',
            style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w700),
          ),
          TextSpan(
            text: label,
            style: TextStyle(color: scheme.onSurface.withOpacity(0.65)),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: content);
  }

  Widget _actionButton(BuildContext context) {
    if (isSelf) {
      return OutlinedButton.icon(
        onPressed: onEdit,
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Edit profile'),
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: actionBusy ? null : onToggleFollow,
      icon: Icon(isFollowing ? Icons.check : Icons.person_add_alt_1, size: 18),
      label: Text(isFollowing ? 'Following' : 'Follow'),
      style: FilledButton.styleFrom(
        backgroundColor: isFollowing
            ? Theme.of(context).colorScheme.surface
            : Theme.of(context).colorScheme.primary,
        foregroundColor: isFollowing
            ? Theme.of(context).colorScheme.onSurface
            : Colors.white,
        side: isFollowing ? BorderSide(color: Theme.of(context).dividerColor) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    );
  }
}
