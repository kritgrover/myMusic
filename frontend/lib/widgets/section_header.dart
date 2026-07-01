import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';

/// A clean, Spotify-style shelf header: a bold title on the left and an optional
/// muted "Show all" affordance on the right. Replaces the old gradient-bar header.
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onShowAll;
  final EdgeInsetsGeometry? padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.onShowAll,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final horizontal = ResponsiveUtils.responsiveValue<double>(
      context,
      compact: 12,
      medium: 20,
      expanded: 24,
    );
    return Padding(
      padding: padding ??
          EdgeInsets.only(left: horizontal, right: horizontal, top: 20, bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
            ),
          ),
          if (onShowAll != null)
            TextButton(
              onPressed: onShowAll,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              child: Text(
                'Show all',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
              ),
            ),
        ],
      ),
    );
  }
}
