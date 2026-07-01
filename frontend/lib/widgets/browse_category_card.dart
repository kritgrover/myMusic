import 'package:flutter/material.dart';

/// A vibrant Spotify-style "Browse all" category tile: a rich colored card with
/// the category name in bold and an album cover tilted out of the bottom-right
/// corner. Lifts slightly on hover. Replaces the old flat gradient banners.
class BrowseCategoryCard extends StatefulWidget {
  final String label;
  final String? imageUrl;
  final VoidCallback onTap;

  const BrowseCategoryCard({
    super.key,
    required this.label,
    required this.onTap,
    this.imageUrl,
  });

  /// A curated palette (harmonizes with the app's indigo/purple accent), picked
  /// deterministically per label so a category always keeps its color.
  static const List<Color> _palette = [
    Color(0xFF6366F1), // indigo (primary)
    Color(0xFF8B5CF6), // purple (secondary)
    Color(0xFF1D9E75), // teal
    Color(0xFFD4537E), // pink
    Color(0xFF378ADD), // blue
    Color(0xFFBA7517), // amber
    Color(0xFFD85A30), // coral
    Color(0xFF534AB7), // deep indigo
    Color(0xFF0F6E56), // deep teal
    Color(0xFF993556), // wine
  ];

  Color get _color => _palette[_stableHash(label) % _palette.length];

  static int _stableHash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  @override
  State<BrowseCategoryCard> createState() => _BrowseCategoryCardState();
}

class _BrowseCategoryCardState extends State<BrowseCategoryCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget._color;
    final darker = Color.alphaBlend(Colors.black.withOpacity(0.28), color);
    final hasImage = widget.imageUrl != null && widget.imageUrl!.isNotEmpty;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.03 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color, darker],
              ),
              boxShadow: _hover
                  ? [BoxShadow(color: color.withOpacity(0.45), blurRadius: 18, offset: const Offset(0, 8))]
                  : const [],
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    widget.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      height: 1.15,
                    ),
                  ),
                ),
                Positioned(
                  right: -14,
                  bottom: -8,
                  child: Transform.rotate(
                    angle: 0.42,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 10, offset: const Offset(-2, 4)),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: hasImage
                            ? Image.network(
                                widget.imageUrl!,
                                width: 78,
                                height: 78,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _artFallback(darker),
                              )
                            : _artFallback(darker),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _artFallback(Color base) {
    return Container(
      width: 78,
      height: 78,
      color: Color.alphaBlend(Colors.black.withOpacity(0.25), base),
      child: Icon(Icons.music_note, color: Colors.white.withOpacity(0.85), size: 30),
    );
  }
}
