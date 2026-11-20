import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/radar_constants.dart';
import '../dsp/track_processor.dart';
import '../ml/target_classifier.dart';

/// Track lifecycle. Every transition is in [TrackLifecycle.next].
///
///   tentative --(evidence for 0.6 s in a row, age > 1 s)--> confirmed
///   tentative --(age > 4 s and no evidence for 1 s)-------> deleted
///   confirmed --(no evidence for 1.5 s)--------------------> coasting
///   coasting  --(evidence again)---------------------------> confirmed
///   coasting  --(no evidence for 10 s)---------------------> deleted
///   any       --(outside the range window)----------------> deleted
enum TrackStatus { tentative, confirmed, coasting }

class TrackLifecycle {
  static const double confirmAfter = 0.6; // s of continuous evidence
  static const double minAgeToConfirm = 1.0;
  static const double dropTentativeAge = 4.0;
  static const double dropTentativeSilence = 1.0;
  static const double coastAfter = 1.5;
  static const double dropAfter = 10.0;

  /// Next status, or null when the track should be deleted.
  static TrackStatus? next(TrackStatus s,
      {required double age,
      required double sinceEvidence,
      required double evidenceStreak,
      required bool inRange}) {
    if (!inRange) return null;
    switch (s) {
      case TrackStatus.tentative:
        if (evidenceStreak >= confirmAfter && age > minAgeToConfirm) {
          return TrackStatus.confirmed;
        }
        if (age > dropTentativeAge && sinceEvidence > dropTentativeSilence) {
          return null;
        }
        return TrackStatus.tentative;
      case TrackStatus.confirmed:
        return sinceEvidence > coastAfter
            ? TrackStatus.coasting
            : TrackStatus.confirmed;
      case TrackStatus.coasting:
        if (sinceEvidence > dropAfter) return null;
        return sinceEvidence == 0 ? TrackStatus.confirmed : TrackStatus.coasting;
    }
  }
}

/// Whether a track is walking, standing, or in between, with hysteresis so
/// a target hovering around one speed does not flicker between phases.
///
///   still  --(speed > 0.25 m/s)--> moving
///   moving --(speed < 0.15 m/s)--> still
///   unsure --(either threshold)--> moving / still
enum MotionPhase {
  unsure,
  still,
  moving;

  static const double moveAbove = 0.25, stillBelow = 0.15;

  MotionPhase next(double speed) => switch (this) {
        MotionPhase.moving => speed < stillBelow ? MotionPhase.still : this,
        MotionPhase.still => speed > moveAbove ? MotionPhase.moving : this,
        MotionPhase.unsure => speed > moveAbove
            ? MotionPhase.moving
            : (speed < stillBelow ? MotionPhase.still : this),
      };
}

/// One tracked target. Positions are metres relative to the radar
/// (x right, y down on screen).
class Track {
  Track(this.id, this.x, this.y, double noise)
      : processor = TrackProcessor(noise);

  /// Where the dwell beam points: a fixed grid position, held steady (static
  /// clutter must look the same chirp to chirp for MTI to cancel it) and
  /// moved only when the target drifts past half a grid step.
  double beamBearing = 0;
  int? beamIndex; // null until pointed (and after clutter is forgotten)

  final int id;
  double x, y;
  double vx = 0, vy = 0;
  TrackStatus status = TrackStatus.tentative;
  double age = 0;
  double sinceEvidence = 0; // s since the dwell last saw energy
  double evidenceStreak = 0; // s of evidence without a gap
  double radialVelocity = 0;
  double excess = 0;
  int walls = 0; // detected walls between radar and target

  /// Set when this track looks like a wall reflection of track [ghostOf].
  int? ghostOf;

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

  /// Walking or standing (see [MotionPhase]) and for how long, so a
  /// signature window never mixes the two.
  MotionPhase phase = MotionPhase.unsure;
  double phaseTime = 0;

  bool get moving => phase == MotionPhase.moving;
  bool get still => phase == MotionPhase.still;
  double get stillTime => still ? phaseTime : 0;

