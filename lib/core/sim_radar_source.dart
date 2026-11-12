import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/fft.dart';
import 'radar_source.dart';
import 'scene.dart';

/// Tier 1: a synthetic rotating-beam FMCW radar.
///
/// For every beam position the engine synthesises one chirp of complex
/// baseband beat signal as a sum of tones (one per scatterer, beat frequency
/// proportional to range, carrier phase 4*pi*r/lambda, amplitude from a
/// simplified radar equation, two-way Gaussian beam gain), adds receiver
/// noise and transmit leakage, then windows and FFTs it into a range
/// profile. Nothing is drawn directly: the image is whatever the signal
/// processing recovers.
///
/// Scatterer model
///  * walls       dense point scatterers, specular-weighted (strong)
///  * furniture   perimeter scatterers (medium)
///  * person      torso + four limb scatterers with gait motion (weak)
///  * multipath   first-order wall images of each person: a full
///                wall-person-wall path and a weaker mixed path
///  * every wall crossed on the way to a scatterer costs 6 dB
///  * clutter     slow per-scatterer amplitude and phase drift
class SimRadarSource extends RadarSource {
  SimRadarSource(this.scene)
      : frame = PolarFrame(beams: 360, bins: 200, maxRange: 10);

  final SceneController scene;

  @override
  final PolarFrame frame;

  @override
  String get label => 'SIM';

  // ---- parameters set by the UI ----
  double sweepRate = 0.5; // rev/s
  double noise = 0.25; // 0..1
  bool playing = true;
  double personSpeed = 0.8; // m/s
  int trajectory = 0;

  set maxRange(double r) {
    if ((r - frame.maxRange).abs() > 1e-6) {
      frame.maxRange = r;
      frame.clear();
      _builtStaticRev = -1;
    }
  }

  // ---- constants ----
  static const int _n = 256; // samples per chirp
  static const double _lambda = 0.125; // 2.4 GHz carrier
  static const double _spacing = 0.08; // wall scatterer pitch, m
  static const double _wallLoss = 0.5; // amplitude factor per wall crossed
  static const double _reflect = 0.6; // wall reflection coefficient
  static const double _circleR = 1.5;
  static const double _lineL = 2.5;
  static const int _halfSpan = 4; // bearing buckets either side of a beam
  static final double _beamSigma = 1.4 * math.pi / 180; // two-way
  static final double _invTwoSigma2 = 1 / (2 * _beamSigma * _beamSigma);

  final Fft _fft = Fft(_n);
  final Float64List _re = Float64List(_n);
  final Float64List _im = Float64List(_n);
  final math.Random _rng = math.Random(7);

  // Effective wall segments (walls minus door gaps): ax, ay, bx, by per seg.
  final List<double> _seg = [];

  // Static scatterers.
  Float64List _sBearing = Float64List(0);
  Float64List _sBin = Float64List(0);
  Float64List _sAmp = Float64List(0);
  Float64List _sPhi = Float64List(0);
  Float64List _sHash = Float64List(0);
  final List<List<int>> _buckets = List.generate(360, (_) => <int>[]);
  int _builtStaticRev = -1;

  // Dynamic scatterers (people and their multipath images), rebuilt per tick.
  final List<double> _dBearing = [];
  final List<double> _dBin = [];
  final List<double> _dAmp = [];
  final List<double> _dPhi = [];

  final Set<int> _pending = <int>{};
  double _acc = 0;
  int _cursor = 0;
  double _time = 0;

  int get staticScattererCount => _sAmp.length;

  /// Ask for the sector around a world point to be re-illuminated on the next
  /// tick, so dragged objects show up without waiting for the sweep.
  void illuminate(double wx, double wy) {
    final b = math.atan2(wy - scene.radarY, wx - scene.radarX);
    _pending.add(((b * 180 / math.pi).round() % 360 + 360) % 360);
  }

