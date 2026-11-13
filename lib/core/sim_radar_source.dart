import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/fft.dart';
import '../dsp/radar_constants.dart';
import '../ml/detector.dart';
import 'bodies.dart';
import 'radar_source.dart';
import 'scene.dart';
import 'tracker.dart';

/// Tier 1: a simulated 2.4 GHz FMCW radar with an electronically steered
/// beam that interleaves two jobs, like a real phased-array tracker:
///
///  * SEARCH: the beam sweeps 360 degrees, one 256-sample chirp per degree,
///    synthesised from every scatterer in the scene, windowed and FFT'd into
///    a range profile. This is the PPI picture.
///  * TRACK DWELL: for every track the beam stares at the target at 256
///    chirps/s with two squinted receive lobes (monopulse), giving a 15-bin
///    range gate per chirp. The processing turns that into range, angle,
///    Doppler, a micro-Doppler spectrogram, gait cadence, radar cross-section
///    and breathing rate, and classifies the target from those.
///
/// This class plays the hardware: it knows the scene. Everything from the
/// receiver samples onward (TrackProcessor, Tracker, TargetClassifier,
/// RadarDetector) sees only signals.
///
/// Physics in the model
///  * point targets (bodies): amplitude G * sqrt(rcs) / r^2 (radar equation)
///  * walls: specular plate return, amplitude falls as 1/r
///  * each wall crossed: two-way amplitude x 0.5 (6 dB)
///  * bodies: torso plus limbs or legs with gait motion, breathing chest,
///    per-individual size and gait; fans: hub plus three rotating blades
///  * multipath: first-order wall images of each body
///  * slow clutter drift (1 % amplitude, 0.02 rad), transmit leakage,
///    thermal noise
class SimRadarSource extends RadarSource {
  SimRadarSource(this.scene)
      : frame = PolarFrame(beams: 360, bins: Radar.bins, maxRange: 10);

  final SceneController scene;

  @override
  final PolarFrame frame;

  @override
  String get label => 'SIM';

  final Tracker tracker = Tracker();
  final RadarDetector detector = RadarDetector();

  /// Walls and static objects from the search sweep (no movers: those are
  /// tracks).
  List<Detection> structure = const [];

  // ---- parameters set by the UI ----
  double sweepRate = 0.5; // rev/s
  double _noise = 0.25; // 0..1
  bool playing = true;
  double personSpeed = 0.8; // m/s
  int trajectory = 0;

  double get noise => _noise;
  set noise(double v) {
    _noise = v;
    tracker.noise = v;
    for (final t in tracker.tracks) {
      t.processor.noise = v;
    }
  }

  set maxRange(double r) {
    if ((r - frame.maxRange).abs() > 1e-6) {
      frame.maxRange = r;
      frame.clear();
      tracker.clear();
      tracker.maxRange = r;
      _builtStaticRev = -1;
    }
  }

  // ---- constants ----
  static const int _n = Radar.samples;
  static const double _lambda = Radar.lambda;
  static const double _spacing = 0.08; // wall scatterer pitch, m
  static const double _reflect = 0.6; // wall reflection coefficient
  static const double _circleR = 1.5;
  static const double _lineL = 2.5;
  static const int _halfSpan = 4; // bearing buckets either side of a beam
  static const double _beamSigma = Radar.beamSigma;
  static const double _invTwoSigma2 = 1 / (2 * _beamSigma * _beamSigma);

  final Fft _fft = Fft(_n);
  final Float64List _re = Float64List(_n);
  final Float64List _im = Float64List(_n);
  final Float64List _re2 = Float64List(_n);
  final Float64List _im2 = Float64List(_n);

  // Snapshots of the dynamic scatterer set at recent chirp times, for the
  // search sweep's two-pulse MTI.
  final List<List<Float64List>> _snap = [];
  int _snapHead = 0;
  final math.Random _rng = math.Random(7);
  final Float64List _resp = Float64List(2);

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