  bool _dead = false;
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
          _point(t);
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
    if (t.beamIndex == null) _point(t);
    final m = t.processor.push(k0, lr, li, rr, ri);
    if (m != null) _measure(t, m, Radar.hop / Radar.prf);
  }

  void _measure(Track t, DwellMeasurement m, double dt) {
    // Predict.
    t.x += t.vx * dt;
    t.y += t.vy * dt;
    t.excess = m.excess;
    if (m.excess > 0.35) {
      t.sinceEvidence = 0;
      t.evidenceStreak += dt;
      final r = binToM(m.range);
      final th = t.beamBearing + m.angleOffset;
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
      t.evidenceStreak = 0;
      // No evidence: bleed velocity.
      t.vx *= 0.97;
      t.vy *= 0.97;
    }
    final v = math.sqrt(t.vx * t.vx + t.vy * t.vy);
    if (v > 2.5) {
      t.vx *= 2.5 / v;
      t.vy *= 2.5 / v;
    }
    t.speed += 0.08 * (math.min(v, 2.5) - t.speed);
    double off = t.bearing - t.beamBearing;
    if (off > math.pi) off -= 2 * math.pi;
    if (off < -math.pi) off += 2 * math.pi;
    if (off.abs() > 0.6 * Radar.beamGrid) _point(t);
  }

  /// Clutter maps per beam position, shared by all tracks and kept.
  final Map<int, ClutterMap> _clutter = {};

  void pointBeam(Track t) => _point(t);

  void _point(Track t) {
    const n = 2 * math.pi / Radar.beamGrid;
    final idx = ((t.bearing / Radar.beamGrid).round() % n.round() + n.round()) %
        n.round();
    t.beamIndex = idx;
    t.beamBearing = idx * Radar.beamGrid;
    t.processor.useClutterMap(_clutter.putIfAbsent(idx, ClutterMap.new));
  }

  /// Housekeeping once per display frame.
  void frame(double dt) {
    _featureClock += dt;
    final doFeatures = _featureClock >= 1.0;
    if (doFeatures) _featureClock = 0;
    for (final t in tracks) {
      t.age += dt;
      t._trailT += dt;
      if (t._trailT >= 0.25) {
        t._trailT = 0;
        t.trail
          ..add(t.x)
          ..add(t.y);
        if (t.trail.length > 64) t.trail.removeRange(0, 2);
      }
      final next = TrackLifecycle.next(t.status,
          age: t.age,
          sinceEvidence: t.sinceEvidence,
          evidenceStreak: t.evidenceStreak,
          inRange: t.range <= maxRange);
      if (next == null) {
        t._dead = true;
        continue;
      }
      t.status = next;
      final phase = t.phase.next(t.speed);
      if (phase != t.phase) {
        t.phase = phase;
        t.phaseTime = 0;
      } else {
        t.phaseTime += dt;
      }
      if (doFeatures && t.status != TrackStatus.tentative) {
        t.walls = wallsTo?.call(t.x, t.y) ?? 0;
        // Look only at the time since the target last started or stopped.
        final window = math.min(8.5, t.phaseTime);
        if (t.phase != MotionPhase.unsure && window >= 3.2) {
          t.features = t.processor.features(
            rangeM: math.max(t.range, 0.5),
            maxRange: maxRange,
            walls: t.walls,
            seconds: window,
            still: t.still,
            stillSeconds: t.stillTime,
          );
          t.classifier.update(t.features, moving: t.moving);
        }
      }
    }
    tracks.removeWhere((t) => t._dead);
    // Merge duplicates: keep the older track.
    for (int i = 0; i < tracks.length; i++) {
      for (int j = tracks.length - 1; j > i; j--) {
        final a = tracks[i], b = tracks[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        if (dx * dx + dy * dy < 0.36) tracks.removeAt(j);
      }
    }
  }

  /// Forget learned clutter (the room or the radar moved).
  void clearClutter() {
    _clutter.clear();
    for (final t in tracks) {
      t.beamIndex = null;
    }
  }

  void clear() {
    tracks.clear();
    _clutter.clear();
  }
}
