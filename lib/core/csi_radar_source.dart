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

/// What the screen shows.
enum WifiState { noSignal, calibrating, still, motion }

/// Internal phases of [WifiMotionAnalyzer]. All transitions happen in
/// [WifiMotionAnalyzer.add]:
///
///   calibrating --(20 s of data)----------------------------> quiet
///   quiet       --(metric > threshold)----------------------> rising
///   rising      --(still above after minAbove)-------------> motion
///   rising      --(drops back below)-------------------------> quiet
///   motion      --(metric < 80 % of threshold)-------------> falling
///   falling     --(back above 80 %)--------------------------> motion
///   falling     --(below for 2 s)----------------------------> quiet
///   any         --(recalibrate)------------------------------> calibrating
///
/// Before any data the analyzer is [_Phase.calibrating] with no deadline:
/// the 20 s start with the first sample. Data that stops arriving is not a
/// phase: [stateAt] reports [WifiState.noSignal] once it is stale, whatever
/// phase the analyzer was in.
enum _Phase { calibrating, quiet, rising, motion, falling }

/// Motion detection on a stream of signal vectors.
///
/// Metric: variance over a short sliding window. For CSI, each subcarrier's
/// amplitude variance relative to its mean, averaged over subcarriers (a
/// standard CSI motion statistic; the per-packet gain is removed first). For
/// RSSI, the variance in dB^2.
///
/// Threshold: learned during calibration with the area empty and still:
/// median + 6 robust standard deviations of the metric, with a floor. If
/// calibration happens with someone moving, the threshold comes out high
/// and the detector is less sensitive; it does not produce false alarms.
class WifiMotionAnalyzer {
  WifiMotionAnalyzer(
      {required this.window,
      required this.relative,
      required this.floor,
      required this.minAbove,
      required this.staleAfter});

  final double window; // s
  final bool relative; // CSI: variance relative to mean^2
  final double floor; // smallest allowed threshold
  final double minAbove; // s above threshold before declaring motion
  final double staleAfter; // s without data before "no signal"

  static const double calibrationSeconds = 20;
  static const double clearAfter = 2;

  final List<double> _t = [];
  final List<Float64List> _x = [];
  Float64List _sum = Float64List(0), _sum2 = Float64List(0);

  double metric = 0;
  double lastMotion = double.negativeInfinity;
  double lastData = double.negativeInfinity;

  _Phase _phase = _Phase.calibrating;
  double _phaseSince = 0;
  double? _calibEnd; // set by the first sample of a calibration
  final List<double> _calib = [];
  double? _threshold; // non-null in every phase except calibrating

  double? get threshold => _threshold;

  // History for display: (time, metric) pairs.
  final List<double> histT = [], histM = [];
  static const double histSeconds = 60;

  double calibrationLeftAt(double now) {
    final end = _calibEnd;
    if (_phase != _Phase.calibrating) return 0;
    return end == null ? calibrationSeconds : math.max(0, end - now);
  }

  bool liveAt(double now) => now - lastData < staleAfter;

  WifiState stateAt(double now) {
    if (!liveAt(now)) return WifiState.noSignal;
    return switch (_phase) {
      _Phase.calibrating => WifiState.calibrating,
      _Phase.quiet || _Phase.rising => WifiState.still,
      _Phase.motion || _Phase.falling => WifiState.motion,
    };
  }

  void _go(_Phase p, double t) {
    _phase = p;
    _phaseSince = t;
  }

  /// Start (or restart) learning the empty room. Works whether or not data
  /// is flowing right now: the 20 s begin with the next sample.
  void recalibrate() {
    _phase = _Phase.calibrating;
    _calibEnd = null;
    _calib.clear();
    _threshold = null;
  }

