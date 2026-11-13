import 'dart:async';
import 'dart:io' show InternetAddress, RawDatagramSocket, RawSocketEvent;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tier 2: real Wi-Fi sensing. There is no simulated data anywhere in this
/// file: if no real signal is available, the UI says so and shows nothing.
///
/// Two real sources:
///  * ESP32 sensor (any phone running the app): an ESP32 board on your
///    Wi-Fi measures channel state information (CSI), 64 subcarriers about
///    50 times a second, and streams it over UDP (firmware/esp32_csi).
///  * Phone Wi-Fi strength (Android app only): the RSSI of the router the
///    phone is connected to, about once a second. Much coarser.
///
/// What either can honestly tell you: whether something is moving in the
/// radio path compared with the empty room it was calibrated on. Not where
/// it is, not what it is, and not a person who is perfectly still.

enum WifiState { unavailable, noSignal, calibrating, still, motion }

/// Motion detection on a stream of signal vectors.
///
/// Metric: variance over a short sliding window. For CSI, each subcarrier's
/// amplitude variance relative to its mean, averaged over subcarriers (a
/// standard CSI motion statistic; the per-packet gain is removed first). For
/// RSSI, the variance in dB^2.
///
/// Threshold: learned during calibration with the area empty and still:
/// median + 6 robust standard deviations of the metric, with a floor. Motion
/// must stay above it for a moment to count, and stay below 80 % of it for 2
/// seconds to clear. If calibration happens with someone moving, the
/// threshold comes out high and the detector is less sensitive; it does not
/// produce false alarms.
class WifiMotionAnalyzer {
  WifiMotionAnalyzer(
      {required this.window,
      required this.relative,
      required this.floor,
      required this.minAbove});

  final double window; // s
  final bool relative; // CSI: variance relative to mean^2
  final double floor; // smallest allowed threshold
  final double minAbove; // s above threshold before declaring motion

  final List<double> _t = [];
  final List<Float64List> _x = [];
  Float64List _sum = Float64List(0), _sum2 = Float64List(0);

  double metric = 0;
  double? threshold;
  WifiState state = WifiState.noSignal;
  double lastMotion = double.negativeInfinity;
  double lastData = double.negativeInfinity;

  bool _calibrating = false;
  double _calibEnd = 0;
  final List<double> _calib = [];
  double _aboveSince = double.nan, _belowSince = double.nan;

  // History for display: (time, metric) pairs.
  final List<double> histT = [], histM = [];
  static const double histSeconds = 60;

  static const double calibrationSeconds = 20;
  double get calibrationLeft => math.max(0, _calibEnd - lastData);

  void startCalibration(double now) {
    _calibrating = true;
    _calibEnd = now + calibrationSeconds;
    _calib.clear();
    threshold = null;
    state = WifiState.calibrating;
  }

  void reset() {
    _t.clear();
    _x.clear();
    _sum = Float64List(0);
    histT.clear();
    histM.clear();
    threshold = null;
    _calibrating = false;
    state = WifiState.noSignal;
  }

  void add(double t, Float64List x) {
    if (_sum.length != x.length) {
      _t.clear();
      _x.clear();
      _sum = Float64List(x.length);
      _sum2 = Float64List(x.length);
    }
    _t.add(t);
    _x.add(x);
    for (int i = 0; i < x.length; i++) {
      _sum[i] += x[i];
      _sum2[i] += x[i] * x[i];
    }
    while (_t.isNotEmpty && t - _t.first > window) {
      final old = _x.first;
      for (int i = 0; i < old.length; i++) {
        _sum[i] -= old[i];
        _sum2[i] -= old[i] * old[i];
      }
      _t.removeAt(0);
      _x.removeAt(0);
    }
    lastData = t;
    final n = _t.length;
    if (n < 3) return;
    double m = 0;
    for (int i = 0; i < x.length; i++) {
      final mean = _sum[i] / n;
      final v = math.max(0.0, _sum2[i] / n - mean * mean);
      m += relative ? v / math.max(mean * mean, 1e-9) : v;
    }
    metric = m / x.length;
    histT.add(t);
    histM.add(metric);
    while (histT.isNotEmpty && t - histT.first > histSeconds) {
      histT.removeAt(0);
      histM.removeAt(0);
    }

    if (_calibrating) {
      _calib.add(metric);
      if (t >= _calibEnd && _calib.length >= 10) {
        final s = List<double>.from(_calib)..sort();
        final med = s[s.length ~/ 2];
        final dev = s.map((v) => (v - med).abs()).toList()..sort();
        final mad = dev[dev.length ~/ 2] * 1.4826;
        threshold = math.max(med + 6 * mad, math.max(floor, med * 1.5));
        _calibrating = false;
        state = WifiState.still;
      } else {
        state = WifiState.calibrating;
      }
      return;
    }
    final thr = threshold;
    if (thr == null) {
      state = WifiState.calibrating;
      return;
    }
    if (metric > thr) {
      _belowSince = double.nan;
      if (_aboveSince.isNaN) _aboveSince = t;
      if (t - _aboveSince >= minAbove) {
        state = WifiState.motion;
        lastMotion = t;
      }
    } else {
      _aboveSince = double.nan;
      if (state == WifiState.motion) {
        if (metric < 0.8 * thr) {
          if (_belowSince.isNaN) _belowSince = t;
          if (t - _belowSince >= 2) state = WifiState.still;
        } else {
          _belowSince = double.nan;
          lastMotion = t;
        }
      } else {
        state = WifiState.still;
      }
    }
  }
}

