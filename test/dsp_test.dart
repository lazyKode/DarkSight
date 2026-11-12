import 'dart:math' as math;
import 'dart:typed_data';

import 'package:darksight/core/scene.dart';
import 'package:darksight/core/sim_radar_source.dart';
import 'package:darksight/dsp/fft.dart';
import 'package:darksight/dsp/fmcw_pipeline.dart';
import 'package:darksight/dsp/motion_detector.dart';
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

  test('detector labels structure and the moving person', () {
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
    expect(labels, contains('person'));
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

  test('motion detector: quiet stays still, fluctuation triggers, then clears',
      () {
    final d = MotionDetector();
    final rng = math.Random(1);
    for (int i = 0; i < 200; i++) {
      d.update([-55 + (rng.nextDouble() - 0.5) * 0.4], 0.1);
    }
    expect(d.state, MotionState.still);
    for (int i = 0; i < 40; i++) {
      d.update([-55 + 4 * math.sin(i * 0.9)], 0.1);
    }
    expect(d.state, MotionState.motion);
    for (int i = 0; i < 300; i++) {
      d.update([-55 + (rng.nextDouble() - 0.5) * 0.4], 0.1);
    }
    expect(d.state, MotionState.still);
  });
}
