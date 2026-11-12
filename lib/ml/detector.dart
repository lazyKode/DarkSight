import 'dart:math' as math;
import 'dart:typed_data';

import '../core/radar_source.dart';

/// A labelled box in metres, relative to the radar (x right, y down).
class Detection {
  const Detection(this.minX, this.minY, this.maxX, this.maxY, this.label,
      this.score);
  final double minX, minY, maxX, maxY;
  final String label; // "person" | "object" | "wall"
  final double score;
}

class _Track {
  _Track(this.x, this.y, this.t);
  double x, y, t;
}

/// The Tier 1 "AI overlay" backend.
///
/// This is a classical pipeline, not a neural network: per-beam CA-CFAR,
/// sweep-to-sweep change detection, projection onto a Cartesian grid,
/// run-length wall extraction, connected components and a size/motion rule
/// set, plus a short track memory so a person who stops walking keeps the
/// label. It sits behind the same interface a TensorFlow Lite / Core ML
/// model would use (PolarFrame in, List<Detection> out); see README for the
/// plan to swap one in.
class RadarDetector {
  static const int g = 96;
  final Uint8List _occ = Uint8List(g * g);
  final Uint8List _cls = Uint8List(g * g);
  final Uint16List _hRun = Uint16List(g * g);
  final Uint16List _vRun = Uint16List(g * g);
  final Int32List _stack = Int32List(g * g);
  final Float32List _pre = Float32List(1025);
  final List<_Track> _tracks = [];

