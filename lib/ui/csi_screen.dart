import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/csi_radar_source.dart';
import 'theme.dart';

/// Tier 2: real Wi-Fi motion sensing. Shows only measured data; when there
/// is none it says why.
class CsiScreen extends StatefulWidget {
  const CsiScreen({super.key});

  @override
  State<CsiScreen> createState() => _CsiScreenState();
}

class _CsiScreenState extends State<CsiScreen> {
  final WifiSensing _w = WifiSensing();
  final TextEditingController _host = TextEditingController();

  @override
  void initState() {
    super.initState();
    _w.start().then((_) {
      if (mounted) _host.text = _w.esp32.host;
    });
  }

  @override
  void dispose() {
    _w.dispose();
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const _WebOnly();
    return AnimatedBuilder(
      animation: _w,
      builder: (context, _) {
        final a = _w.active;
        final state = a?.state ?? WifiState.noSignal;
        final now = _w.now;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _bigState(a, state, now),
            const SizedBox(height: 12),
            if (a != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      a.threshold == null
                          ? 'Learning this room\'s normal signal…'
                          : 'Threshold learned from the empty room. Recalibrate if '
                              'you move the sensor or router.',
                      style: const TextStyle(color: kDim, fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _w.calibrate,
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('RECALIBRATE'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _section('MOTION METRIC  ·  last 60 s'),
              SizedBox(
                height: 110,
                child: CustomPaint(
                    painter: _MetricPainter(a, now), child: const SizedBox.expand()),
              ),
              const SizedBox(height: 10),
              if (_w.esp32Live) ...[
                _section('CSI  ·  subcarrier amplitude over time (ESP32)'),
                SizedBox(
                  height: 120,
                  child: CustomPaint(
                      painter: _WaterfallPainter(_w.waterfall),
                      child: const SizedBox.expand()),
                ),
              ] else ...[
                _section('PHONE WI-FI STRENGTH  ·  last 60 s'),
                SizedBox(
                  height: 100,
                  child: CustomPaint(
                      painter: _LinePainter(_w.rssiHistT, _w.rssiHist, now, 'dBm'),
                      child: const SizedBox.expand()),
                ),
              ],
              const SizedBox(height: 14),
            ],
            _section('SOURCES'),
            const SizedBox(height: 6),
            _esp32Card(),
            const SizedBox(height: 8),
            _rssiCard(),
            const SizedBox(height: 14),
            const Text(
              'What this can tell you: whether something is moving in the '
              'radio path, compared with the empty room it learned. It cannot '
              'show where a person is, what they look like, or detect someone '
              'who is perfectly still. Pets and fans also cause motion.',
              style: TextStyle(color: kDim, fontSize: 11, height: 1.4),
            ),
          ],
        );
      },
    );
  }

  Widget _bigState(WifiMotionAnalyzer? a, WifiState s, double now) {
    String title, sub;
    Color c;
    switch (a == null ? WifiState.noSignal : s) {
      case WifiState.motion:
        title = 'MOTION';
        sub = 'Something is moving in the Wi-Fi path';
        c = kAlert;
        break;
      case WifiState.still:
        final ago = now - a!.lastMotion;
        title = 'NO MOTION';
        sub = ago.isFinite
            ? 'Last motion ${_ago(ago)} ago'
            : 'No motion since calibration';
        c = kPhosphor;
        break;
      case WifiState.calibrating:
        title = 'CALIBRATING';
        sub = 'Keep the area empty and still · '
            '${a!.calibrationLeft.ceil()} s';
        c = kAmber;
        break;
      default:
        title = 'NO SIGNAL';
        sub = 'No real Wi-Fi data yet: see Sources below';
        c = kDim;
    }
    final src = a == null
        ? ''
        : (identical(a, _w.csi)
            ? 'ESP32 CSI · ${_w.esp32.rate.toStringAsFixed(0)} readings/s'
            : 'Phone Wi-Fi strength · ${_w.lastRssi ?? '-'} dBm');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kPanel,
        border: Border.all(color: c.withOpacity(0.7)),
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c,
              boxShadow: s == WifiState.motion
                  ? [BoxShadow(color: c.withOpacity(0.6), blurRadius: 16)]
                  : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: c,
                        fontSize: 26,
                        letterSpacing: 3,
                        fontWeight: FontWeight.w700)),
                Text(sub, style: const TextStyle(color: kDim, fontSize: 12)),
                if (src.isNotEmpty)
                  Text(src,
                      style: const TextStyle(color: kDim, fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _esp32Card() {
    final e = _w.esp32;
    final live = _w.esp32Live;
    final status = e.error ??
        (live
            ? 'Receiving: ${e.rate.toStringAsFixed(0)} readings/s, '
                'link ${e.lastRssi} dBm'
            : (e.host.isEmpty
                ? 'Enter the IP the board prints on its Serial Monitor.'
                : 'Waiting for data from ${e.host}…'));
    return _card(
      'ESP32 SENSOR (recommended)',
      live ? kPhosphor : kDim,
      [
        Text(status,
            style: TextStyle(
                fontSize: 11, color: e.error != null ? kAmber : kDim)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _host,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Board IP, e.g. 192.168.1.50',
                    border: OutlineInputBorder()),
                onSubmitted: _w.setHost,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                onPressed: () => _w.setHost(_host.text),
                child: const Text('CONNECT')),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'An ESP32 board (about \$5–10) on your Wi-Fi reads detailed channel '
          'data (CSI) and sends it here. Firmware and steps: '
          'firmware/esp32_csi in the GitHub repo.',
          style: TextStyle(fontSize: 10, color: kDim, height: 1.35),
        ),
      ],
    );
  }

  Widget _rssiCard() {
    final why = _w.rssiUnavailable;
    String status;
    if (why != null) {
      status = why;
    } else if (_w.lastRssi == null) {
      status = 'Phone is not connected to Wi-Fi.';
    } else {
      status = '${_w.lastRssi} dBm · ${_w.rssiUpdates} changes seen. Coarse: '
          'notices people walking between the phone and the router.';
    }
    return _card('PHONE WI-FI STRENGTH (Android)',
        why == null && _w.rssiLive ? kPhosphor : kDim, [
      Text(status,
          style: TextStyle(fontSize: 11, color: why != null ? kAmber : kDim)),
    ]);
  }

  Widget _card(String title, Color c, List<Widget> body) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: kSurface,
          border: Border.all(color: c.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(color: c, fontSize: 11, letterSpacing: 1.5)),
            const SizedBox(height: 4),
            ...body,
          ],
        ),
      );

  Widget _section(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(s,
            style: const TextStyle(
                color: kPhosphor, fontSize: 10, letterSpacing: 2)),
      );

  static String _ago(double s) {
    if (s < 60) return '${s.round()} s';
    if (s < 3600) return '${(s / 60).floor()} min';
    return '${(s / 3600).floor()} h';
  }
}

