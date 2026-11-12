import 'dart:math' as math;

import '../dsp/fmcw_pipeline.dart';

/// A labelled cluster of radar points (metres; x right, y forward).
class Cluster {
  Cluster(this.minX, this.minY, this.maxX, this.maxY, this.count,
      this.meanSpeed, this.label);
  final double minX, minY, maxX, maxY;
  final int count;
  final double meanSpeed; // mean |radial velocity|, m/s
  final String label;
  double get cx => (minX + maxX) / 2;
  double get cy => (minY + maxY) / 2;
  double get extent => math.max(maxX - minX, maxY - minY);
}

/// Tier 3 overlay: DBSCAN over CFAR points, then the size/motion rule set
/// from the spec. A learned classifier (TFLite / Core ML) would replace
/// [_label] and take the cluster's point features as input.
class PointClassifier {
  PointClassifier({this.eps = 0.7, this.minPts = 2});
  final double eps;
  final int minPts;

  List<Cluster> classify(List<RadarPoint> pts) {
    final n = pts.length;
    if (n == 0) return const [];
    final xs = List<double>.generate(n, (i) => pts[i].x);
    final ys = List<double>.generate(n, (i) => pts[i].y);
    final label = List<int>.filled(n, -2); // -2 unvisited, -1 noise
    final eps2 = eps * eps;

    List<int> neighbours(int i) {
      final out = <int>[];
      for (int j = 0; j < n; j++) {
        final dx = xs[i] - xs[j], dy = ys[i] - ys[j];
        if (dx * dx + dy * dy <= eps2) out.add(j);
      }
      return out;
    }

    int clusters = 0;
    for (int i = 0; i < n; i++) {
      if (label[i] != -2) continue;
      final seed = neighbours(i);
      if (seed.length < minPts) {
        label[i] = -1;
        continue;
      }
      final id = clusters++;
      label[i] = id;
      final queue = List<int>.from(seed);
      for (int q = 0; q < queue.length; q++) {
        final j = queue[q];
        if (label[j] == -1) label[j] = id; // border point
        if (label[j] != -2) continue;
        label[j] = id;
        final nb = neighbours(j);
        if (nb.length >= minPts) queue.addAll(nb);
      }
    }

    final out = <Cluster>[];
    for (int c = 0; c < clusters; c++) {
      double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9, speed = 0;
      int count = 0;
      for (int i = 0; i < n; i++) {
        if (label[i] != c) continue;
        count++;
        speed += pts[i].velocity.abs();
        if (xs[i] < minX) minX = xs[i];
        if (xs[i] > maxX) maxX = xs[i];
        if (ys[i] < minY) minY = ys[i];
        if (ys[i] > maxY) maxY = ys[i];
      }
      if (count == 0) continue;
      speed /= count;
      final extent = math.max(maxX - minX, maxY - minY);
      out.add(Cluster(minX, minY, maxX, maxY, count, speed,
          _label(extent, speed, count)));
    }
    return out;
  }

  static String _label(double extent, double speed, int count) {
    final moving = speed > 0.3;
    if (!moving && extent > 1.5) return 'wall / structure';
    if (moving && (extent > 0.25 || count >= 3)) return 'person';
    return 'object';
  }
}
