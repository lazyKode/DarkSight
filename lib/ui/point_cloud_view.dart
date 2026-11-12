import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/sdr_radar_source.dart';
import 'theme.dart';

/// 3D point cloud, software-projected on a Canvas (a few hundred points, so
/// no GL context is needed). Axes: x cross-range, y range, z radial
/// velocity. A linear array gives no elevation, so velocity is used as the
/// third axis; with a 2D MIMO array z becomes height.
class PointCloudPainter extends CustomPainter {
  PointCloudPainter(this.source, this.yaw, Listenable repaint)
      : super(repaint: repaint);
  final SdrRadarSource source;
  final ValueNotifier<double> yaw;

  @override
  void paint(Canvas canvas, Size size) {
    final maxR = source.cfg.maxRange;
    final cy = math.cos(yaw.value), sy = math.sin(yaw.value);
    const pitch = 0.95; // rad, looking down
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final f = math.min(size.width, size.height) * 0.9;
    final centre = Offset(size.width / 2, size.height * 0.5);

    Offset? project(double x, double y, double z) {
      // Centre the scene, rotate about the vertical axis, then tilt.
      final px = x, py = y - maxR / 2;
      final rx = px * cy - py * sy;
      final ry = px * sy + py * cy;
      final dy = ry * cp - z * sp; // depth
      final dz = ry * sp + z * cp; // up on screen
      final depth = dy + maxR * 1.6;
      if (depth < 0.5) return null;
      final s = f / depth;
      return centre + Offset(rx * s, -dz * s);
    }

    void line(double x0, double y0, double x1, double y1, Paint p) {
      final a = project(x0, y0, 0), b = project(x1, y1, 0);
      if (a != null && b != null) canvas.drawLine(a, b, p);
    }

    // Ground grid, 1 m pitch.
    final grid = Paint()
      ..color = kPhosphor.withOpacity(0.12)
      ..strokeWidth = 1;
    final half = maxR / 2;
    for (double g = -half; g <= half + 1e-6; g += 1) {
      line(g, 0, g, maxR, grid);
    }
    for (double g = 0; g <= maxR + 1e-6; g += 1) {
      line(-half, g, half, g, grid);
    }
    final radar = project(0, 0, 0);
    if (radar != null) {
      canvas.drawCircle(radar, 4, Paint()..color = kPhosphor);
      paintLabel(canvas, 'RADAR', radar + const Offset(6, -4), kPhosphor,
          size: 9);
    }

    // Points: older frames dimmer; colour by radial velocity.
    final hist = source.history;
    for (int h = 0; h < hist.length; h++) {
      final age = (h + 1) / hist.length;
      for (final p in hist[h]) {
        final at = project(p.x, p.y, p.velocity * 0.6);
        final foot = project(p.x, p.y, 0);
        if (at == null) continue;
        final color = p.velocity.abs() < 0.3
            ? kPhosphor
            : (p.velocity < 0 ? kAlert : const Color(0xFF4FC3F7));
        if (foot != null && h == hist.length - 1) {
          canvas.drawLine(
              foot, at, Paint()..color = color.withOpacity(0.25));
        }
        canvas.drawCircle(
            at,
            1.5 + 2.5 * p.power * age,
            Paint()..color = color.withOpacity(0.15 + 0.85 * age * age));
      }
    }

    paintLabel(
        canvas,
        'x cross-range   y range   z radial velocity\n'
        'green static   red approaching   blue receding   drag to rotate',
        const Offset(8, 8),
        kDim,
        size: 10);
  }

  @override
  bool shouldRepaint(covariant PointCloudPainter oldDelegate) => false;
}
