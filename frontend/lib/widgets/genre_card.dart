import 'package:flutter/material.dart';

class GenreCard extends StatefulWidget {
  final String genre;
  final VoidCallback onTap;

  const GenreCard({
    super.key,
    required this.genre,
    required this.onTap,
  });

  @override
  State<GenreCard> createState() => _GenreCardState();
}

class _GenreCardState extends State<GenreCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    // Generate a consistent color based on genre name
    final color = Colors.primaries[widget.genre.hashCode % Colors.primaries.length];
    final darkerColor = Color.alphaBlend(
      Colors.black.withOpacity(0.2),
      color,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Card(
        elevation: _isHovered ? 8 : 4,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withOpacity(0.9),
                    darkerColor.withOpacity(0.7),
                    color.withOpacity(0.8),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
              child: Stack(
                children: [
                  // Decorative circles in background
                  Positioned(
                    top: -20,
                    right: -20,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.1),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: -30,
                    left: -30,
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.08),
                      ),
                    ),
                  ),
                  // Content
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.music_note,
                          color: Colors.white.withOpacity(0.9),
                          size: 32,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.genre,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            letterSpacing: 0.5,
                            shadows: [
                              Shadow(
                                offset: const Offset(0, 2),
                                blurRadius: 4.0,
                                color: Colors.black.withOpacity(0.3),
                              ),
                            ],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  // Hover overlay
                  if (_isHovered)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

