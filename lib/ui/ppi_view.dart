import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/radar_source.dart';
import '../core/scene.dart';
import '../ml/detector.dart';
import 'theme.dart';

/// Converts a [PolarFrame] to a Cartesian RGBA image through a precomputed
/// polar lookup table, applying per-beam phosphor decay and a colour table.
/// The GPU then scales and composites the image; everything else on the PPI
/// (sweep glow, rings, overlays) is vector drawing in [PpiPainter].
class PpiRenderer {
  PpiRenderer({this.size = 360})
      : _bytes = Uint8List(size * size * 4),
        _lutIdx = Int32List(size * size),
        _lutBeam = Uint16List(size * size);

  final int size;
  final Uint8List _bytes;
  final Int32List _lutIdx;
  final Uint16List _lutBeam;
  Float32List _fade = Float32List(0);
  int _lutBeams = 0, _lutBins = 0;
  bool busy = false;

  void _buildLut(int beams, int bins) {
    _lutBeams = beams;
    _lutBins = bins;
    _fade = Float32List(beams);
    final c = (size - 1) / 2.0;
    final rad = size / 2.0;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final dx = x - c, dy = y - c;
        final r = math.sqrt(dx * dx + dy * dy) / rad;
        final p = y * size + x;
        if (r >= 1) {
          _lutIdx[p] = -1;
          continue;
        }
        int beam = (math.atan2(dy, dx) / (2 * math.pi) * beams).round();
        beam = (beam % beams + beams) % beams;
        final bin = math.min(bins - 1, (r * bins).floor());
        _lutIdx[p] = beam * bins + bin;
        _lutBeam[p] = beam;
      }
    }
  }

  /// Returns null if a previous render is still being uploaded.
  Future<ui.Image?> render(PolarFrame f, Uint32List cmap, double persistence) {
    if (busy) return Future<ui.Image?>.value(null);
    if (_lutBeams != f.beams || _lutBins != f.bins) {
      _buildLut(f.beams, f.bins);
    }
    // Phosphor persistence: each beam fades from the moment it was painted,
    // down to a floor so the room outline stays readable between sweeps.
    final fade = _fade;
    for (int b = 0; b < f.beams; b++) {
      final age = f.time - f.beamTime[b];
      fade[b] = age > 1e8 ? 0.0 : 0.3 + 0.7 * math.exp(-age / persistence);
    }
    final px = _bytes.buffer.asUint32List();
    final vals = f.values;
    final lutIdx = _lutIdx, lutBeam = _lutBeam;
    final n = size * size;
    for (int p = 0; p < n; p++) {
      final idx = lutIdx[p];
      if (idx < 0) {
        px[p] = 0;
        continue;
      }
      int ci = (vals[idx] * fade[lutBeam[p]] * 255).toInt();
      if (ci > 255) ci = 255;
      px[p] = cmap[ci];
    }
    busy = true;
    final done = Completer<ui.Image?>();
    ui.decodeImageFromPixels(_bytes, size, size, ui.PixelFormat.rgba8888,
        (ui.Image img) {
      busy = false;
      done.complete(img);
    });
    return done.future;
  }
}

/// Mutable state shared between a screen and its [PpiPainter].
class PpiModel {
  PpiModel(this.repaint);
  final Listenable repaint;
  ui.Image? image;
  PolarFrame? frame;
  SceneController? scene;
  List<Detection> detections = const [];
  bool showAi = false;
  bool showGhost = true;
  String hud = '';
}

class PpiPainter extends CustomPainter {
  PpiPainter(this.model) : super(repaint: model.repaint);
  final PpiModel model;

  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);
    final rad = d / 2 - 6;
    final circle = Rect.fromCircle(center: c, radius: rad);
    final f = model.frame;

    canvas.drawCircle(c, rad, Paint()..color = const Color(0xFF010201));
    final img = model.image;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        circle,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    if (f == null) return;
    final scale = rad / f.maxRange;

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));

    // Ghosted floor plan at 20 % opacity, radar-centred.
    final scene = model.scene;
    if (scene != null && model.showGhost) {
      final ghost = Paint()
        ..color = const Color(0x33FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      Offset w2p(double x, double y) => Offset(
          c.dx + (x - scene.radarX) * scale, c.dy + (y - scene.radarY) * scale);
      for (final o in scene.objects) {
        switch (o.kind) {
          case ObjKind.wall:
            canvas.drawLine(w2p(o.x, o.y), w2p(o.x2, o.y2), ghost);
            break;
          case ObjKind.door:
            canvas.drawCircle(w2p(o.x, o.y), o.w / 2 * scale,
                Paint()..color = const Color(0x33000000));
            canvas.drawCircle(w2p(o.x, o.y), o.w / 2 * scale, ghost);
            break;
          case ObjKind.furniture:
            canvas.drawRect(
                Rect.fromCenter(
                    center: w2p(o.x, o.y),
                    width: o.w * scale,
                    height: o.h * scale),
                ghost);
            break;
          case ObjKind.person:
            canvas.drawCircle(w2p(o.x, o.y), 0.28 * scale, ghost);
            break;
        }
      }
    }

    // Sweep glow: a bright leading edge with a short trailing wedge.
    final sweep = Paint()
      ..shader = SweepGradient(
        colors: [
          kPhosphor.withOpacity(0),
          kPhosphor.withOpacity(0),
          kPhosphor.withOpacity(0.28),
        ],
        stops: const [0.0, 0.88, 1.0],
        transform: GradientRotation(f.sweepAngle),
      ).createShader(circle);
    canvas.drawCircle(c, rad, sweep);
    canvas.drawLine(
      c,
      c + Offset(math.cos(f.sweepAngle), math.sin(f.sweepAngle)) * rad,
      Paint()
        ..color = kPhosphor.withOpacity(0.8)
        ..strokeWidth = 1.2,
    );
    canvas.restore();

    // Range rings and bezel.
    final ring = Paint()
      ..color = kPhosphor.withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(c, rad * i / 4, ring);
      paintLabel(
          canvas,
          '${(f.maxRange * i / 4).toStringAsFixed(1)} m',
          c + Offset(4, -rad * i / 4 + 2),
          kPhosphor.withOpacity(0.55),
          size: 9);
    }
    canvas.drawLine(c - Offset(rad, 0), c + Offset(rad, 0), ring);
    canvas.drawLine(c - Offset(0, rad), c + Offset(0, rad), ring);
    canvas.drawCircle(
        c,
        rad,
        Paint()
          ..color = kPhosphor.withOpacity(0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    // Detector overlay.
    if (model.showAi) {
      for (final det in model.detections) {
        final color = det.label == 'person'
            ? kAlert
            : det.label == 'wall'
                ? const Color(0xFF4FC3F7)
                : kAmber;
        final r = Rect.fromLTRB(
          c.dx + det.minX * scale - 2,
          c.dy + det.minY * scale - 2,
          c.dx + det.maxX * scale + 2,
          c.dy + det.maxY * scale + 2,
        );
        canvas.drawRect(
            r,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = det.label == 'wall' ? 1.0 : 1.8);
        if (det.label != 'wall' || r.longestSide > 60) {
          paintLabel(
              canvas,
              '${det.label} ${(det.score * 100).round()}%',
              Offset(r.left, r.top - 13),
              color,
              size: 9,
              background: true);
        }
      }
    }

    if (model.hud.isNotEmpty) {
      paintLabel(canvas, model.hud, Offset(c.dx - rad, c.dy - rad - 2), kDim,
          size: 10);
    }
  }

  @override
  bool shouldRepaint(covariant PpiPainter oldDelegate) => false;
}
