import 'dart:math' as math;

import '../dsp/track_processor.dart';

enum TargetClass { human, dog, cat, machine }

extension TargetClassX on TargetClass {
  String get label => switch (this) {
        TargetClass.human => 'HUMAN',
        TargetClass.dog => 'DOG',
        TargetClass.cat => 'CAT',
        TargetClass.machine => 'MACHINERY',
      };
  String get detail => switch (this) {
        TargetClass.human => 'adult-sized biped',
        TargetClass.dog => 'medium quadruped',
        TargetClass.cat => 'small quadruped',
        TargetClass.machine => 'rotating machinery',
      };
}

class _G {
  const _G(this.mean, this.sd);
  final double mean, sd;
  double logPdf(double x) {
    final z = (x - mean) / sd;
    return -0.5 * math.min(z * z, 16) - math.log(sd);
  }
}

/// Bayesian classifier over physical signature features, with evidence
/// accumulated over the life of a track.
///
/// Per-class feature distributions were fitted by
/// tools/classifier_proto/nb.py on 220 labelled synthetic tracks (randomised
/// individuals, 0-2 walls, 2.5-8 m) and checked on a separate 165-track test
/// set. Standard deviations have floors so no single feature dominates.
/// On real hardware these tables must be refitted from recorded data.
///
/// Features: RCS (dBsm), log micro-Doppler span, spread symmetry, log
/// cadence (only with a clear periodicity), breathing rate (only when the
/// target has been still for 10 s and the breathing line stands out).
class TargetClassifier {
  static const _moving = <TargetClass, Map<String, _G>>{
    TargetClass.human: {
      'rcs': _G(1.46, 4.79),
      'span': _G(1.47, 0.49),
      'sym': _G(0.25, 0.15),
      'cad': _G(0.71, 0.2),
    },
    TargetClass.dog: {
      'rcs': _G(-5.82, 3.54),
      'span': _G(1.58, 0.64),
      'sym': _G(0.30, 0.20),
      'cad': _G(1.17, 0.21),
    },
    TargetClass.cat: {
      'rcs': _G(-10.98, 3.66),
      'span': _G(0.79, 0.66),
      'sym': _G(0.15, 0.15),
      'cad': _G(0.89, 0.2),
    },
  };

  static const _still = <TargetClass, Map<String, _G>>{
    TargetClass.human: {
      'rcs': _G(1.44, 3.38),
      'span': _G(-0.43, 0.32),
      'sym': _G(1.0, 0.15),
      'cad': _G(0.49, 0.40),
      'bpm': _G(16, 4.5),
    },
    TargetClass.dog: {
      'rcs': _G(-5.16, 3.83),
      'span': _G(-0.40, 0.32),
      'sym': _G(1.0, 0.15),
      'cad': _G(0.66, 0.29),
      'bpm': _G(26, 6),
    },
    TargetClass.cat: {
      'rcs': _G(-10.59, 3.43),
      'span': _G(-0.69, 0.3),
      'sym': _G(0.86, 0.35),
      'cad': _G(0.59, 0.40),
      'bpm': _G(28, 6.5),
    },
    TargetClass.machine: {
      'rcs': _G(-10.12, 3.78),
      'span': _G(2.41, 0.66),
      'sym': _G(0.92, 0.22),
      'cad': _G(1.72, 0.56),
      'bpm': _G(20, 15),
    },
  };

  /// Accumulated log evidence per class.
  final Map<TargetClass, double> evidence = {
    for (final c in TargetClass.values) c: 0.0
  };
  int updates = 0;

  /// RCS measured while the target was moving (MTI hides a still target's
  /// body, so a still track keeps its moving estimate).
  double rcsMoving = double.nan;
  int _rcsN = 0;

  /// Forgetting factor per 1 s update (about 20 s memory) and evidence
  /// weight per update (windows overlap heavily, so each counts little).
  static const double _lambda = 0.95;
  static const double _weight = 0.1;

  /// Last feature vector used, for display.
  Map<String, double> lastFeatures = const {};

  void update(SignatureFeatures f, {required bool moving}) {
    if (!f.detected) return;
    if (moving && f.rcsDbsm.isFinite) {
      _rcsN++;
      final a = 1 / math.min(_rcsN, 10);
      rcsMoving =
          rcsMoving.isNaN ? f.rcsDbsm : rcsMoving + a * (f.rcsDbsm - rcsMoving);
    }
    // A still body is mostly removed by MTI, so its instantaneous RCS reads
    // low. Use the RCS measured while it moved; failing that, trust the
    // instantaneous value only for strongly spinning targets (machinery).
    final double? rcs = rcsMoving.isFinite
        ? rcsMoving
        : (moving || f.span > 2.0 ? f.rcsDbsm : null);
    // A still body shows little beyond its size (remembered from when it
    // moved) and its breathing; its span, symmetry and "rhythm" are noise
    // and would slowly drag the decision around during a long rest. Only a
    // clearly spinning target (machinery) keeps the full feature set.
    final spinning = f.span > 1.5;
    final full = moving || spinning;
    final x = <String, double>{
      if (rcs != null && rcs.isFinite) 'rcs': rcs,
      if (full) 'span': math.log(math.max(f.span, 0.25)),
      if (full) 'sym': f.symmetry,
      if (full && f.cadenceSnr > 4) 'cad': math.log(math.max(f.cadence, 0.5)),
      if (!moving && f.breathBpm.isFinite && f.breathSnr > 4)
        'bpm': f.breathBpm,
    };
    if (x.isEmpty) return;
    lastFeatures = x;
    final table = moving ? _moving : _still;
    final lp = <TargetClass, double>{};
    for (final c in TargetClass.values) {
      final m = table[c];
      if (m == null) continue;
      double s = 0;
      for (final e in x.entries) {
        final gd = m[e.key];
        if (gd != null) s += gd.logPdf(e.value);
      }
      lp[c] = s;
    }
    // Machinery does not walk, and a still target that is not spinning is
    // not machinery: it gets the worst score of the others minus a margin.
    if (!lp.containsKey(TargetClass.machine) || !spinning) {
      lp.remove(TargetClass.machine);
      lp[TargetClass.machine] = lp.values.reduce(math.min) - 8;
    }
    // Normalise to log-posterior for this window before fusing.
    final mx = lp.values.reduce(math.max);
    double z = 0;
    for (final v in lp.values) {
      z += math.exp(v - mx);
    }
    for (final c in TargetClass.values) {
      final l = lp[c]! - mx - math.log(z);
      // A still look carries less information than a moving one.
      evidence[c] = _lambda * evidence[c]! + (full ? _weight : 0.4 * _weight) * l;
    }
    updates++;
  }

  /// Posterior probabilities from the accumulated evidence.
  Map<TargetClass, double> get posterior {
    final mx = evidence.values.reduce(math.max);
    double z = 0;
    for (final v in evidence.values) {
      z += math.exp(v - mx);
    }
    return {
      for (final e in evidence.entries) e.key: math.exp(e.value - mx) / z
    };
  }

  /// Best class, or null until there is enough evidence.
  TargetClass? get best {
    if (updates < 3) return null;
    final p = posterior;
    TargetClass bc = TargetClass.human;
    double bv = -1;
    p.forEach((c, v) {
      if (v > bv) {
        bv = v;
        bc = c;
      }
    });
    return bv >= 0.5 ? bc : null;
  }

  double get confidence {
    final b = best;
    return b == null ? 0 : posterior[b]!;
  }
}
