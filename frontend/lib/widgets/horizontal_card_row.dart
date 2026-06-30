import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';

/// A reusable horizontal shelf (section title + optional "Show All" + horizontally
/// scrolling cards). Parallels HorizontalSongList but renders arbitrary cards
/// (playlist tiles, artist tiles), so curated/mood/artist rows share one layout.
class HorizontalCardRow extends StatelessWidget {
  final String title;
  final int itemCount;
  final double itemWidth;

  /// Extra vertical space below each square cover for label text.
  final double labelHeight;
  final IndexedWidgetBuilder itemBuilder;
  final VoidCallback? onShowAll;

  const HorizontalCardRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemWidth,
    required this.itemBuilder,
    this.labelHeight = 52,
    this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            right: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            top: 8,
            bottom: 8,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (onShowAll != null)
                TextButton(
                  onPressed: onShowAll,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Show All',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_forward, size: 16, color: Theme.of(context).colorScheme.primary),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: itemWidth + labelHeight,
          child: ListView.separated(
            padding: ResponsiveUtils.responsiveHorizontalPadding(context),
            scrollDirection: Axis.horizontal,
            itemCount: itemCount,
            separatorBuilder: (context, index) => SizedBox(
              width: ResponsiveUtils.responsiveValue<double>(context, compact: 16, medium: 20, expanded: 24),
            ),
            itemBuilder: (context, index) {
              return SizedBox(
                width: itemWidth,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: itemBuilder(context, index),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