  /// Re-derive a person's animation anchor from its current position, so the
  /// trajectory continues from wherever the user dropped it.
  void reanchor(SceneObject p) {
    _trajectoryOffset(p);
    p.ax = p.x - _ox;
    p.ay = p.y - _oy;
  }

  double _ox = 0, _oy = 0;

  void _trajectoryOffset(SceneObject p) {
    switch (trajectory) {
      case 0:
        _ox = _circleR * math.cos(p.phase);
        _oy = _circleR * math.sin(p.phase);
        break;
      case 1:
        final u = p.phase % (4 * _lineL);
        _ox = u < 2 * _lineL ? u - _lineL : 3 * _lineL - u;
        _oy = 0;
        break;
      default:
        _ox = p.x - p.ax;
        _oy = p.y - p.ay;
    }
  }

  void _animate(double dt) {
    for (final p in scene.objects) {
      if (p.kind != ObjKind.person) continue;
      if (p.held || personSpeed <= 0.001) {
        p.moving = false;
        continue;
      }
      p.moving = true;
      switch (trajectory) {
        case 0:
          p.phase += personSpeed * dt / _circleR;
          _trajectoryOffset(p);
          p.x = p.ax + _ox;
          p.y = p.ay + _oy;
          break;
        case 1:
          p.phase += personSpeed * dt;
          _trajectoryOffset(p);
          p.x = p.ax + _ox;
          p.y = p.ay + _oy;
          break;
        default:
          p.heading += (_rng.nextDouble() - 0.5) * 3.0 * dt;
          final dx = p.ax - p.x, dy = p.ay - p.y;
          if (dx * dx + dy * dy > 6.25) p.heading = math.atan2(dy, dx);
          p.x += personSpeed * math.cos(p.heading) * dt;
          p.y += personSpeed * math.sin(p.heading) * dt;
      }
      p.x = p.x.clamp(0.3, SceneController.worldW - 0.3).toDouble();
      p.y = p.y.clamp(0.3, SceneController.worldH - 0.3).toDouble();
      p.gait += personSpeed * dt * 5.0;
    }
  }

  // ---- geometry ----

  static double _cross(
          double ax, double ay, double bx, double by, double px, double py) =>
      (bx - ax) * (py - ay) - (by - ay) * (px - ax);

  static bool _intersects(double ax, double ay, double bx, double by,
      double cx, double cy, double dx, double dy) {
    final d1 = _cross(cx, cy, dx, dy, ax, ay);
    final d2 = _cross(cx, cy, dx, dy, bx, by);
    final d3 = _cross(ax, ay, bx, by, cx, cy);
    final d4 = _cross(ax, ay, bx, by, dx, dy);
    return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
  }

  /// Number of wall segments between the radar and a point.
  int _crossings(double px, double py, int skip) {
    final rx = scene.radarX, ry = scene.radarY;
    final ex = rx + (px - rx) * 0.995, ey = ry + (py - ry) * 0.995;
    int c = 0;
    final n = _seg.length ~/ 4;
    for (int j = 0; j < n; j++) {
      if (j == skip) continue;
      final o = j * 4;
      if (_intersects(
          rx, ry, ex, ey, _seg[o], _seg[o + 1], _seg[o + 2], _seg[o + 3])) {
        c++;
      }
    }
    return c;
  }

  static double _wrapBearing(double b) => b < 0 ? b + 2 * math.pi : b;