/// Receives CSI from the ESP32 sensor over UDP port 4211.
class Esp32CsiLink {
  static const int port = 4211;
  RawDatagramSocket? _sock;
  Timer? _hello;
  String host = '';
  String? error;
  int packets = 0;
  double rate = 0; // packets / s
  int lastRssi = 0;
  int _rateCount = 0;
  double _rateT0 = 0;

  // Subcarrier amplitude history for the waterfall (normalised).
  static const int maxSub = 64;
  final Float64List _avgAmp = Float64List(maxSub);
  int _frames = 0;

  void Function(double t, Float64List amps)? onFrame;

  Future<void> start(double Function() clock) async {
    if (kIsWeb) {
      error = 'Not possible in a web browser.';
      return;
    }
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port,
          reuseAddress: true);
      _sock!.broadcastEnabled = true;
      _sock!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        var d = _sock?.receive();
        while (d != null) {
          _parse(d.data, clock());
          d = _sock?.receive();
        }
      });
      _hello = Timer.periodic(const Duration(seconds: 2), (_) => sayHello());
      sayHello();
    } catch (e) {
      error = 'Could not open UDP port $port: $e';
    }
  }

  void sayHello() {
    final h = host.trim();
    if (h.isEmpty || _sock == null) return;
    try {
      final addr = InternetAddress.tryParse(h);
      if (addr == null) {
        error = '"$h" is not an IP address.';
        return;
      }
      error = null;
      _sock!.send('DSHELLO'.codeUnits, addr, port);
    } catch (e) {
      error = 'Could not reach $h: $e';
    }
  }

  void _parse(Uint8List b, double t) {
    if (b.length < 16) return;
    if (b[0] != 0x44 || b[1] != 0x53 || b[2] != 0x43 || b[3] != 0x53) return;
    if (b[4] != 1) return;
    final n = b[6];
    if (b.length < 16 + n) return;
    lastRssi = b[5] >= 128 ? b[5] - 256 : b[5];
    final nSub = math.min(maxSub, n ~/ 2);
    final amp = Float64List(nSub);
    for (int k = 0; k < nSub; k++) {
      int im = b[16 + 2 * k], re = b[17 + 2 * k];
      if (im >= 128) im -= 256;
      if (re >= 128) re -= 256;
      amp[k] = math.sqrt((re * re + im * im).toDouble());
    }
    _frames++;
    final a = _frames < 50 ? 1.0 / _frames : 0.02;
    for (int k = 0; k < nSub; k++) {
      _avgAmp[k] += a * (amp[k] - _avgAmp[k]);
    }
    // Keep subcarriers that carry signal (drops DC and guard bands), then
    // divide by the packet's mean amplitude to remove automatic gain changes.
    final used = <double>[];
    for (int k = 0; k < nSub; k++) {
      if (_avgAmp[k] > 2.0) used.add(amp[k]);
    }
    if (used.length < 8) return;
    final mean = used.reduce((x, y) => x + y) / used.length;
    if (mean <= 0) return;
    final v = Float64List.fromList(used.map((x) => x / mean).toList());
    packets++;
    _rateCount++;
    if (t - _rateT0 >= 2) {
      rate = _rateCount / (t - _rateT0);
      _rateCount = 0;
      _rateT0 = t;
    }
    onFrame?.call(t, v);
  }

  void stop() {
    _hello?.cancel();
    _sock?.close();
    _sock = null;
  }
}

