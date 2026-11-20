import 'dart:math' as math;
import 'dart:typed_data';

import 'package:darksight/core/csi_radar_source.dart';
import 'package:flutter_test/flutter_test.dart';

// Test inputs only: synthetic CSI-like vectors, to check the decision logic.
// The app itself never generates data.
Float64List frame(math.Random r, double t, {bool moving = false}) {
  final v = Float64List(52);
  for (int k = 0; k < 52; k++) {
    final base = 1 + 0.3 * math.sin(k * 0.4);
    double x = base * (1 + 0.01 * (r.nextDouble() - 0.5));
    if (moving) x *= 1 + 0.15 * math.sin(2 * math.pi * 1.3 * t + k * 0.7);
    v[k] = x;
  }
  final mean = v.reduce((a, b) => a + b) / v.length;
  return Float64List.fromList(v.map((x) => x / mean).toList());
}

void main() {
  test('calibrates on an empty room, then flags motion and clears it', () {
    final a = WifiMotionAnalyzer(
        window: 1.0, relative: true, floor: 0.002, minAbove: 0.4, staleAfter: 3);
    final r = math.Random(1);
    double t = 0;
    a.recalibrate();
    for (; t < 25; t += 0.02) {
      a.add(t, frame(r, t));
    }
    expect(a.threshold, isNotNull);
    expect(a.stateAt(t), WifiState.still);
    // Quiet room for a minute: no false alarms.
    for (; t < 85; t += 0.02) {
      a.add(t, frame(r, t));
      expect(a.stateAt(t), isNot(WifiState.motion));
    }
    // Someone walks through.
    for (; t < 95; t += 0.02) {
      a.add(t, frame(r, t, moving: true));
    }
    expect(a.stateAt(t), WifiState.motion);
    // They leave.
    for (; t < 105; t += 0.02) {
      a.add(t, frame(r, t));
    }
    expect(a.stateAt(t), WifiState.still);
    expect(t - a.lastMotion, lessThan(12));
  });

  test('motion during calibration makes it less sensitive, not trigger-happy',
      () {
    final a = WifiMotionAnalyzer(
        window: 1.0, relative: true, floor: 0.002, minAbove: 0.4, staleAfter: 3);
    final r = math.Random(2);
    double t = 0;
    a.recalibrate();
    for (; t < 25; t += 0.02) {
      a.add(t, frame(r, t, moving: true));
    }
    for (; t < 85; t += 0.02) {
      a.add(t, frame(r, t));
      expect(a.stateAt(t), isNot(WifiState.motion));
    }
  });

  test('data stopping means no signal; recalibrating with no data waits', () {
    final a = WifiMotionAnalyzer(
        window: 1.0, relative: true, floor: 0.002, minAbove: 0.4, staleAfter: 3);
    final r = math.Random(3);
    expect(a.stateAt(0), WifiState.noSignal);
    double t = 0;
    for (; t < 25; t += 0.02) {
      a.add(t, frame(r, t));
    }
    expect(a.stateAt(t), WifiState.still);
    expect(a.stateAt(t + 10), WifiState.noSignal);
    // Recalibrate while nothing is arriving: the 20 s start with new data.
    a.recalibrate();
    expect(a.threshold, isNull);
    t += 100;
    a.add(t, frame(r, t));
    expect(a.calibrationLeftAt(t), greaterThan(19));
    for (double end = t + 5; t < end; t += 0.02) {
      a.add(t, frame(r, t));
    }
    expect(a.stateAt(t), WifiState.calibrating);
  });
}
