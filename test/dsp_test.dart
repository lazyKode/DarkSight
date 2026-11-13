import 'dart:math' as math;
import 'dart:typed_data';

import 'package:darksight/core/scene.dart';
import 'package:darksight/core/sim_radar_source.dart';
import 'package:darksight/dsp/fft.dart';
import 'package:darksight/dsp/fmcw_pipeline.dart';
import 'package:darksight/ml/classifier.dart';
import 'package:darksight/ml/detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FFT puts a complex tone in the right bin', () {
    final fft = Fft(64);
    final re = Float64List(64), im = Float64List(64);
    for (int n = 0; n < 64; n++) {
      re[n] = math.cos(2 * math.pi * 9 * n / 64);
      im[n] = math.sin(2 * math.pi * 9 * n / 64);
    }
    fft.transform(re, im);
    int best = 0;
    double bestP = 0;
    for (int k = 0; k < 64; k++) {
      final p = re[k] * re[k] + im[k] * im[k];
      if (p > bestP) {
        bestP = p;
        best = k;
      }
    }
    expect(best, 9);
    expect(math.sqrt(bestP), closeTo(64, 1e-6));
  });

  test('simulator images the wall nearest the radar at the right range', () {
    final scene = SceneController();
    final radar = SimRadarSource(scene)..sweepRate = 2;
    for (int i = 0; i < 60; i++) {
      radar.tick(1 / 30);
    }
    final f = radar.frame;
    // Default radar is at (5, 9.5); the wall at y = 12.5 is 3 m away, due
    // +y, which is bearing 90 degrees.
    int best = 10;
    for (int k = 10; k < f.bins; k++) {
      if (f.values[90 * f.bins + k] > f.values[90 * f.bins + best]) best = k;
    }
    final range = (best + 0.5) / f.bins * f.maxRange;
    expect(range, closeTo(3.0, 0.15));
    expect(f.values[90 * f.bins + best], greaterThan(0.7));
  });

  test('search detector finds structure and motion', () {
    final scene = SceneController();
    final radar = SimRadarSource(scene)
      ..sweepRate = 2
      ..noise = 0.2;
    final det = RadarDetector();
    final labels = <String>{};
    for (int i = 0; i < 150; i++) {
      radar.tick(1 / 30);
      if (i > 60 && i % 6 == 0) {
        labels.addAll(det.detect(radar.frame).map((d) => d.label));
      }
    }
    expect(labels, contains('wall'));
    expect(labels, contains('motion'));
  });

  test('FMCW pipeline recovers range, velocity and angle of one target', () {
    const cfg = FmcwConfig();
    final re = Float32List(cfg.cubeLength), im = Float32List(cfg.cubeLength);
    const r = 5.0, v = 1.0, sinTh = 0.5;
    for (int rx = 0; rx < cfg.rx; rx++) {
      for (int m = 0; m < cfg.chirps; m++) {
        for (int n = 0; n < cfg.samples; n++) {
          final ph = 2 *
                  math.pi *
                  (r / cfg.rangeRes * n / cfg.samples +
                      v / cfg.velocityRes * m / cfg.chirps) +
              math.pi * sinTh * rx;
          final i = (rx * cfg.chirps + m) * cfg.samples + n;
          re[i] = 0.2 * math.cos(ph);
          im[i] = 0.2 * math.sin(ph);
        }
      }
    }
    final p = FmcwPipeline(cfg)..process(re, im);
    expect(p.points, isNotEmpty);
    final best = p.points.reduce((a, b) => a.power > b.power ? a : b);
    expect(best.range, closeTo(r, 0.2));
    expect(best.velocity, closeTo(v, 0.26));
    expect(math.sin(best.angle), closeTo(sinTh, 0.1));
  });

  test('DBSCAN rules: long static cluster is structure, moving blob is a person',
      () {
    final pts = <RadarPoint>[
      for (double x = -2; x <= 2; x += 0.4)
        RadarPoint(math.sqrt(x * x + 64), math.atan2(x, 8), 0, 0.7),
      const RadarPoint(4.0, 0.00, 1.1, 0.8),
      const RadarPoint(4.2, 0.05, 0.9, 0.7),
      const RadarPoint(4.1, -0.06, 1.4, 0.6),
    ];
    final labels = PointClassifier().classify(pts).map((c) => c.label).toSet();
    expect(labels, containsAll(<String>['wall / structure', 'person']));
  });


  test('natural movement goes places through doors, never through walls',
      () {
    final scene = SceneController();
    scene.objects.removeWhere((o) => o.kind.isBody);
    final p = scene.addObject(ObjKind.person);
    p
      ..x = 4.5
      ..y = 10.5;
    scene.touch();
    final radar = SimRadarSource(scene)
      ..trajectory = 3
      ..personSpeed = 1.1;
    final walls = scene.objects.where((o) => o.kind == ObjKind.wall).toList();
    final doors = scene.objects.where((o) => o.kind == ObjKind.door).toList();
    bool crossesWall(double ax, double ay, double bx, double by) {
      double cr(double x1, double y1, double x2, double y2, double px, double py) =>
          (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1);
      for (final w in walls) {
        final d1 = cr(w.x, w.y, w.x2, w.y2, ax, ay);
        final d2 = cr(w.x, w.y, w.x2, w.y2, bx, by);
        final d3 = cr(ax, ay, bx, by, w.x, w.y);
        final d4 = cr(ax, ay, bx, by, w.x2, w.y2);
        if (((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))) {
          final inDoor = doors.any((d) {
            final dx = (ax + bx) / 2 - d.x, dy = (ay + by) / 2 - d.y;
            return dx * dx + dy * dy < 0.5 * 0.5;
          });
          if (!inDoor) return true;
        }
      }
      return false;
    }

    int violations = 0;
    double travelled = 0, stillFor = 0, longestStill = 0;
    double minX = 99, maxX = -99, minY = 99, maxY = -99;
    for (int i = 0; i < 30 * 180; i++) {
      final ox = p.x, oy = p.y;
      radar.tick(1 / 30);
      if (crossesWall(ox, oy, p.x, p.y)) violations++;
      final d = math.sqrt((p.x - ox) * (p.x - ox) + (p.y - oy) * (p.y - oy));
      travelled += d;
      stillFor = d < 0.002 ? stillFor + 1 / 30 : 0;
      longestStill = math.max(longestStill, stillFor);
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    // ignore: avoid_print
    print('natural walk: travelled ${travelled.toStringAsFixed(1)} m, '
        'area x ${minX.toStringAsFixed(1)}..${maxX.toStringAsFixed(1)} '
        'y ${minY.toStringAsFixed(1)}..${maxY.toStringAsFixed(1)}, '
        'longest stop ${longestStill.toStringAsFixed(1)} s, '
        'wall crossings $violations');
    expect(violations, 0);
    expect(travelled, greaterThan(20));
    expect(longestStill, greaterThan(2));
    expect(maxX - minX, greaterThan(4)); // reaches other rooms
  });
}
