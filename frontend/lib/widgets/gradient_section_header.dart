import 'package:flutter/material.dart';

/// Section header with optional subtle gradient bar.
/// Used in Profile, Downloads, Playlists for consistent hierarchy.
class GradientSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final bool showGradientBar;

  const GradientSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.showGradientBar = true,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        if (showGradientBar) ...[
          const SizedBox(height: 8),
          Container(
            height: 2,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(1),
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  primaryColor.withOpacity(0.4),
                  primaryColor.withOpacity(0.1),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
