import 'dart:typed_data';

import 'package:flutter/material.dart';

const Color kBg = Color(0xFF040704);
const Color kSurface = Color(0xFF0A120A);
const Color kPanel = Color(0xFF101A10);
const Color kPhosphor = Color(0xFF39FF14);
const Color kAmber = Color(0xFFFFB000);
const Color kDim = Color(0xFF5C7A5C);
const Color kAlert = Color(0xFFFF5A36);

ThemeData darkSightTheme() {
  const scheme = ColorScheme.dark(
    primary: kPhosphor,
    onPrimary: Colors.black,
    secondary: kAmber,
    onSecondary: Colors.black,
    surface: kSurface,
    onSurface: Color(0xFFB8F5B0),
    error: kAlert,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    canvasColor: kBg,
    fontFamily: 'monospace',
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      foregroundColor: kPhosphor,
      elevation: 0,
      centerTitle: false,
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: kSurface),
    sliderTheme: const SliderThemeData(
      activeTrackColor: kPhosphor,
      thumbColor: kPhosphor,
      inactiveTrackColor: Color(0xFF1E3A1E),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kPanel,
      contentTextStyle: TextStyle(color: kPhosphor, fontFamily: 'monospace'),
    ),
  );
}

const List<String> kColormapNames = ['Inferno', 'Phosphor', 'Amber', 'Grey'];

/// 256-entry colour table packed for a little-endian RGBA8888 pixel buffer
/// (0xAABBGGRR).
Uint32List buildColormap(int id) {
  late final List<List<double>> stops; // [pos, r, g, b]
  switch (id) {
    case 1:
      stops = [
        [0, 0, 4, 0],
        [0.35, 0, 70, 12],
        [0.8, 57, 255, 20],
        [1, 225, 255, 215],
      ];
      break;
    case 2:
      stops = [
        [0, 5, 2, 0],
        [0.4, 110, 55, 0],
        [0.8, 255, 176, 0],
        [1, 255, 240, 200],
      ];
      break;
    case 3:
      stops = [
        [0, 4, 6, 4],
        [1, 235, 245, 235],
      ];
      break;
    default:
      stops = [
        [0.00, 0, 0, 4],
        [0.13, 31, 12, 72],
        [0.25, 85, 15, 109],
        [0.38, 136, 34, 106],
        [0.50, 186, 54, 85],
        [0.63, 227, 89, 51],
        [0.75, 249, 140, 10],
        [0.88, 249, 201, 50],
        [1.00, 252, 255, 164],
      ];
  }
  final out = Uint32List(256);
  int s = 0;
  for (int i = 0; i < 256; i++) {
    final x = i / 255.0;
    while (s < stops.length - 2 && x > stops[s + 1][0]) {
      s++;
    }
    final a = stops[s], b = stops[s + 1];
    final span = b[0] - a[0];
    final t = span <= 0 ? 0.0 : ((x - a[0]) / span).clamp(0.0, 1.0);
    final r = (a[1] + (b[1] - a[1]) * t).round();
    final g = (a[2] + (b[2] - a[2]) * t).round();
    final bl = (a[3] + (b[3] - a[3]) * t).round();
    out[i] = 0xFF000000 | (bl << 16) | (g << 8) | r;
  }
  return out;
}

/// Small monospace label helper for painters.
void paintLabel(Canvas canvas, String text, Offset at, Color color,
    {double size = 10, bool background = false}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontFamily: 'monospace',
        fontWeight: FontWeight.w600,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  if (background) {
    canvas.drawRect(
      Rect.fromLTWH(at.dx - 2, at.dy - 1, tp.width + 4, tp.height + 2),
      Paint()..color = const Color(0xCC000000),
    );
  }
  tp.paint(canvas, at);
}
