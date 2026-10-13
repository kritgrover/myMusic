import 'dart:io';
import 'package:flutter/material.dart';

Widget buildArtwork(String? url, double size, Widget placeholder) {
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null || uri.scheme != 'file') return placeholder;
  return Image.file(
    File.fromUri(uri),
    width: size,
    height: size,
    fit: BoxFit.cover,
    errorBuilder: (_, __, ___) => placeholder,
  );
}