  // Dynamic scatterers (bodies and their multipath images).
  final List<double> _dBearing = [];
  final List<double> _dBin = [];
  final List<double> _dAmp = [];
  final List<double> _dPhi = [];

  // Scratch lists for body scatterers.
  final List<double> _bx = [], _by = [], _ba = [];

  final Set<int> _pending = <int>{};
  double _acc = 0;
  double _chirpAcc = 0;
  int _cursor = 0;
  double _time = 0;
  double _detectClock = 0;

  int get staticScattererCount => _sAmp.length;
  double get time => _time;

  /// Ask for the sector around a world point to be re-illuminated on the next
  /// tick, so dragged objects show up without waiting for the sweep.
  void illuminate(double wx, double wy) {
    final b = math.atan2(wy - scene.radarY, wx - scene.radarX);
    _pending.add(((b * 180 / math.pi).round() % 360 + 360) % 360);
  }

  /// Re-derive a person's animation anchor from its current position, so the
  /// trajectory continues from wherever the user dropped it.
  void reanchor(SceneObject p) {
    p.path.clear();
    p.pause = 1.5;
    if (p.kind != ObjKind.person) {
      p.ax = p.x;
      p.ay = p.y;
      return;
    }
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

  // ---- animation (simulator ground truth) ----

  void _animate(double dt) {
    for (final p in scene.objects) {
      final body = p.body;
      if (body == null) continue;
      if (p.held) {
        p.moving = false;
        p.speed = 0;
        continue;
      }
      final ox = p.x, oy = p.y;
      switch (p.kind) {
        case ObjKind.person:
          if (personSpeed <= 0.001) {
            p.speed = 0;
            p.path.clear();
            break;
          }
          switch (trajectory) {
            case 0:
              p.phase += personSpeed * dt / _circleR;
              _trajectoryOffset(p);
              p.x = p.ax + _ox;
              p.y = p.ay + _oy;
              p.speed = personSpeed;
              break;
            case 1:
              p.phase += personSpeed * dt;
              _trajectoryOffset(p);
              p.x = p.ax + _ox;
              p.y = p.ay + _oy;
              p.speed = personSpeed;
              break;
            case 2:
              _wander(p, personSpeed, 2.5, dt);
              p.speed = personSpeed;
              break;
            default:
              _natural(p, personSpeed, dt, standLong: true);
          }
          break;
        case ObjKind.dog:
        case ObjKind.cat:
          p.behaviourTimer -= dt;
          if (p.behaviourTimer <= 0) {
            p.resting = !p.resting;
            p.behaviourTimer = p.resting
                ? 6 + _rng.nextDouble() * 14
                : 5 + _rng.nextDouble() * 10;
          }
          if (p.resting) {
            p.speed += (0 - p.speed) * math.min(1, dt * 2);
            if (p.speed > 0.02) {
              p.x += p.speed * math.cos(p.heading) * dt;
              p.y += p.speed * math.sin(p.heading) * dt;
            }
          } else if (p.stayNear) {
            p.speed += (body.cruiseSpeed - p.speed) * math.min(1, dt * 2);
            _wander(p, p.speed, 1.8, dt);
          } else {
            _natural(p, body.cruiseSpeed, dt, standLong: false);
          }
          break;
        default:
          p.speed = 0;
      }
      p.x = p.x.clamp(0.3, SceneController.worldW - 0.3).toDouble();
      p.y = p.y.clamp(0.3, SceneController.worldH - 0.3).toDouble();
      final mx = p.x - ox, my = p.y - oy;
      if (mx * mx + my * my > 1e-10) p.heading = math.atan2(my, mx);
      p.moving = p.speed > 0.05;
      p.gait += 2 * math.pi * body.legFreq(p.speed) * dt;
    }
  }

  // ---- natural movement: pick a place, walk there through doorways ----

  /// True if the straight line between two points crosses no wall (door
  /// gaps are open).
  bool _clear(double ax, double ay, double bx, double by) {
    final n = _seg.length ~/ 4;
    for (int j = 0; j < n; j++) {
      final o = j * 4;
      if (_intersects(
          ax, ay, bx, by, _seg[o], _seg[o + 1], _seg[o + 2], _seg[o + 3])) {
        return false;
      }
    }
    return true;
  }

  double _wallDistance(double x, double y) {
    double best = 1e9;
    final n = _seg.length ~/ 4;
    for (int j = 0; j < n; j++) {
      final ax = _seg[j * 4], ay = _seg[j * 4 + 1];
      final bx = _seg[j * 4 + 2], by = _seg[j * 4 + 3];
      final vx = bx - ax, vy = by - ay;
      final l2 = vx * vx + vy * vy;
      double t = l2 < 1e-9 ? 0 : ((x - ax) * vx + (y - ay) * vy) / l2;
      t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
      final dx = ax + t * vx - x, dy = ay + t * vy - y;
      best = math.min(best, math.sqrt(dx * dx + dy * dy));
    }
    return best;
  }

  /// Chooses a destination somewhere in the building and a route to it:
  /// straight if nothing is in the way, otherwise through one or two door
  /// gaps (each crossed square-on via points either side of the gap).
  bool _planTrip(SceneObject p) {
    if (_seg.isEmpty) return false;
    double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
    for (int i = 0; i < _seg.length; i += 2) {
      minX = math.min(minX, _seg[i]);
      maxX = math.max(maxX, _seg[i]);
      minY = math.min(minY, _seg[i + 1]);
      maxY = math.max(maxY, _seg[i + 1]);
    }
    if (maxX - minX < 1.5 || maxY - minY < 1.5) return false;
    // Door crossing points: 0.5 m either side of each gap, perpendicular to
    // the wall it sits in.
    final doors = <List<double>>[];
    for (final d in scene.objects) {
      if (d.kind != ObjKind.door) continue;
      double nx = 0, ny = 0, bestD = 1e9;
      for (final w in scene.objects) {
        if (w.kind != ObjKind.wall) continue;
        final vx = w.x2 - w.x, vy = w.y2 - w.y;
        final l = math.sqrt(vx * vx + vy * vy);
        if (l < 0.05) continue;
        final dist = ((d.x - w.x) * vy - (d.y - w.y) * vx).abs() / l;
        if (dist < bestD) {
          bestD = dist;
          nx = -vy / l;
          ny = vx / l;
        }
      }
      if (bestD > 0.5) continue;
      doors.add([d.x + nx * 0.5, d.y + ny * 0.5, d.x - nx * 0.5, d.y - ny * 0.5]);
    }
    List<double>? via(List<double> d, double fx, double fy, double tx, double ty) {
      // Enter from whichever side is reachable.
      for (final s in [0, 2]) {
        final ix = d[s], iy = d[s + 1], ox = d[2 - s], oy = d[3 - s];
        if (_clear(fx, fy, ix, iy) && _clear(ox, oy, tx, ty)) {
          return [ix, iy, ox, oy];
        }
      }
      return null;
    }

    for (int attempt = 0; attempt < 16; attempt++) {
      final tx = minX + 0.6 + _rng.nextDouble() * (maxX - minX - 1.2);
      final ty = minY + 0.6 + _rng.nextDouble() * (maxY - minY - 1.2);
      if (_wallDistance(tx, ty) < 0.5) continue;
      final dx = tx - p.x, dy = ty - p.y;
      if (dx * dx + dy * dy < 2.5) continue;
      if (_clear(p.x, p.y, tx, ty)) {
        p.path
          ..clear()
          ..addAll([tx, ty]);
        return true;
      }
      for (final d in doors) {
        final r = via(d, p.x, p.y, tx, ty);
        if (r != null) {
          p.path
            ..clear()
            ..addAll([...r, tx, ty]);
          return true;
        }
      }
      for (final d1 in doors) {
        for (final d2 in doors) {
          if (identical(d1, d2)) continue;
          for (final s in [0, 2]) {
            final ix = d1[s], iy = d1[s + 1], ox = d1[2 - s], oy = d1[3 - s];
            if (!_clear(p.x, p.y, ix, iy)) continue;
            final r = via(d2, ox, oy, tx, ty);
            if (r != null) {
              p.path
                ..clear()
                ..addAll([ix, iy, ox, oy, ...r, tx, ty]);
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  /// Walks a body along its path with human-like steering: limited turn
  /// rate, slowing for corners and on arrival. At the end it stands still
  /// for a while (people sometimes for half a minute) before the next trip.
  void _natural(SceneObject p, double cruise, double dt,
      {required bool standLong}) {
    if (p.pause > 0) {
      p.pause -= dt;
      p.speed += (0 - p.speed) * math.min(1, dt * 3);
      return;
    }
    if (p.path.isEmpty) {
      if (_planTrip(p)) {
        p.legSpeed = cruise * (0.8 + 0.4 * _rng.nextDouble());
      } else {
        p.pause = 1 + _rng.nextDouble() * 2;
      }
      return;
    }
    final tx = p.path[0], ty = p.path[1];
    final dx = tx - p.x, dy = ty - p.y;
    final d = math.sqrt(dx * dx + dy * dy);
    final last = p.path.length == 2;
    if (d < (last ? 0.15 : 0.25)) {
      p.path.removeRange(0, 2);
      if (p.path.isEmpty) {
        p.pause = standLong && _rng.nextDouble() < 0.4
            ? 12 + _rng.nextDouble() * 20
            : 2 + _rng.nextDouble() * 6;
      }
      return;
    }
    double turn = math.atan2(dy, dx) - p.heading;
    while (turn > math.pi) {
      turn -= 2 * math.pi;
    }
    while (turn < -math.pi) {
      turn += 2 * math.pi;
    }
    final maxTurn = 3.5 * dt;
    p.heading += turn.clamp(-maxTurn, maxTurn).toDouble();
    double target = p.legSpeed * (0.3 + 0.7 * math.max(0, math.cos(turn)));
    if (last) target = math.min(target, 0.25 + d * 0.9);
    p.speed += (target - p.speed) * math.min(1, dt * 1.8);
    final nx = p.x + p.speed * math.cos(p.heading) * dt;
    final ny = p.y + p.speed * math.sin(p.heading) * dt;
    if (_clear(p.x, p.y, nx, ny)) {
      p.x = nx;
      p.y = ny;
    } else {
      // About to clip a wall (e.g. cutting the corner of a doorway): stop
      // and turn on the spot toward the waypoint instead.
      p.speed *= 0.3;
      p.heading = math.atan2(dy, dx);
    }
  }

  void _wander(SceneObject p, double v, double leash, double dt) {
    p.heading += (_rng.nextDouble() - 0.5) * 3.0 * dt;
    final dx = p.ax - p.x, dy = p.ay - p.y;
    if (dx * dx + dy * dy > leash * leash) p.heading = math.atan2(dy, dx);
    p.x += v * math.cos(p.heading) * dt;
    p.y += v * math.sin(p.heading) * dt;
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
          _seg.addAll(
              [w.x + ux * s, w.y + uy * s, w.x + ux * g[0], w.y + uy * g[0]]);
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
      final att =
          math.pow(Radar.wallLoss, _crossings(px, py, skipSeg)).toDouble();
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

  /// Adds a point return seen at (atX, atY) with total two-way path [r]
  /// (one-way equivalent range) and final amplitude [a].
  void _addDynamic(double atX, double atY, double r, double a) {
    if (r < 0.25 || r > frame.maxRange * 1.2) return;
    final bx = atX - scene.radarX, by = atY - scene.radarY;
    _dBearing.add(_wrapBearing(math.atan2(by, bx)));
    _dBin.add(r / frame.maxRange * frame.bins);
    _dAmp.add(a);
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
      final body = p.body;
      if (body == null) continue;
      final att =
          math.pow(Radar.wallLoss, _crossings(p.x, p.y, -1)).toDouble();
      final breath = breathingOffset(body, _time);
      _bx.clear();
      _by.clear();
      _ba.clear();
      emitScatterers(body, _time, p.x, p.y, p.heading, p.speed, p.gait,
          Radar.gain, _bx, _by, _ba);
      for (int i = 0; i < _bx.length; i++) {
        final dx = _bx[i] - rx, dy = _by[i] - ry;
        final r = math.sqrt(dx * dx + dy * dy) + breath;
        final rr = math.max(r, 0.5);
        _addDynamic(_bx[i], _by[i], r, _ba[i] * att / (rr * rr));
      }

      // Multipath: mirror the body's main return in each wall segment.
      final a0 = _ba.isEmpty ? 0.0 : _ba[0];
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
        final ll = math.max(l, 0.5);
        // Radar -> wall -> body -> wall -> radar: seen at the image.
        _addDynamic(mx, my, l + breath,
            a0 * att * _reflect * _reflect / (ll * ll));
        // Radar -> body -> wall -> radar: half-way range, body bearing.
        final h = (d + l) / 2;
        _addDynamic(p.x, p.y, h + breath,
            a0 * att * _reflect * 0.25 / math.max(h * h, 0.25));
      }
    }
  }

  void _snapshotDynamic() {
    final snap = [
      Float64List.fromList(_dBearing),
      Float64List.fromList(_dBin),
      Float64List.fromList(_dAmp),
      Float64List.fromList(_dPhi),
    ];
    const keep = Radar.mtiDelayChirps + 1;
    if (_snap.length < keep) {
      _snap.add(snap);
      _snapHead = _snap.length % keep;
    } else {
      _snap[_snapHead] = snap;
      _snapHead = (_snapHead + 1) % keep;
    }
  }

  /// Dynamic scatterers as they were [Radar.mtiDelayChirps] chirps ago (or
  /// the oldest available).
  List<Float64List>? get _delayed {
    if (_snap.isEmpty) return null;
    if (_snap.length < Radar.mtiDelayChirps + 1) return _snap.first;
    return _snap[_snapHead]; // oldest in a full ring
  }

  // ---- search: one chirp per beam ----

  void _tone(double bin, double phase, double a,
      [Float64List? reBuf, Float64List? imBuf]) {
    final w = 2 * math.pi * bin / _n;
    final wr = math.cos(w), wi = math.sin(w);
    double pr = a * math.cos(phase), pq = a * math.sin(phase);
    final re = reBuf ?? _re, im = imBuf ?? _im;
    for (int n = 0; n < _n; n++) {
      re[n] += pr;
      im[n] += pq;
      final t = pr * wr - pq * wi;
      pq = pr * wi + pq * wr;
      pr = t;
    }
  }

  double _gauss() {
    final u1 = _rng.nextDouble() + 1e-12, u2 = _rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
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
        final a = _sAmp[i] *
            math.exp(-d * d * _invTwoSigma2) *
            (1 + 0.01 * math.sin(0.5 * t + h));
        if (a < 1e-5) continue;
        _tone(_sBin[i], _sPhi[i] + 0.02 * math.sin(0.23 * t + 1.7 * h), a);
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

    final double sigma = Radar.noiseSigma(_noise);
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

    // Two-pulse MTI: the same beam a few chirps earlier, subtracted. Static
    // returns cancel exactly; anything that moved does not.
    final re2 = _re2, im2 = _im2;
    re2.fillRange(0, _n, 0);
    im2.fillRange(0, _n, 0);
    for (int i = 0; i < _dAmp.length; i++) {
      double d = _dBearing[i] - th;
      if (d > math.pi) d -= 2 * math.pi;
      if (d < -math.pi) d += 2 * math.pi;
      if (d.abs() > 4 * _beamSigma) continue;
      _tone(_dBin[i], _dPhi[i], _dAmp[i] * math.exp(-d * d * _invTwoSigma2),
          re2, im2);
    }
    final old = _delayed;
    if (old != null) {
      final ob = old[0], ok = old[1], oa = old[2], op = old[3];
      for (int i = 0; i < oa.length; i++) {
        double d = ob[i] - th;
        if (d > math.pi) d -= 2 * math.pi;
        if (d < -math.pi) d += 2 * math.pi;
        if (d.abs() > 4 * _beamSigma) continue;
        _tone(ok[i], op[i], -oa[i] * math.exp(-d * d * _invTwoSigma2),
            re2, im2);
      }
    }
    final ms = sigma * math.sqrt2; // difference of two noisy chirps
    for (int n = 0; n < _n; n++) {
      re2[n] = (re2[n] + ms * _gauss()) * hann[n];
      im2[n] = (im2[n] + ms * _gauss()) * hann[n];
    }
    _fft.transform(re2, im2);
    final mot = frame.motion;
    for (int k = 0; k < bins; k++) {
      final p = (re2[k] * re2[k] + im2[k] * im2[k]) * norm;
      double v = (4.342944819 * math.log(p + 1e-12) + 60) / 60;
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      mot[base + k] = v;
    }
  }

  // ---- track dwell: one chirp, two lobes, one range gate ----

  void _accGate(double bin, int k0, double a, double phase, double gL,
      double gR) {
    final tr = tracker;
    final c = a * math.cos(phase), s = a * math.sin(phase);
    const half = Radar.gate ~/ 2;
    for (int j = 0; j < Radar.gate; j++) {
      if (!HannResponse.at(bin - (k0 - half + j), _resp)) continue;
      final vr = c * _resp[0] - s * _resp[1];
      final vi = c * _resp[1] + s * _resp[0];
      tr.lr[j] += gL * vr;
      tr.li[j] += gL * vi;
      tr.rr[j] += gR * vr;
      tr.ri[j] += gR * vi;
    }
  }

  void _dwellChirp(Track track) {
    final tr = tracker;
    tr.lr.fillRange(0, Radar.gate, 0);
    tr.li.fillRange(0, Radar.gate, 0);
    tr.rr.fillRange(0, Radar.gate, 0);
    tr.ri.fillRange(0, Radar.gate, 0);
    if (track.beamIndex < 0) tr.pointBeam(track);
    final th = _wrapBearing(track.beamBearing);
    final k0 = tr.mToBin(track.range);
    const sq = Radar.squint;
    final lo = k0 - Radar.gate ~/ 2 - HannResponse.span;
    final hi = k0 + Radar.gate ~/ 2 + HannResponse.span;
    final t = _time;
    const limit = 4 * Radar.dwellSigma;
    const inv2 = 1 / (2 * Radar.dwellSigma * Radar.dwellSigma);

    void add(double d, double bin, double a, double phase) {
      if (bin < lo || bin > hi || d.abs() > limit + sq) return;
      final gL = math.exp(-(d + sq) * (d + sq) * inv2);
      final gR = math.exp(-(d - sq) * (d - sq) * inv2);
      _accGate(bin, k0, a, phase, gL, gR);
    }

    final deg = (th * 180 / math.pi).floor();
    const span = 28; // degrees: 4 sigma + squint
    for (int o = -span; o <= span; o++) {
      final bucket = _buckets[((deg + o) % 360 + 360) % 360];
      for (int q = 0; q < bucket.length; q++) {
        final i = bucket[q];
        final b = _sBin[i];
        if (b < lo || b > hi) continue;
        double d = _sBearing[i] - th;
        if (d > math.pi) d -= 2 * math.pi;
        if (d < -math.pi) d += 2 * math.pi;
        final h = _sHash[i];
        add(d, b, _sAmp[i] * (1 + 0.01 * math.sin(0.5 * t + h)),
            _sPhi[i] + 0.02 * math.sin(0.23 * t + 1.7 * h));
      }
    }
    for (int i = 0; i < _dAmp.length; i++) {
      double d = _dBearing[i] - th;
      if (d > math.pi) d -= 2 * math.pi;
      if (d < -math.pi) d += 2 * math.pi;
      add(d, _dBin[i], _dAmp[i], _dPhi[i]);
    }
    final sn = Radar.noisePerBin(_noise);
    for (int j = 0; j < Radar.gate; j++) {
      tr.lr[j] += sn * _gauss();
      tr.li[j] += sn * _gauss();
      tr.rr[j] += sn * _gauss();
      tr.ri[j] += sn * _gauss();
    }
    tr.onChirp(track, k0);
  }

  // ---- search-sweep detection feeding the tracker ----

  void _runDetector() {
    final dets = detector.detect(frame);
    final out = <Detection>[];
    for (final d in dets) {
      if (d.label == 'motion') {
        tracker.onSearchDetection(
            (d.minX + d.maxX) / 2, (d.minY + d.maxY) / 2);
        continue;
      }
      if (d.label == 'object') {
        // A static blob on top of a track is the tracked target itself.
        final cx = (d.minX + d.maxX) / 2, cy = (d.minY + d.maxY) / 2;
        bool nearTrack = false;
        for (final t in tracker.tracks) {
          final dx = t.x - cx, dy = t.y - cy;
          if (dx * dx + dy * dy < 0.8) nearTrack = true;
        }
        if (nearTrack) continue;
      }
      out.add(d);
    }
    structure = out;
  }

  /// Multipath ghost check: a track that sits at the mirror image of a
  /// nearer track across a detected wall is probably that target's
  /// reflection. Uses detected walls and tracks only.
  void _tagGhosts() {
    final ts = tracker.tracks;
    for (final t in ts) {
      t.ghostOf = null;
    }
    for (final b in ts) {
      for (final a in ts) {
        if (identical(a, b) || a.ghostOf != null || a.range >= b.range) continue;
        for (final w in structure) {
          if (w.label != 'wall') continue;
          final horizontal = (w.maxX - w.minX) >= (w.maxY - w.minY);
          double mx, my;
          if (horizontal) {
            final c = (w.minY + w.maxY) / 2;
            if (a.x < w.minX - 0.5 || a.x > w.maxX + 0.5) continue;
            mx = a.x;
            my = 2 * c - a.y;
          } else {
            final c = (w.minX + w.maxX) / 2;
            if (a.y < w.minY - 0.5 || a.y > w.maxY + 0.5) continue;
            mx = 2 * c - a.x;
            my = a.y;
          }
          final dx = mx - b.x, dy = my - b.y;
          if (dx * dx + dy * dy < 0.8 * 0.8) {
            b.ghostOf = a.id;
            break;
          }
        }
        if (b.ghostOf != null) break;
        // Radar -> target -> wall -> radar arrives on the target's bearing
        // but later: a weaker track just behind a stronger one on the same
        // bearing is that echo.
        double db = a.bearing - b.bearing;
        if (db > math.pi) db -= 2 * math.pi;
        if (db < -math.pi) db += 2 * math.pi;
        if (db.abs() < 5 * math.pi / 180 &&
            b.range - a.range > 0.4 &&
            b.range - a.range < 4 &&
            b.excess < 0.5 * a.excess) {
          b.ghostOf = a.id;
          break;
        }
      }
    }
  }

  @override
  void tick(double dt) {
    if (dt > 0.1) dt = 0.1;
    tracker.maxRange = frame.maxRange;
    tracker.wallsTo ??= detector.wallsBetween;
    if (_builtStaticRev != scene.staticRevision) {
      _rebuildStatic();
      tracker.clearClutter();
    }

    // Chirp-rate loop: animation and track dwells at 256 Hz.
    const step = 1 / Radar.prf;
    _chirpAcc += dt;
    while (_chirpAcc >= step) {
      _chirpAcc -= step;
      _time += step;
      if (playing) _animate(step);
      _rebuildDynamic();
      _snapshotDynamic();
      for (final t in tracker.tracks) {
        _dwellChirp(t);
      }
    }
    tracker.frame(dt);
    _tagGhosts();

    // Search sweep at frame end.
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

    _detectClock += dt;
    if (_detectClock >= 0.2) {
      _detectClock = 0;
      _runDetector();
    }
  }
}
