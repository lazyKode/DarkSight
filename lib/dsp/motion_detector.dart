import 'dart:math' as math;

enum MotionState { still, motion }

enum MotionTrend { none, approaching, receding }

/// Presence/motion detector for a stream of channel measurements.
///
/// Works on a vector per sample: one element for RSSI, one per subcarrier
/// amplitude once raw CSI is available. Steps (spec section "Tier 2"):
///   1. per-element static channel removal (long moving average)
///   2. residual -> short-time energy
///   3. adaptive threshold with hysteresis and hold-off
///   4. crude approach/recede trend from the slope of the mean level
///      (with CSI this becomes a Doppler estimate from the phase derivative)
class MotionDetector {
  MotionDetector({this.longTau = 8, this.shortTau = 0.8, this.hold = 1.5});

  final double longTau; // s, static channel estimate
  final double shortTau; // s, energy integration
  final double hold; // s, minimum time in "motion" after last trigger

  List<double>? _static;
  double _energy = 0;
  double _floor = 0.05;
  double _fast = 0, _slow = 0;
  double _sinceTrigger = 1e9;
  bool _primed = false;

  MotionState state = MotionState.still;
  MotionTrend trend = MotionTrend.none;

  /// Short-time residual energy (units of the input squared).
  double get energy => _energy;

  /// Current switch-on threshold.
  double get threshold => math.max(0.6, _floor * 6);

  void reset() {
    _static = null;
    _primed = false;
    _energy = 0;
    state = MotionState.still;
    trend = MotionTrend.none;
  }

  void update(List<double> x, double dt) {
    var st = _static;
    double mean = 0;
    for (final v in x) {
      mean += v;
    }
    mean /= x.length;
    if (st == null || st.length != x.length || !_primed) {
      _static = st = List<double>.from(x);
      _fast = _slow = mean;
      _primed = true;
      return;
    }
    final aLong = 1 - math.exp(-dt / longTau);
    final aShort = 1 - math.exp(-dt / shortTau);
    double e = 0;
    for (int i = 0; i < x.length; i++) {
      final r = x[i] - st[i];
      e += r * r;
      st[i] += aLong * r;
    }
    e /= x.length;
    _energy += aShort * (e - _energy);

    // Noise floor tracks the energy only while still.
    if (state == MotionState.still) {
      _floor += (1 - math.exp(-dt / 20)) * (_energy - _floor);
      if (_floor < 0.02) _floor = 0.02;
    }

    _sinceTrigger += dt;
    final on = threshold, off = on * 0.5;
    if (_energy > on) {
      state = MotionState.motion;
      _sinceTrigger = 0;
    } else if (state == MotionState.motion &&
        _energy < off &&
        _sinceTrigger > hold) {
      state = MotionState.still;
    }

    _fast += (1 - math.exp(-dt / 0.7)) * (mean - _fast);
    _slow += (1 - math.exp(-dt / 3.0)) * (mean - _slow);
    final slope = _fast - _slow;
    if (state == MotionState.still || slope.abs() < 0.8) {
      trend = MotionTrend.none;
    } else {
      trend = slope > 0 ? MotionTrend.approaching : MotionTrend.receding;
    }
  }
}