  void _rebuildStatic() {
    _builtStaticRev = scene.staticRevision;
    final rx = scene.radarX, ry = scene.radarY;
    final maxR = frame.maxRange;

    // 1. Walls minus door gaps.
    _seg.clear();
    final doors = scene.objects.where((o) => o.kind == ObjKind.door).toList();
    for (final w in scene.objects) {
      if (w.kind != ObjKind.wall) continue;
      final len = math.sqrt((w.x2 - w.x) * (w.x2 - w.x) +
          (w.y2 - w.y) * (w.y2 - w.y));
      if (len < 0.05) continue;
      final ux = (w.x2 - w.x) / len, uy = (w.y2 - w.y) / len;
      final gaps = <List<double>>[];
      for (final d in doors) {
        final t = (d.x - w.x) * ux + (d.y - w.y) * uy;
        final dist = ((d.x - w.x) * -uy + (d.y - w.y) * ux).abs();
        if (dist < 0.5 && t > -d.w / 2 && t < len + d.w / 2) {
          gaps.add([t - d.w / 2, t + d.w / 2]);
        }
      }
      gaps.sort((a, b) => a[0].compareTo(b[0]));
      double s = 0;
      for (final g in gaps) {
        if (g[0] - s > 0.05) {
          _seg.addAll([w.x + ux * s, w.y + uy * s, w.x + ux * g[0], w.y + uy * g[0]]);
        }
        if (g[1] > s) s = g[1];
      }
      if (len - s > 0.05) {
        _seg.addAll([w.x + ux * s, w.y + uy * s, w.x2, w.y2]);
      }
    }

    // 2. Scatterers.
    final bearing = <double>[], bin = <double>[], amp = <double>[];
    final phi = <double>[], hash = <double>[];
    void addScatterer(double px, double py, double a, int skipSeg) {
      final dx = px - rx, dy = py - ry;
      final r = math.sqrt(dx * dx + dy * dy);
      if (r < 0.25 || r > maxR * 1.2) return;
      final att = math.pow(_wallLoss, _crossings(px, py, skipSeg)).toDouble();
      bearing.add(_wrapBearing(math.atan2(dy, dx)));
      bin.add(r / maxR * frame.bins);
      amp.add(a * att / math.max(r, 0.5));
      phi.add((4 * math.pi * r / _lambda) % (2 * math.pi));
      hash.add(_rng.nextDouble() * 2 * math.pi);
    }

    final nSeg = _seg.length ~/ 4;
    for (int j = 0; j < nSeg; j++) {
      final ax = _seg[j * 4], ay = _seg[j * 4 + 1];
      final bx = _seg[j * 4 + 2], by = _seg[j * 4 + 3];
      final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
      final ux = (bx - ax) / len, uy = (by - ay) / len;
      final count = math.max(1, (len / _spacing).round());
      for (int k = 0; k < count; k++) {
        final t = (k + 0.5) / count * len;
        final px = ax + ux * t, py = ay + uy * t;
        final dx = px - rx, dy = py - ry;
        final r = math.sqrt(dx * dx + dy * dy);
        if (r < 1e-6) continue;
        // Specular weighting: strongest where the beam hits the wall square-on.
        final c = ((dx * -uy + dy * ux) / r).abs();
        addScatterer(px, py, 0.2 + 0.8 * c * c, j);
      }
    }
    for (final f in scene.objects) {
      if (f.kind != ObjKind.furniture) continue;
      final x0 = f.x - f.w / 2, x1 = f.x + f.w / 2;
      final y0 = f.y - f.h / 2, y1 = f.y + f.h / 2;
      final nx = math.max(1, (f.w / _spacing).round());
      final ny = math.max(1, (f.h / _spacing).round());
      for (int k = 0; k < nx; k++) {
        final px = x0 + (k + 0.5) / nx * f.w;
        addScatterer(px, y0, 0.45, -1);
        addScatterer(px, y1, 0.45, -1);
      }
      for (int k = 0; k < ny; k++) {
        final py = y0 + (k + 0.5) / ny * f.h;
        addScatterer(x0, py, 0.45, -1);
        addScatterer(x1, py, 0.45, -1);
      }
    }

    _sBearing = Float64List.fromList(bearing);
    _sBin = Float64List.fromList(bin);
    _sAmp = Float64List.fromList(amp);
    _sPhi = Float64List.fromList(phi);
    _sHash = Float64List.fromList(hash);
    for (final b in _buckets) {
      b.clear();
    }
    for (int i = 0; i < bearing.length; i++) {
      final deg = (bearing[i] * 180 / math.pi).floor() % 360;
      _buckets[deg].add(i);
    }
  }

