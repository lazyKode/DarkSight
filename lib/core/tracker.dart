import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/radar_constants.dart';
import '../dsp/track_processor.dart';
import '../ml/target_classifier.dart';

enum TrackStatus { tentative, confirmed, coasting }

/// One tracked target. Positions are metres relative to the radar
/// (x right, y down on screen).
class Track {
  Track(this.id, this.x, this.y, double noise)
      : processor = TrackProcessor(noise);

  final int id;
  double x, y;
  double vx = 0, vy = 0;
  TrackStatus status = TrackStatus.tentative;
  double age = 0;
  double sinceEvidence = 0; // s since the dwell last saw energy
  double confirmTime = 0;
  double stillTime = 0; // s with speed below the still threshold
  double radialVelocity = 0;
  double excess = 0;
  int walls = 0; // detected walls between radar and target

  /// Smoothed ground speed.
  double speed = 0;

  final TrackProcessor processor;
  final TargetClassifier classifier = TargetClassifier();
  SignatureFeatures features = SignatureFeatures();

  // Dwell geometry for the current chirp.
  double get range => math.sqrt(x * x + y * y);
  double get bearing => math.atan2(y, x);
  double get heading => math.atan2(vy, vx);

  // Trail: positions over the last ~8 s (every 0.25 s).
  final List<double> trail = [];
  double _trailT = 0;

  bool get moving => speed > 0.25;
  bool get still => speed < 0.15;
}

/// Track management: initiation from search-sweep motion detections,
/// per-chirp dwell scheduling, alpha-beta filtering of dwell measurements,
/// classification updates, and deletion.
class Tracker {
  Tracker();

  final List<Track> tracks = [];
  int _nextId = 1;
  int get created => _nextId - 1;
  double noise = 0.25;

  /// Range window in metres (maps range bins to metres).
  double maxRange = 10;

  /// Walls-crossed lookup provided by the search processing (detected
  /// structure only). Returns 0 if unknown.
  int Function(double x, double y)? wallsTo;

  static const double _gateInit = 1.4; // m, search association gate
  static const double _alpha = 0.3, _beta = 0.04;

  double _featureClock = 0;

  /// Channel buffers reused for every chirp.
  final Float64List lr = Float64List(Radar.gate),
      li = Float64List(Radar.gate),
      rr = Float64List(Radar.gate),
      ri = Float64List(Radar.gate);

  double binToM(double b) => b / Radar.bins * maxRange;
  int mToBin(double r) => (r / maxRange * Radar.bins).round();

  /// Search sweep found motion at (x, y): start a track unless one is near.
  void onSearchDetection(double x, double y) {
    for (final t in tracks) {
      final dx = t.x - x, dy = t.y - y;
      if (dx * dx + dy * dy < _gateInit * _gateInit) {
        // Weak position update helps the angle when the dwell has drifted.
        if (t.sinceEvidence > 0.5) {
          t.x += 0.5 * (x - t.x);
          t.y += 0.5 * (y - t.y);
          t.processor.resetClutter();
        }
        return;
      }
    }
    if (tracks.length >= 6) return;
    final r = math.sqrt(x * x + y * y);
    if (r < 0.6 || r > maxRange * 0.97) return;
    tracks.add(Track(_nextId++, x, y, noise));
  }

  /// Called by the radar after each dwell chirp for [t], with the channel
  /// buffers filled.
  void onChirp(Track t, int k0) {
    final m = t.processor.push(k0, t.bearing, lr, li, rr, ri);
    if (m != null) _measure(t, m, Radar.hop / Radar.prf);
  }

  void _measure(Track t, DwellMeasurement m, double dt) {
    // Predict.
    t.x += t.vx * dt;
    t.y += t.vy * dt;
    t.excess = m.excess;
    if (m.excess > 0.35) {
      t.sinceEvidence = 0;
      final r = binToM(m.range);
      final th = t.bearing + m.angleOffset;
      final mx = r * math.cos(th), my = r * math.sin(th);
      final ex = mx - t.x, ey = my - t.y;
      final e = math.sqrt(ex * ex + ey * ey);
      if (e < 1.0) {
        t.x += _alpha * ex;
        t.y += _alpha * ey;
        t.vx += _beta / dt * ex;
        t.vy += _beta / dt * ey;
      }
      t.radialVelocity = m.radialVelocity;
    } else {
      t.sinceEvidence += dt;
      // Coasting: bleed velocity.
      t.vx *= 0.97;
      t.vy *= 0.97;
    }
    final v = math.sqrt(t.vx * t.vx + t.vy * t.vy);
    if (v > 2.5) {
      t.vx *= 2.5 / v;
      t.vy *= 2.5 / v;
    }
    t.speed += 0.08 * (math.min(v, 2.5) - t.speed);
  }

  /// Housekeeping once per display frame.
  void frame(double dt) {
    _featureClock += dt;
    final doFeatures = _featureClock >= 1.0;
    if (doFeatures) _featureClock = 0;
    for (final t in tracks) {
      t.age += dt;
      t.stillTime = t.still ? t.stillTime + dt : 0;
      t._trailT += dt;
      if (t._trailT >= 0.25) {
        t._trailT = 0;
        t.trail
          ..add(t.x)
          ..add(t.y);
        if (t.trail.length > 64) t.trail.removeRange(0, 2);
      }
      if (t.status == TrackStatus.tentative) {
        if (t.sinceEvidence == 0 && t.age > 1.0) {
          t.confirmTime += dt;
          if (t.confirmTime > 0.6) t.status = TrackStatus.confirmed;
        }
      } else {
        t.status = t.sinceEvidence > 1.5
            ? TrackStatus.coasting
            : TrackStatus.confirmed;
      }
      if (doFeatures && t.status != TrackStatus.tentative) {
        t.walls = wallsTo?.call(t.x, t.y) ?? 0;
        t.features = t.processor.features(
          rangeM: math.max(t.range, 0.5),
          maxRange: maxRange,
          walls: t.walls,
          still: t.still,
          stillSeconds: t.stillTime,
        );
        if (!t.moving && !t.still) {
          // In between: not a clean look either way.
        } else {
          t.classifier.update(t.features, moving: t.moving);
        }
      }
    }
    tracks.removeWhere((t) =>
        (t.status == TrackStatus.tentative && t.age > 4 && t.sinceEvidence > 1) ||
        t.sinceEvidence > 10 ||
        t.range > maxRange);
    // Merge duplicates: keep the older track.
    for (int i = 0; i < tracks.length; i++) {
      for (int j = tracks.length - 1; j > i; j--) {
        final a = tracks[i], b = tracks[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        if (dx * dx + dy * dy < 0.36) tracks.removeAt(j);
      }
    }
  }

  void clear() => tracks.clear();
}
