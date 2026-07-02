import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import 'section_header.dart';

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
        SectionHeader(title: title, onShowAll: onShowAll),
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
