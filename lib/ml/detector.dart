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

/// Search-sweep structure detector.
///
/// Per-beam CA-CFAR, sweep-to-sweep change detection, projection onto a
/// Cartesian grid, run-length wall extraction and connected components.
/// Outputs "wall" and "object" (static) boxes, and "motion" blobs that start
/// tracks; what a moving thing *is* is decided by the track dwell and
/// TargetClassifier, not here. Also answers how many detected walls lie
/// between the radar and a point (used to correct RCS for wall loss).
class RadarDetector {
  static const int g = 96;
  final Uint8List _occ = Uint8List(g * g);
  final Uint8List _cls = Uint8List(g * g);
  final Uint16List _hRun = Uint16List(g * g);
  final Uint16List _vRun = Uint16List(g * g);
  final Int32List _stack = Int32List(g * g);
  final Uint8List _wall = Uint8List(g * g);
  Float32List _row = Float32List(0);
  double _cell = 0.2, _maxR = 10;
  final Float32List _pre = Float32List(1025);

  List<Detection> detect(PolarFrame f) {
    final beams = f.beams, bins = f.bins;
    final vals = f.values, mot = f.motion;
    if (_row.length != bins) _row = Float32List(bins);
    final maxR = f.maxRange;
    final cell = 2 * maxR / g;
    _cell = cell;
    _maxR = maxR;
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
        _occ[gy * g + gx] |= 1;
      }
      // Motion: two-pulse MTI residual well above this beam's median.
      if (f.time - f.beamTime[b] > 0.6) continue; // stale beam
      for (int k = 0; k < bins; k++) {
        _row[k] = mot[base + k];
      }
      final sorted = Float32List.fromList(_row)..sort();
      final floor = sorted[bins ~/ 2];
      for (int k = 6; k < bins; k++) {
        if (mot[base + k] < floor + 0.2) continue; // 12 dB over the floor
        final r = (k + 0.5) / bins * maxR;
        final gx = ((r * cs + maxR) / cell).floor();
        final gy = ((r * sn + maxR) / cell).floor();
        if (gx < 0 || gy < 0 || gx >= g || gy >= g) continue;
        _occ[gy * g + gx] |= 3;
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
    _wall.fillRange(0, g * g, 0);
    for (int i = 0; i < g * g; i++) {
      final o = _occ[i];
      if (o == 0) continue;
      final h = _hRun[i], v = _vRun[i];
      if (h >= wallRun || v >= wallRun) {
        _cls[i] = h >= v ? 1 : 2; // horizontal / vertical structure
        _wall[i] = 1;
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
    Detection box(List<int> c, String label, double score) => Detection(
        c[1] * cell - maxR,
        c[2] * cell - maxR,
        (c[3] + 1) * cell - maxR,
        (c[4] + 1) * cell - maxR,
        label,
        score);
    double extent(List<int> c) =>
        math.max(c[3] - c[1] + 1, c[4] - c[2] + 1) * cell;

    for (final c in comps) {
      if ((c[0] == 1 || c[0] == 2) && c[5] >= 3) {
        out.add(box(c, 'wall', 0.9));
      } else if (c[0] == 3 && c[5] >= 2 && extent(c) <= 2.0) {
        out.add(box(c, 'motion', math.min(0.95, 0.5 + c[5] * 0.05)));
      } else if (c[0] == 4 && c[5] >= 2 && c[6] == 0) {
        // Static fragments hanging off a wall are wall, not objects.
        out.add(box(c, 'object', 0.6));
      }
    }
    return out;
  }

  /// Walls detected between the radar and (x, y) (metres, radar-relative),
  /// ignoring the last 0.4 m in front of the point.
  int wallsBetween(double x, double y) {
    final r = math.sqrt(x * x + y * y);
    if (r < 0.5) return 0;
    final steps = ((r - 0.4) / (_cell * 0.5)).floor();
    int count = 0;
    bool inWall = false;
    for (int i = 1; i <= steps; i++) {
      final t = i * _cell * 0.5 / r;
      final gx = ((x * t + _maxR) / _cell).floor();
      final gy = ((y * t + _maxR) / _cell).floor();
      if (gx < 0 || gy < 0 || gx >= g || gy >= g) break;
      final w = _wall[gy * g + gx] == 1;
      if (w && !inWall) count++;
      inWall = w;
    }
    return count;
  }
}