  void add(double t, Float64List x) {
    if (_sum.length != x.length) {
      _t.clear();
      _x.clear();
      _sum = Float64List(x.length);
      _sum2 = Float64List(x.length);
    }
    // A gap in the data invalidates the sliding window.
    if (_t.isNotEmpty && t - _t.last > staleAfter) {
      _t.clear();
      _x.clear();
      _sum.fillRange(0, _sum.length, 0);
      _sum2.fillRange(0, _sum2.length, 0);
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
    _step(t);
  }

  void _step(double t) {
    switch (_phase) {
      case _Phase.calibrating:
        _calibEnd ??= t + calibrationSeconds;
        _calib.add(metric);
        if (t >= _calibEnd! && _calib.length >= 10) {
          final s = List<double>.from(_calib)..sort();
          final med = s[s.length ~/ 2];
          final dev = s.map((v) => (v - med).abs()).toList()..sort();
          final mad = dev[dev.length ~/ 2] * 1.4826;
          _threshold = math.max(med + 6 * mad, math.max(floor, med * 1.5));
          _go(_Phase.quiet, t);
        }
      case _Phase.quiet:
        if (metric > _threshold!) _go(_Phase.rising, t);
      case _Phase.rising:
        if (metric <= _threshold!) {
          _go(_Phase.quiet, t);
        } else if (t - _phaseSince >= minAbove) {
          _go(_Phase.motion, t);
          lastMotion = t;
        }
      case _Phase.motion:
        lastMotion = t;
        if (metric < 0.8 * _threshold!) _go(_Phase.falling, t);
      case _Phase.falling:
        if (metric >= 0.8 * _threshold!) {
          _go(_Phase.motion, t);
          lastMotion = t;
        } else if (t - _phaseSince >= clearAfter) {
          _go(_Phase.quiet, t);
        }
    }
  }
}

/// State of the link to the ESP32 sensor, derived in one place
/// ([Esp32CsiLink.linkAt]) instead of from scattered error strings.
enum SensorLink { unsupported, portError, needAddress, badAddress, waiting, receiving }

/// Receives CSI from the ESP32 sensor over UDP port 4211.
class Esp32CsiLink {
  static const int port = 4211;
  RawDatagramSocket? _sock;
  Timer? _hello;
  String host = '';
  String? _bindError;
  String? sendError;
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
    if (kIsWeb) return;
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
      _bindError = 'Could not open UDP port $port: $e';
    }
  }

  InternetAddress? get _address {
    final h = host.trim();
    return h.isEmpty ? null : InternetAddress.tryParse(h);
  }

  SensorLink linkAt({required bool live}) {
    if (kIsWeb) return SensorLink.unsupported;
    if (_bindError != null) return SensorLink.portError;
    if (live) return SensorLink.receiving;
    if (host.trim().isEmpty) return SensorLink.needAddress;
    if (_address == null) return SensorLink.badAddress;
    return SensorLink.waiting;
  }

  String? get detail => _bindError ?? sendError;

  void sayHello() {
    final addr = _address;
    final sock = _sock;
    if (addr == null || sock == null) return;
    try {
      sock.send('DSHELLO'.codeUnits, addr, port);
      sendError = null;
    } catch (e) {
      sendError = 'Could not reach ${host.trim()}: $e';
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
      window: 1.0, relative: true, floor: 0.002, minAbove: 0.4, staleAfter: 3);
  final WifiMotionAnalyzer rssi = WifiMotionAnalyzer(
      window: 6.0, relative: false, floor: 0.6, minAbove: 1.0, staleAfter: 6);

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

  bool get esp32Live => csi.liveAt(now);
  bool get rssiLive => rssiUnavailable == null && rssi.liveAt(now);

  /// The source the big indicator follows.
  WifiMotionAnalyzer? get active =>
      esp32Live ? csi : (rssiLive ? rssi : null);

  Future<void> start() async {
    if (kIsWeb) {
      rssiUnavailable = 'A web browser cannot read Wi-Fi signals.';
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
    rssi.add(t, Float64List.fromList([v.toDouble()]));
    rssiHist.add(v.toDouble());
    rssiHistT.add(t);
    while (rssiHistT.isNotEmpty && t - rssiHistT.first > 60) {
      rssiHistT.removeAt(0);
      rssiHist.removeAt(0);
    }
  }

  void calibrate() {
    csi.recalibrate();
    rssi.recalibrate();
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