class _WebOnly extends StatelessWidget {
  const _WebOnly();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'WI-FI SENSING IS NOT AVAILABLE IN A WEB BROWSER\n\n'
            'Browsers cannot read Wi-Fi signals, so this page shows nothing '
            'rather than invented data.\n\n'
            'Use the installed app instead:\n'
            '• Android app: reads your phone\'s Wi-Fi strength (coarse), or\n'
            '• Android or iPhone app with an ESP32 sensor board: detailed '
            'Wi-Fi channel data (recommended).',
            textAlign: TextAlign.center,
            style: TextStyle(color: kDim, fontSize: 13, height: 1.5),
          ),
        ),
      );
}

class _MetricPainter extends CustomPainter {
  _MetricPainter(this.a, this.now);
  final WifiMotionAnalyzer a;
  final double now;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = const Color(0xFF010201));
    canvas.drawRect(
        r,
        Paint()
          ..color = kPhosphor.withOpacity(0.35)
          ..style = PaintingStyle.stroke);
    if (a.histM.length < 2) return;
    final thr = a.threshold;
    double mx = thr != null ? thr * 3 : 0;
    for (final m in a.histM) {
      mx = math.max(mx, m);
    }
    mx = math.max(mx, 1e-9) * 1.1;
    double x(double t) => size.width * (1 - (now - t) / WifiMotionAnalyzer.histSeconds);
    double y(double m) => size.height * (1 - m / mx);
    if (thr != null) {
      canvas.drawLine(Offset(0, y(thr)), Offset(size.width, y(thr)),
          Paint()
            ..color = kAlert.withOpacity(0.7)
            ..strokeWidth = 1);
      paintLabel(canvas, 'motion threshold', Offset(4, y(thr) - 13), kAlert,
          size: 9);
    }
    final path = Path();
    for (int i = 0; i < a.histM.length; i++) {
      final p = Offset(x(a.histT[i]), y(a.histM[i]));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = kPhosphor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
  }

  @override
  bool shouldRepaint(covariant _MetricPainter old) => true;
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.t, this.v, this.now, this.unit);
  final List<double> t, v;
  final double now;
  final String unit;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = const Color(0xFF010201));
    canvas.drawRect(
        r,
        Paint()
          ..color = kPhosphor.withOpacity(0.35)
          ..style = PaintingStyle.stroke);
    if (v.length < 2) return;
    double lo = v.reduce(math.min), hi = v.reduce(math.max);
    if (hi - lo < 4) {
      final c = (hi + lo) / 2;
      lo = c - 2;
      hi = c + 2;
    }
    final path = Path();
    for (int i = 0; i < v.length; i++) {
      final px = size.width * (1 - (now - t[i]) / 60);
      final py = size.height * (1 - (v[i] - lo) / (hi - lo));
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = kAmber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
    paintLabel(canvas, '${hi.round()} $unit', const Offset(4, 2), kDim, size: 9);
    paintLabel(canvas, '${lo.round()} $unit', Offset(4, size.height - 13), kDim,
        size: 9);
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

class _WaterfallPainter extends CustomPainter {
  _WaterfallPainter(this.rows);
  final List<Float64List> rows;
  static final _cmap = buildColormap(0);
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = const Color(0xFF010201));
    if (rows.isEmpty) return;
    final nSub = rows.last.length;
    final w = size.width / rows.length, h = size.height / nSub;
    final p = Paint();
    for (int i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.length != nSub) continue;
      for (int k = 0; k < nSub; k++) {
        // Relative amplitude 0.3..1.7 -> colour.
        final v = ((row[k] - 0.3) / 1.4).clamp(0.0, 1.0);
        final c = _cmap[(v * 255).toInt()];
        p.color = Color.fromARGB(
            255, c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF);
        canvas.drawRect(Rect.fromLTWH(i * w, k * h, w + 0.5, h + 0.5), p);
      }
    }
    canvas.drawRect(
        r,
        Paint()
          ..color = kPhosphor.withOpacity(0.35)
          ..style = PaintingStyle.stroke);
    paintLabel(canvas, 'subcarriers ↕   time →   newest at right',
        const Offset(4, 2), kPhosphor, size: 9, background: true);
  }

  @override
  bool shouldRepaint(covariant _WaterfallPainter old) => true;
}
