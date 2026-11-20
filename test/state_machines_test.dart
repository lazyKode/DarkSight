import 'package:darksight/core/tracker.dart';
import 'package:darksight/ml/target_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

TrackStatus? step(TrackStatus s,
        {double age = 5,
        double silent = 0,
        double streak = 0,
        bool inRange = true}) =>
    TrackLifecycle.next(s,
        age: age,
        sinceEvidence: silent,
        evidenceStreak: streak,
        inRange: inRange);

void main() {
  test('track lifecycle transitions', () {
    const t = TrackStatus.tentative,
        c = TrackStatus.confirmed,
        k = TrackStatus.coasting;
    // tentative
    expect(step(t, age: 0.5, streak: 0.5), t); // too young
    expect(step(t, age: 2, streak: 0.3), t); // streak too short
    expect(step(t, age: 2, streak: 0.7), c);
    expect(step(t, age: 5, silent: 2), isNull); // never firmed up
    expect(step(t, age: 5, silent: 0.5), t);
    // confirmed
    expect(step(c, silent: 1.0), c);
    expect(step(c, silent: 1.6), k);
    // coasting
    expect(step(k, silent: 5), k);
    expect(step(k, silent: 0), c);
    expect(step(k, silent: 10.5), isNull);
    // out of range deletes from any state
    for (final s in TrackStatus.values) {
      expect(step(s, inRange: false), isNull);
    }
  });

  test('motion phase has hysteresis', () {
    var p = MotionPhase.unsure;
    p = p.next(0.2);
    expect(p, MotionPhase.unsure); // between thresholds, nothing known yet
    p = p.next(0.3);
    expect(p, MotionPhase.moving);
    p = p.next(0.2);
    expect(p, MotionPhase.moving); // does not flicker in the gap
    p = p.next(0.1);
    expect(p, MotionPhase.still);
    p = p.next(0.2);
    expect(p, MotionPhase.still);
    p = p.next(0.26);
    expect(p, MotionPhase.moving);
  });

  test('classifier starts out collecting and has no class', () {
    final c = TargetClassifier();
    expect(c.verdict, Verdict.collecting);
    expect(c.best, isNull);
    expect(c.confidence, 0);
  });
}
