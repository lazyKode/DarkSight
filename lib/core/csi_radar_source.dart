import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../dsp/motion_detector.dart';
import 'radar_source.dart';

/// Where the Tier 2 samples are coming from.
enum CsiInput { probing, rssi, simulated }

/// Tier 2: presence/motion from the phone's own Wi-Fi radio.
///
/// Working path today: RSSI of the associated access point, polled over the
/// `darksight/wifi` method channel (Android, see MainActivity.kt). People
/// moving through the link perturb the multipath sum and the RSSI wobbles.
///
/// TODO(csi): raw per-subcarrier CSI. Stock Android exposes no CSI API; it
/// needs a rooted device with patched Wi-Fi firmware (e.g. Nexmon CSI on
/// Broadcom chips) and a native reader (native/csi_android). When that
/// exists, feed amplitude vectors to [MotionDetector.update] in place of the
/// single RSSI value. The detector is already written for vectors.
///
/// When no RSSI is available (iOS, desktop, Wi-Fi off) the source switches
/// to a clearly labelled synthetic signal so the UI can still be exercised.
class CsiRadarSource extends RadarSource with ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('darksight/wifi');
  static const int historyLength = 300;
  static const double sampleHz = 10;

  final MotionDetector detector = MotionDetector();
  final Float32List energyHistory = Float32List(historyLength);
  final Float32List levelHistory = Float32List(historyLength);
  int head = 0;
  int samples = 0;

  CsiInput input = CsiInput.probing;
  double lastRssi = -60;
  bool present = false;

  Timer? _timer;
  int _misses = 0;
  double _presenceScore = 0;
  final math.Random _rng = math.Random(3);
  double _simT = 0;
  bool _disposed = false;

  @override
  String get label => switch (input) {
        CsiInput.probing => 'PROBING',
        CsiInput.rssi => 'RSSI',
        CsiInput.simulated => 'SIMULATED',
      };

  @override
  void start() {
    _timer ??= Timer.periodic(
        Duration(milliseconds: (1000 / sampleHz).round()), (_) => _poll());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void tick(double dt) {}

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }

  Future<double?> _readRssi() async {
    try {
      final v = await _channel.invokeMethod<num>('getRssi');
      return v?.toDouble();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  double _simulatedRssi() {
    // Quiet for ~10 s, then someone walks through for ~6 s, repeating.
    _simT += 1 / sampleHz;
    final phase = _simT % 16;
    double v = -57 + (_rng.nextDouble() - 0.5) * 0.6;
    if (phase > 10) {
      final k = (phase - 10) / 6;
      v += 4 * math.sin(_simT * 5.1) * math.sin(math.pi * k) +
          3 * (k - 0.5) +
          (_rng.nextDouble() - 0.5) * 2;
    }
    return v;
  }

  Future<void> _poll() async {
    double? rssi;
    if (input != CsiInput.simulated) {
      rssi = await _readRssi();
      if (_disposed) return;
      if (rssi == null) {
        if (++_misses >= 5) {
          input = CsiInput.simulated;
          detector.reset();
        }
      } else {
        _misses = 0;
        input = CsiInput.rssi;
      }
    }
    if (input == CsiInput.simulated) rssi = _simulatedRssi();
    if (rssi == null) return;

    lastRssi = rssi;
    const dt = 1 / sampleHz;
    detector.update([rssi], dt);

    // "Person present" placeholder classifier: leaky integral of motion.
    // TODO(ml): replace with the ~200 kB TFLite sequence classifier.
    _presenceScore += detector.state == MotionState.motion ? dt : -dt * 0.1;
    _presenceScore = _presenceScore.clamp(0.0, 6.0).toDouble();
    present = _presenceScore > 0.5;

    energyHistory[head] = detector.energy;
    levelHistory[head] = rssi;
    head = (head + 1) % historyLength;
    if (samples < historyLength) samples++;
    if (!_disposed) notifyListeners();
  }
}
