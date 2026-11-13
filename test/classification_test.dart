import 'dart:io';
import 'dart:math' as math;

import 'package:darksight/core/scene.dart';
import 'package:darksight/core/sim_radar_source.dart';
import 'package:darksight/core/tracker.dart';
import 'package:darksight/ml/target_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs the full simulated radar on a scene with one body and returns the
/// track nearest the body at the end, plus the body.
({Track? track, SceneObject body, SimRadarSource radar}) runScenario(
    ObjKind kind, double x, double y,
    {double seconds = 40,
    double stopAfter = double.infinity,
    int trajectory = 2,
    bool natural = false,
    void Function(double t, SimRadarSource r, SceneObject b)? onSecond}) {
  final scene = SceneController();
  scene.objects.removeWhere((o) => o.kind.isBody);
  final body = scene.addObject(kind);
  body
    ..x = x
    ..y = y
    ..ax = x
    ..ay = y
    ..behaviourTimer = natural ? 0 : 1e9
    ..stayNear = !natural
    ..resting = false;
  scene.touch();
  final radar = SimRadarSource(scene)
    ..sweepRate = 1.0
    ..personSpeed = 1.0
    ..trajectory = trajectory;
  const dt = 1 / 30;
  double nextReport = 1;
  for (double t = 0; t < seconds; t += dt) {
    if (onSecond != null && t >= nextReport) {
      nextReport += 5;
      onSecond(t, radar, body);
    }
    if (t > stopAfter) {
      radar.personSpeed = 0;
      body.resting = true;
    }
    radar.tick(dt);
  }
  Track? best;
  double bd = 1e9;
  for (final t in radar.tracker.tracks) {
    if (t.ghostOf != null) continue;
    final dx = t.x - (body.x - scene.radarX), dy = t.y - (body.y - scene.radarY);
    final d = math.sqrt(dx * dx + dy * dy);
    if (d < bd) {
      bd = d;
      best = t;
    }
  }
  final list = radar.tracker.tracks
      .map((t) => 'T${t.id}(${t.x.toStringAsFixed(1)},${t.y.toStringAsFixed(1)} '
          '${t.status.name} ex=${t.excess.toStringAsFixed(1)}'
          '${t.ghostOf != null ? ' ghost' : ''})')
      .join(' ');
  // ignore: avoid_print
  print('  ${kind.name} truth (${(body.x - scene.radarX).toStringAsFixed(1)}, '
      '${(body.y - scene.radarY).toStringAsFixed(1)}) tracks created '
      '${radar.tracker.created}: $list');
  return (track: bd < 1.2 ? best : null, body: body, radar: radar);
}

String describe(Track? t) {
  if (t == null) return 'no track';
  final f = t.features;
  final p = t.classifier.posterior.map((k, v) => MapEntry(k.label, (v * 100).round()));
  return 'T${t.id} ${t.status.name} speed=${t.speed.toStringAsFixed(2)} '
      'walls=${t.walls} detected=${f.detected} span=${f.span.toStringAsFixed(2)} '
      'sym=${f.symmetry.toStringAsFixed(2)} cad=${f.cadence.toStringAsFixed(2)}'
      '/${f.cadenceSnr.toStringAsFixed(1)} rcs=${f.rcsDbsm.toStringAsFixed(1)} '
      'rcsMov=${t.classifier.rcsMoving.toStringAsFixed(1)} '
      'bpm=${f.breathBpm.toStringAsFixed(1)}/${f.breathSnr.toStringAsFixed(1)} '
      'post=$p';
}

void main() {
  test('track and processing code never reads the simulated scene', () {
    for (final f in [
      'lib/dsp/track_processor.dart',
      'lib/core/tracker.dart',
      'lib/ml/target_classifier.dart',
      'lib/ml/detector.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src.contains('scene.dart'), isFalse, reason: f);
      expect(src.contains('bodies.dart'), isFalse, reason: f);
    }
  });

  // Radar at (5, 9.5). Walls: x = 8 (door at y 9.5), y = 6 for x < 8
  // (door at x 4), outer box 1.5..12.5.
  final cases = <(ObjKind, TargetClass, double, double)>[
    (ObjKind.person, TargetClass.human, 10.3, 5.2), // next room, 1 wall
    (ObjKind.person, TargetClass.human, 3.2, 7.0), // same room
    (ObjKind.dog, TargetClass.dog, 10.2, 9.6), // through the door
    (ObjKind.dog, TargetClass.dog, 3.2, 3.8), // behind a wall
    (ObjKind.cat, TargetClass.cat, 6.6, 7.6), // same room
    (ObjKind.cat, TargetClass.cat, 3.2, 4.6), // behind a wall
    (ObjKind.fan, TargetClass.machine, 6.9, 7.2), // same room
    (ObjKind.fan, TargetClass.machine, 9.6, 10.8), // behind a wall
  ];

  int correct = 0;
  final lines = <String>[];
  for (final c in cases) {
    test('classify ${c.$1.name} at (${c.$3}, ${c.$4})', () {
      final r = runScenario(c.$1, c.$3, c.$4);
      final got = r.track?.classifier.best;
      final line = '${c.$1.name.padRight(7)} expect ${c.$2.label.padRight(9)} '
          'got ${got?.label ?? '-'}   ${describe(r.track)}';
      lines.add(line);
      // ignore: avoid_print
      print(line);
      if (got == c.$2) correct++;
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('a person who stops is still tracked and breathing is measured', () {
    final r = runScenario(ObjKind.person, 3.2, 7.0,
        seconds: 60, stopAfter: 20, trajectory: 2);
    // ignore: avoid_print
    print('stopped person: ${describe(r.track)}  '
        'true bpm ${(r.body.body!.breathHz * 60).toStringAsFixed(1)}');
    expect(r.track, isNotNull);
    expect(r.track!.features.breathBpm.isFinite, isTrue);
    expect((r.track!.features.breathBpm - r.body.body!.breathHz * 60).abs(),
        lessThan(5));
  }, timeout: const Timeout(Duration(minutes: 3)));

  for (final k in [ObjKind.dog, ObjKind.cat]) {
    test('${k.name} with natural walk / rest bouts', () {
      final r = runScenario(k, 10.2, 9.6, seconds: 90, natural: true,
          onSecond: (t, radar, b) {
        final ts = radar.tracker.tracks
            .map((tr) => 'T${tr.id}(${tr.status.name} '
                'sp=${tr.speed.toStringAsFixed(2)} '
                '${tr.classifier.best?.label ?? '-'} '
                'rcsMov=${tr.classifier.rcsMoving.toStringAsFixed(1)} '
                'f=${tr.classifier.lastFeatures.map((k, v) => MapEntry(k, v.toStringAsFixed(2)))})')
            .join(' ');
        // ignore: avoid_print
        print('  t=${t.round()} truth speed=${b.speed.toStringAsFixed(2)} '
            'resting=${b.resting} $ts');
      });
      // ignore: avoid_print
      print('${k.name} natural: ${describe(r.track)}');
    }, timeout: const Timeout(Duration(minutes: 4)));
  }

  tearDownAll(() {
    // ignore: avoid_print
    print('CLASSIFICATION $correct / ${cases.length}');
  });

  test('overall accuracy', () {
    expect(correct, greaterThanOrEqualTo(6));
  });
}