/// Orchestrates the real sources and their analyzers.
class WifiSensing extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('darksight/wifi');

  final Stopwatch _clock = Stopwatch()..start();
  double get now => _clock.elapsedMicroseconds / 1e6;

  final Esp32CsiLink esp32 = Esp32CsiLink();
  final WifiMotionAnalyzer csi = WifiMotionAnalyzer(
      window: 1.0, relative: true, floor: 0.002, minAbove: 0.4);
  final WifiMotionAnalyzer rssi = WifiMotionAnalyzer(
      window: 6.0, relative: false, floor: 0.6, minAbove: 1.0);

  /// Why phone RSSI can't be used here, or null when it works.
  String? rssiUnavailable;
  int? lastRssi;
  int rssiUpdates = 0;
  int? _prevRssi;

  /// Recent normalised CSI vectors for the waterfall (oldest first).
  final List<Float64List> waterfall = [];
  final List<double> rssiHist = [], rssiHistT = [];

  Timer? _poll, _ui;
  bool _disposed = false;

  bool get esp32Live => now - csi.lastData < 3;
  bool get rssiLive => rssiUnavailable == null && now - rssi.lastData < 6;

  /// The source the big indicator follows.
  WifiMotionAnalyzer? get active =>
      esp32Live ? csi : (rssiLive ? rssi : null);

  Future<void> start() async {
    if (kIsWeb) {
      rssiUnavailable = 'A web browser cannot read Wi-Fi signals.';
      esp32.error = 'A web browser cannot receive the sensor\'s data.';
      notifyListeners();
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      rssiUnavailable =
          'iPhone does not let apps read Wi-Fi signal strength. Use the ESP32 sensor.';
    } else if (defaultTargetPlatform != TargetPlatform.android) {
      rssiUnavailable = 'Phone Wi-Fi reading works in the Android app only.';
    }
    try {
      final p = await SharedPreferences.getInstance();
      esp32.host = p.getString('esp32Host') ?? '';
    } catch (_) {}
    esp32.onFrame = (t, v) {
      if (csi.state == WifiState.noSignal && csi.threshold == null) {
        csi.startCalibration(t);
      }
      csi.add(t, v);
      waterfall.add(v);
      if (waterfall.length > 300) waterfall.removeAt(0);
    };
    await esp32.start(() => now);
    if (rssiUnavailable == null) {
      try {
        await _channel.invokeMethod<void>('multicastLock');
      } catch (_) {}
      _poll = Timer.periodic(
          const Duration(milliseconds: 250), (_) => _pollRssi());
    }
    _ui = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _pollRssi() async {
    int? v;
    try {
      v = (await _channel.invokeMethod<num>('getRssi'))?.toInt();
    } on MissingPluginException {
      rssiUnavailable = 'This build cannot read Wi-Fi strength.';
      _poll?.cancel();
      return;
    } on PlatformException catch (e) {
      rssiUnavailable = 'Wi-Fi strength unavailable: ${e.message}';
      return;
    }
    if (_disposed) return;
    if (v == null) {
      // Not connected to Wi-Fi.
      lastRssi = null;
      return;
    }
    final t = now;
    if (v != _prevRssi) rssiUpdates++;
    _prevRssi = v;
    lastRssi = v;
    if (rssi.state == WifiState.noSignal && rssi.threshold == null) {
      rssi.startCalibration(t);
    }
    rssi.add(t, Float64List.fromList([v.toDouble()]));
    rssiHist.add(v.toDouble());
    rssiHistT.add(t);
    while (rssiHistT.isNotEmpty && t - rssiHistT.first > 60) {
      rssiHistT.removeAt(0);
      rssiHist.removeAt(0);
    }
  }

  void calibrate() {
    if (esp32Live) csi.startCalibration(now);
    if (rssiLive) rssi.startCalibration(now);
    notifyListeners();
  }

  Future<void> setHost(String h) async {
    esp32.host = h.trim();
    esp32.sayHello();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('esp32Host', esp32.host);
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _ui?.cancel();
    esp32.stop();
    super.dispose();
  }
}
