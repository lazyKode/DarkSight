import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/radar_source.dart';
import '../core/scene.dart';
import '../core/tracker.dart';
import '../ml/detector.dart';
import '../ml/target_classifier.dart';
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
  List<Detection> structure = const [];
  List<Track> tracks = const [];
  int? selectedTrack;
  bool showAi = false;
  bool showGhost = true;
  double clock = 0;
  String hud = '';

  /// Geometry of the last paint, for hit-testing taps.
  Offset centre = Offset.zero;
  double scale = 1;
}

Color classColor(TargetClass? c) => switch (c) {
      TargetClass.human => kAlert,
      TargetClass.dog => kAmber,
      TargetClass.cat => const Color(0xFFE6A8FF),
      TargetClass.machine => const Color(0xFF4FC3F7),
      null => kPhosphor,
    };

class PpiPainter extends CustomPainter {
  PpiPainter(this.model) : super(repaint: model.repaint);
  final PpiModel model;

  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);
    final rad = d / 2 - 8;
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
    model.centre = c;
    model.scale = scale;
    Offset r2p(double x, double y) => Offset(c.dx + x * scale, c.dy + y * scale);

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));

    // Ghosted floor plan at 20 % opacity: the static plan only. Bodies are
    // never drawn from the scene: anything shown moving comes from tracks.
    final scene = model.scene;
    if (scene != null && model.showGhost) {
      final ghost = Paint()
        ..color = const Color(0x33FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      Offset w2p(double x, double y) =>
          r2p(x - scene.radarX, y - scene.radarY);
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
          default:
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

    if (model.showAi) {
      for (final det in model.structure) {
        final wall = det.label == 'wall';
        final color = wall ? const Color(0xFF4FC3F7) : kAmber;
        final r = Rect.fromPoints(r2p(det.minX, det.minY), r2p(det.maxX, det.maxY))
            .inflate(2);
        canvas.drawRect(
            r,
            Paint()
              ..color = color.withOpacity(wall ? 0.45 : 0.8)
              ..style = PaintingStyle.stroke
              ..strokeWidth = wall ? 0.8 : 1.2);
        if (!wall) {
          paintLabel(canvas, 'STATIC OBJECT', Offset(r.left, r.top - 12),
              color, size: 8, background: true);
        }
      }
      for (final t in model.tracks) {
        _paintTrack(canvas, t, r2p, scale);
      }
    }
    canvas.restore();

    // Range rings, bearing ticks and bezel.
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
    final tick = Paint()
      ..color = kPhosphor.withOpacity(0.5)
      ..strokeWidth = 1;
    for (int deg = 0; deg < 360; deg += 10) {
      final a = (deg - 90) * math.pi / 180; // 000 at the top
      final len = deg % 30 == 0 ? 8.0 : 4.0;
      final u = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + u * rad, c + u * (rad - len), tick);
      if (deg % 30 == 0) {
        paintLabel(canvas, deg.toString().padLeft(3, '0'),
            c + u * (rad - 20) - const Offset(9, 5), kPhosphor.withOpacity(0.45),
            size: 8);
      }
    }
    canvas.drawCircle(
        c,
        rad,
        Paint()
          ..color = kPhosphor.withOpacity(0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    if (model.hud.isNotEmpty) {
      paintLabel(canvas, model.hud, Offset(6, 4), kDim, size: 10);
    }
  }

  void _paintTrack(Canvas canvas, Track t,
      Offset Function(double, double) r2p, double scale) {
    final cls = t.classifier.best;
    final color = classColor(cls);
    final p = r2p(t.x, t.y);
    final tentative = t.status == TrackStatus.tentative;
    final coasting = t.status == TrackStatus.coasting;
    final alpha = coasting ? 0.45 : 1.0;
    final selected = model.selectedTrack == t.id;

    // Trail.
    final tr = t.trail;
    for (int i = 2; i + 1 < tr.length; i += 2) {
      final a = (i / tr.length);
      canvas.drawLine(
          r2p(tr[i - 2], tr[i - 1]),
          r2p(tr[i], tr[i + 1]),
          Paint()
            ..color = color.withOpacity(0.5 * a * alpha)
            ..strokeWidth = 1.4);
    }

    // Corner brackets.
    final h = math.max(9.0, 0.45 * scale);
    final pen = Paint()
      ..color = color.withOpacity(alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 2 : 1.4;
    final l = h * 0.55;
    for (final s in const [
      [-1.0, -1.0],
      [1.0, -1.0],
      [-1.0, 1.0],
      [1.0, 1.0]
    ]) {
      final o = p + Offset(s[0] * h, s[1] * h);
      if (tentative) {
        canvas.drawCircle(o, 1.2, Paint()..color = color.withOpacity(0.7));
        continue;
      }
      canvas.drawLine(o, o - Offset(s[0] * l, 0), pen);
      canvas.drawLine(o, o - Offset(0, s[1] * l), pen);
    }
    canvas.drawCircle(p, 2, Paint()..color = color.withOpacity(alpha));

    // Velocity vector (1 s ahead).
    if (t.speed > 0.2) {
      canvas.drawLine(p, r2p(t.x + t.vx, t.y + t.vy),
          Paint()
            ..color = color.withOpacity(0.8 * alpha)
            ..strokeWidth = 1.2);
    }

    // Lock reticle on the selected track.
    if (selected) {
      final spin = model.clock * 1.5;
      final rr = h * 1.9;
      final arc = Paint()
        ..color = color.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      for (int k = 0; k < 4; k++) {
        canvas.drawArc(Rect.fromCircle(center: p, radius: rr),
            spin + k * math.pi / 2, math.pi / 4, false, arc);
      }
    }

    final name = 'T-${t.id.toString().padLeft(2, '0')}';
    String tag;
    if (tentative) {
      tag = '$name  ACQUIRING';
    } else if (cls == null) {
      tag = '$name  ANALYSING';
    } else {
      tag = '$name  ${cls.label} ${(t.classifier.confidence * 100).round()}%';
    }
    if (coasting) tag = '$tag  (LOST)';
    paintLabel(canvas, tag, p + Offset(h + 4, -h - 4), color.withOpacity(alpha),
        size: 9, background: true);
  }

  @override
  bool shouldRepaint(covariant PpiPainter oldDelegate) => false;
}

/// Faint horizontal scan lines over a display, for the CRT feel.
class ScanlinePainter extends CustomPainter {
  const ScanlinePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x0DFFFFFF);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(covariant ScanlinePainter oldDelegate) => false;
}
