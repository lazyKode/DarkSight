import 'dart:typed_data';

/// A polar (beam x range-bin) intensity image, the common currency between
/// radar sources and the PPI renderer.
class PolarFrame {
  PolarFrame({required this.beams, required this.bins, required this.maxRange})
      : values = Float32List(beams * bins),
        previous = Float32List(beams * bins),
        motion = Float32List(beams * bins),
        beamTime = Float64List(beams) {
    clear();
  }

  final int beams;
  final int bins;

  /// Range in metres represented by the outermost bin.
  double maxRange;

  /// Log-scaled intensity, 0..1 (0 = -60 dB, 1 = 0 dB full scale).
  final Float32List values;

  /// The value each cell held before its beam was last refreshed. Used for
  /// sweep-to-sweep change detection (moving-target indication).
  final Float32List previous;

  /// Two-pulse MTI residual per cell, same log scale as [values]: what
  /// changed between two chirps a few milliseconds apart. Zero where the
  /// source has no MTI.
  final Float32List motion;

  /// Source time (s) at which each beam was last refreshed.
  final Float64List beamTime;

  /// Current sweep bearing in radians (0 = +x, increasing clockwise on screen).
  double sweepAngle = 0;

  /// Source clock in seconds.
  double time = 0;

  void clear() {
    values.fillRange(0, values.length, 0);
    previous.fillRange(0, previous.length, 0);
    motion.fillRange(0, motion.length, 0);
    beamTime.fillRange(0, beams, -1e9);
  }
}

/// Abstract base for the three tiers.
abstract class RadarSource {
  /// Short label for the HUD ("SIM", "RSSI", "SDR").
  String get label;

  /// Polar image, when the source produces one.
  PolarFrame? get frame => null;

  void start() {}
  void stop() {}

  /// Advance the source by [dt] seconds. Called once per display frame.
  void tick(double dt);

  void dispose() {}
}