  void _addDynamic(double px, double py, double a, {double? pathLen, double? atX, double? atY}) {
    final rx = scene.radarX, ry = scene.radarY;
    final bx = (atX ?? px) - rx, by = (atY ?? py) - ry;
    final dx = px - rx, dy = py - ry;
    final r = pathLen ?? math.sqrt(dx * dx + dy * dy);
    if (r < 0.25 || r > frame.maxRange * 1.2) return;
    _dBearing.add(_wrapBearing(math.atan2(by, bx)));
    _dBin.add(r / frame.maxRange * frame.bins);
    _dAmp.add(a / math.max(r, 0.5));
    _dPhi.add((4 * math.pi * r / _lambda) % (2 * math.pi));
  }

  void _rebuildDynamic() {
    _dBearing.clear();
    _dBin.clear();
    _dAmp.clear();
    _dPhi.clear();
    final rx = scene.radarX, ry = scene.radarY;
    final nSeg = _seg.length ~/ 4;
    for (final p in scene.objects) {
      if (p.kind != ObjKind.person) continue;
      final att = math.pow(_wallLoss, _crossings(p.x, p.y, -1)).toDouble();
      // Torso.
      _addDynamic(p.x, p.y, 0.9 * att);
      // Limbs: swing along the heading while walking, small sway otherwise.
      final swing = p.moving ? 0.22 : 0.02;
      final s = math.sin(p.gait) * swing;
      final breathe = 0.004 * math.sin(_time * 1.6);
      _addDynamic(p.x + 0.18 + s, p.y + 0.10, 0.34 * att);
      _addDynamic(p.x - 0.18 - s, p.y - 0.10, 0.34 * att);
      _addDynamic(p.x + 0.10 - s, p.y - 0.20 + breathe, 0.28 * att);
      _addDynamic(p.x - 0.10 + s, p.y + 0.20 - breathe, 0.28 * att);

      // Multipath: mirror the person in each wall segment.
      final ddx = p.x - rx, ddy = p.y - ry;
      final d = math.sqrt(ddx * ddx + ddy * ddy);
      for (int j = 0; j < nSeg; j++) {
        final ax = _seg[j * 4], ay = _seg[j * 4 + 1];
        final bx = _seg[j * 4 + 2], by = _seg[j * 4 + 3];
        final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        final ux = (bx - ax) / len, uy = (by - ay) / len;
        final sP = _cross(ax, ay, bx, by, p.x, p.y);
        final sR = _cross(ax, ay, bx, by, rx, ry);
        if (sP * sR <= 0) continue; // must be on the same side to reflect
        final t = (p.x - ax) * ux + (p.y - ay) * uy;
        final mx = 2 * (ax + t * ux) - p.x, my = 2 * (ay + t * uy) - p.y;
        final u = sR.abs() / (sR.abs() + sP.abs());
        final qx = rx + (mx - rx) * u, qy = ry + (my - ry) * u;
        final tq = (qx - ax) * ux + (qy - ay) * uy;
        if (tq < 0 || tq > len) continue; // reflection point misses the wall
        final l = math.sqrt((mx - rx) * (mx - rx) + (my - ry) * (my - ry));
        // Radar -> wall -> person -> wall -> radar: seen at the image position.
        _addDynamic(mx, my, 0.9 * att * _reflect * _reflect, pathLen: l);
        // Radar -> person -> wall -> radar: half-way range, person bearing,
        // heavily suppressed by the narrow beam.
        _addDynamic(p.x, p.y, 0.9 * att * _reflect * 0.25,
            pathLen: (d + l) / 2);
      }
    }
  }

  // ---- signal synthesis ----

  void _tone(double bin, double phase, double a) {
    final w = 2 * math.pi * bin / _n;
    final wr = math.cos(w), wi = math.sin(w);
    double pr = a * math.cos(phase), pq = a * math.sin(phase);
    final re = _re, im = _im;
    for (int n = 0; n < _n; n++) {
      re[n] += pr;
      im[n] += pq;
      final t = pr * wr - pq * wi;
      pq = pr * wi + pq * wr;
      pr = t;
    }
  }