  List<Detection> detect(PolarFrame f) {
    final beams = f.beams, bins = f.bins;
    final vals = f.values, prev = f.previous;
    final maxR = f.maxRange;
    final cell = 2 * maxR / g;
    final now = f.time;
    _occ.fillRange(0, g * g, 0);
    _cls.fillRange(0, g * g, 0);

    // 1. CA-CFAR along range (log domain) + change detection.
    const guard = 2, train = 8;
    final pre = _pre;
    for (int b = 0; b < beams; b++) {
      if (f.beamTime[b] < -1e8) continue;
      final base = b * bins;
      pre[0] = 0;
      for (int k = 0; k < bins; k++) {
        pre[k + 1] = pre[k] + vals[base + k];
      }
      final th = b * 2 * math.pi / beams;
      final cs = math.cos(th), sn = math.sin(th);
      for (int k = 6; k < bins; k++) {
        final v = vals[base + k];
        if (v < 0.3) continue;
        bool hit = v > 0.6; // strong returns pass outright
        if (!hit) {
          final lo1 = math.max(0, k - guard - train), lo2 = k - guard - 1;
          final hi1 = k + guard + 1, hi2 = math.min(bins - 1, k + guard + train);
          double sum = 0;
          int cnt = 0;
          if (lo2 >= lo1) {
            sum += pre[lo2 + 1] - pre[lo1];
            cnt += lo2 - lo1 + 1;
          }
          if (hi2 >= hi1) {
            sum += pre[hi2 + 1] - pre[hi1];
            cnt += hi2 - hi1 + 1;
          }
          hit = cnt > 0 && v - sum / cnt > 0.22; // ~13 dB over the local mean
        }
        if (!hit) continue;
        final r = (k + 0.5) / bins * maxR;
        final gx = ((r * cs + maxR) / cell).floor();
        final gy = ((r * sn + maxR) / cell).floor();
        if (gx < 0 || gy < 0 || gx >= g || gy >= g) continue;
        final moving = (v - prev[base + k]).abs() > 0.17; // ~10 dB change
        _occ[gy * g + gx] |= moving ? 3 : 1;
      }
    }

    // 2. Run lengths: long straight runs are structure.
    for (int y = 0; y < g; y++) {
      int x = 0;
      while (x < g) {
        if (_occ[y * g + x] == 0) {
          _hRun[y * g + x] = 0;
          x++;
          continue;
        }
        final s = x;
        while (x < g && _occ[y * g + x] != 0) {
          x++;
        }
        for (int i = s; i < x; i++) {
          _hRun[y * g + i] = x - s;
        }
      }
    }
    for (int x = 0; x < g; x++) {
      int y = 0;
      while (y < g) {
        if (_occ[y * g + x] == 0) {
          _vRun[y * g + x] = 0;
          y++;
          continue;
        }
        final s = y;
        while (y < g && _occ[y * g + x] != 0) {
          y++;
        }
        for (int i = s; i < y; i++) {
          _vRun[i * g + x] = y - s;
        }
      }
    }
    final wallRun = math.max(4, (1.2 / cell).ceil());
    for (int i = 0; i < g * g; i++) {
      final o = _occ[i];
      if (o == 0) continue;
      final h = _hRun[i], v = _vRun[i];
      if (h >= wallRun || v >= wallRun) {
        _cls[i] = h >= v ? 1 : 2; // horizontal / vertical structure
      } else {
        _cls[i] = (o & 2) != 0 ? 3 : 4; // moving / static blob
      }
    }

    // 3. Connected components per class.
    final comps = <List<int>>[]; // cls, minX, minY, maxX, maxY, count, onWall
    for (int i = 0; i < g * g; i++) {
      final c = _cls[i];
      if (c == 0 || c > 4) continue;
      int sp = 0;
      _stack[sp++] = i;
      _cls[i] = c + 8; // visited
      int minX = g, minY = g, maxX = -1, maxY = -1, count = 0, onWall = 0;
      while (sp > 0) {
        final p = _stack[--sp];
        final px = p % g, py = p ~/ g;
        count++;
        if (px < minX) minX = px;
        if (px > maxX) maxX = px;
        if (py < minY) minY = py;
        if (py > maxY) maxY = py;
        for (int dy = -1; dy <= 1; dy++) {
          final ny = py + dy;
          if (ny < 0 || ny >= g) continue;
          for (int dx = -1; dx <= 1; dx++) {
            final nx = px + dx;
            if (nx < 0 || nx >= g) continue;
            final q = ny * g + nx;
            final cq = _cls[q];
            if (cq == c) {
              _cls[q] = c + 8;
              _stack[sp++] = q;
            } else if (cq == 1 || cq == 2 || cq == 9 || cq == 10) {
              onWall = 1; // blob touches structure
            }
          }
        }
      }
      comps.add([c, minX, minY, maxX, maxY, count, onWall]);
    }

    // 4. Rules.
    final out = <Detection>[];
    _tracks.removeWhere((t) => now - t.t > 45);
    Detection box(List<int> c, String label, double score) => Detection(
        c[1] * cell - maxR,
        c[2] * cell - maxR,
        (c[3] + 1) * cell - maxR,
        (c[4] + 1) * cell - maxR,
        label,
        score);
    double cx(List<int> c) => (c[1] + c[3] + 1) / 2 * cell - maxR;
    double cy(List<int> c) => (c[2] + c[4] + 1) / 2 * cell - maxR;
    double extent(List<int> c) =>
        math.max(c[3] - c[1] + 1, c[4] - c[2] + 1) * cell;

    for (final c in comps) {
      if ((c[0] == 1 || c[0] == 2) && c[5] >= 3) {
        out.add(box(c, 'wall', 0.9));
      }
    }
    // Moving blobs first, so they can claim and refresh tracks.
    for (final c in comps) {
      if (c[0] != 3 || c[5] < 2) continue;
      final e = extent(c);
      if (e > 2.0) continue;
      final x = cx(c), y = cy(c);
      _Track? near;
      for (final t in _tracks) {
        if ((t.x - x) * (t.x - x) + (t.y - y) * (t.y - y) < 1.0) near = t;
      }
      if (near != null) {
        near.x = x;
        near.y = y;
        near.t = now;
      } else {
        _tracks.add(_Track(x, y, now));
      }
      out.add(box(c, 'person', math.min(0.95, 0.5 + c[5] * 0.05)));
    }
    for (final c in comps) {
      // Static fragments hanging off a wall are wall, not objects.
      if (c[0] != 4 || c[5] < 2 || c[6] == 1) continue;
      final x = cx(c), y = cy(c);
      _Track? near;
      for (final t in _tracks) {
        if ((t.x - x) * (t.x - x) + (t.y - y) * (t.y - y) < 0.8) near = t;
      }
      if (near != null) {
        if (now - near.t < 1.0) continue; // part of a blob already boxed
        out.add(box(c, 'person', 0.55)); // was moving here recently
      } else {
        out.add(box(c, 'object', 0.6));
      }
    }
    return out;
  }
}