  void _synthBeam(int b) {
    final beams = frame.beams, bins = frame.bins;
    final th = b * 2 * math.pi / beams;
    final re = _re, im = _im;
    re.fillRange(0, _n, 0);
    im.fillRange(0, _n, 0);
    final t = _time;

    for (int o = -_halfSpan; o <= _halfSpan; o++) {
      final bucket = _buckets[(b + o) % 360];
      for (int q = 0; q < bucket.length; q++) {
        final i = bucket[q];
        double d = _sBearing[i] - th;
        if (d > math.pi) d -= 2 * math.pi;
        if (d < -math.pi) d += 2 * math.pi;
        final h = _sHash[i];
        // Slow clutter drift in amplitude and phase.
        final a = _sAmp[i] *
            math.exp(-d * d * _invTwoSigma2) *
            (1 + 0.08 * math.sin(0.5 * t + h));
        if (a < 1e-5) continue;
        _tone(_sBin[i], _sPhi[i] + 0.15 * math.sin(0.23 * t + 1.7 * h), a);
      }
    }
    for (int i = 0; i < _dAmp.length; i++) {
      double d = _dBearing[i] - th;
      if (d > math.pi) d -= 2 * math.pi;
      if (d < -math.pi) d += 2 * math.pi;
      if (d.abs() > 4 * _beamSigma) continue;
      _tone(_dBin[i], _dPhi[i], _dAmp[i] * math.exp(-d * d * _invTwoSigma2));
    }
    // Transmit leakage ("main bang") with slow drift.
    _tone(0.6, 0.4 * math.sin(0.11 * t), 0.5 * (1 + 0.2 * math.sin(0.07 * t)));

    // Thermal noise (complex Gaussian, Box-Muller) and window.
    final double sigma = 0.01 * math.pow(10, 2 * noise).toDouble();
    final hann = _fft.hann;
    for (int n = 0; n < _n; n++) {
      final u1 = _rng.nextDouble() + 1e-12, u2 = _rng.nextDouble();
      final m = sigma * math.sqrt(-2 * math.log(u1));
      re[n] = (re[n] + m * math.cos(2 * math.pi * u2)) * hann[n];
      im[n] = (im[n] + m * math.sin(2 * math.pi * u2)) * hann[n];
    }
    _fft.transform(re, im);

    // Log-detect into the polar frame: 0 dB full scale, 60 dB dynamic range.
    const norm = 1.0 / (_n / 2) / (_n / 2);
    final base = b * bins;
    final vals = frame.values, prev = frame.previous;
    for (int k = 0; k < bins; k++) {
      final p = (re[k] * re[k] + im[k] * im[k]) * norm;
      double v = (4.342944819 * math.log(p + 1e-12) + 60) / 60;
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      prev[base + k] = vals[base + k];
      vals[base + k] = v;
    }
    frame.beamTime[b] = t;
  }

  @override
  void tick(double dt) {
    if (dt > 0.1) dt = 0.1;
    _time += dt;
    if (playing) _animate(dt);
    if (_builtStaticRev != scene.staticRevision) _rebuildStatic();
    _rebuildDynamic();

    if (_pending.isNotEmpty) {
      final done = <int>{};
      for (final c in _pending) {
        for (int o = -7; o <= 7; o++) {
          final b = (c + o) % 360;
          if (done.add(b)) _synthBeam(b);
        }
      }
      _pending.clear();
    }

    _acc += sweepRate * frame.beams * dt;
    int n = _acc.floor();
    _acc -= n;
    if (n > 120) n = 120;
    for (int i = 0; i < n; i++) {
      _synthBeam(_cursor);
      _cursor = (_cursor + 1) % frame.beams;
    }
    frame.sweepAngle = _cursor * 2 * math.pi / frame.beams;
    frame.time = _time;
  }
}
