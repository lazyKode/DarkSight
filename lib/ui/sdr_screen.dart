import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/sdr_radar_source.dart';
import '../core/settings.dart';
import 'heatmap.dart';
import 'pairing_screen.dart';
import 'point_cloud_view.dart';
import 'theme.dart';

/// Tier 3: pairing, then three swipeable views of the external radar.
class SdrScreen extends ConsumerStatefulWidget {
  const SdrScreen({super.key});

  @override
  ConsumerState<SdrScreen> createState() => _SdrScreenState();
}

class _SdrScreenState extends ConsumerState<SdrScreen>
    with SingleTickerProviderStateMixin {
  SdrRadarSource? _source;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final ValueNotifier<double> _yaw = ValueNotifier<double>(0.5);
  final PageController _pages = PageController();
  int _page = 0;
  int _seenFrame = -1;

  static const int _sectorW = 192, _sectorH = 96;
  static const double _fovSin = 0.866; // +/- 60 degrees
  GridImager? _rdImager;
  final GridImager _raImager = GridImager(_sectorW, _sectorH);
  Int32List? _sectorLut;
  ui.Image? _rdImage, _raImage;
  final Uint32List _cmap = buildColormap(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _connect(SdrDevice d) async {
    final src = SdrRadarSource(d)..start();
    _rdImager = GridImager(src.cfg.chirps, src.cfg.samples);
    _sectorLut = _buildSectorLut(src);
    _seenFrame = -1;
    setState(() => _source = src);
    // Remember the device profile (JSON) for next launch.
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          'sdrDevice',
          jsonEncode({
            'id': d.id,
            'name': d.name,
            'transport': d.transport.name,
            'profile': d.profile?.toJson(),
          }));
    } catch (_) {}
  }

  void _disconnect() {
    _source?.dispose();
    setState(() => _source = null);
  }

  /// Pixel -> range-angle cell for the top-down sector image. Radar at the
  /// bottom centre, boresight up.
  Int32List _buildSectorLut(SdrRadarSource s) {
    final lut = Int32List(_sectorW * _sectorH);
    final ns = s.cfg.samples, na = s.cfg.angleBins;
    for (int py = 0; py < _sectorH; py++) {
      for (int px = 0; px < _sectorW; px++) {
        final x = (px + 0.5 - _sectorW / 2) / (_sectorW / 2); // -1..1
        final y = (_sectorH - py - 0.5) / _sectorH; // 0..1 forward
        final r = math.sqrt(x * x + y * y);
        int v = -1;
        if (r < 1 && r > 1e-3) {
          final sinTh = x / r;
          if (sinTh.abs() <= _fovSin) {
            final k = math.min(ns - 1, (r * ns).floor());
            final a = math.min(
                na - 1, math.max(0, (sinTh * na / 2 + na / 2).floor()));
            v = k * na + a;
          }
        }
        lut[py * _sectorW + px] = v;
      }
    }
    return lut;
  }

  void _onTick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    final s = _source;
    if (s == null || dt <= 0 || dt > 1) return;
    s.tick(dt);
    if (s.frameCount != _seenFrame) {
      _seenFrame = s.frameCount;
      final rd = _rdImager!;
      if (!rd.busy) {
        rd.render(s.pipeline.rangeDoppler, _cmap).then((img) {
          if (img == null) return;
          if (!mounted) {
            img.dispose();
            return;
          }
          _rdImage?.dispose();
          _rdImage = img;
          _repaint.value++;
        });
      }
      if (s.hasAngle && !_raImager.busy) {
        _raImager
            .render(s.pipeline.rangeAngle, _cmap, lut: _sectorLut)
            .then((img) {
          if (img == null) return;
          if (!mounted) {
            img.dispose();
            return;
          }
          _raImage?.dispose();
          _raImage = img;
          _repaint.value++;
        });
      }
    }
    _repaint.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _source?.dispose();
    _rdImage?.dispose();
    _raImage?.dispose();
    _pages.dispose();
    _repaint.dispose();
    _yaw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _source;
    if (s == null) return PairingScreen(onConnected: _connect);
    final ai = ref.watch(settingsProvider.select((v) => v.aiOverlay));
    const titles = ['TOP-DOWN', 'RANGE-DOPPLER', 'POINT CLOUD'];
    return Column(
      children: [
        Container(
          color: kPanel,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<int>(
                  valueListenable: _repaint,
                  builder: (_, __, ___) => Text(
                      '${s.device.name}\n${s.status}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: kDim)),
                ),
              ),
              const Text('AI', style: TextStyle(fontSize: 11, color: kDim)),
              Switch(
                value: ai,
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update(ref.read(settingsProvider).copyWith(aiOverlay: v)),
              ),
              IconButton(
                tooltip: 'Disconnect',
                icon: const Icon(Icons.link_off, color: kAmber),
                onPressed: _disconnect,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('${titles[_page]}   (${_page + 1}/3, swipe)',
              style: const TextStyle(
                  color: kPhosphor, fontSize: 12, letterSpacing: 2)),
        ),
        Expanded(
          child: PageView(
            controller: _pages,
            onPageChanged: (p) => setState(() => _page = p),
            children: [
              CustomPaint(
                painter: _TopDownPainter(this, s, ai),
                child: const SizedBox.expand(),
              ),
              CustomPaint(
                painter: _RdPainter(this, s),
                child: const SizedBox.expand(),
              ),
              GestureDetector(
                // Vertical drag rotates, so horizontal swipes still page.
                onVerticalDragUpdate: (d) =>
                    _yaw.value += d.delta.dy * 0.01,
                child: CustomPaint(
                  painter: PointCloudPainter(
                      s, _yaw, Listenable.merge([_repaint, _yaw])),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RdPainter extends CustomPainter {
  _RdPainter(this.state, this.source) : super(repaint: state._repaint);
  final _SdrScreenState state;
  final SdrRadarSource source;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(34, 8, size.width - 46, size.height - 34);
    canvas.drawRect(r, Paint()..color = const Color(0xFF010201));
    final img = state._rdImage;
    if (img != null) {
      // Image rows are range bins from 0; flip so range increases upward.
      canvas.save();
      canvas.translate(0, r.top + r.bottom);
      canvas.scale(1, -1);
      canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          r,
          Paint()..filterQuality = FilterQuality.low);
      canvas.restore();
    }
    final axis = Paint()
      ..color = kPhosphor.withOpacity(0.5)
      ..style = PaintingStyle.stroke;
    canvas.drawRect(r, axis);
    canvas.drawLine(Offset(r.center.dx, r.top), Offset(r.center.dx, r.bottom),
        Paint()..color = kPhosphor.withOpacity(0.25));
    final cfg = source.cfg;
    for (int i = 0; i <= 4; i++) {
      final y = r.bottom - r.height * i / 4;
      paintLabel(canvas, (cfg.maxRange * i / 4).toStringAsFixed(0),
          Offset(6, y - 6), kDim,
          size: 10);
    }
    paintLabel(canvas, 'm', const Offset(6, 0), kDim, size: 10);
    for (int i = -2; i <= 2; i++) {
      final x = r.center.dx + r.width / 2 * i / 2;
      paintLabel(canvas, (cfg.maxVelocity * i / 2).toStringAsFixed(0),
          Offset(x - 6, r.bottom + 4), kDim,
          size: 10);
    }
    paintLabel(canvas, 'radial velocity, m/s',
        Offset(r.right - 150, r.bottom + 16), kDim,
        size: 10);
    if (img == null) {
      paintLabel(canvas, 'waiting for frames...', r.center - const Offset(60, 6),
          kAmber,
          size: 11);
    }
  }

  @override
  bool shouldRepaint(covariant _RdPainter oldDelegate) => false;
}

class _TopDownPainter extends CustomPainter {
  _TopDownPainter(this.state, this.source, this.showAi)
      : super(repaint: state._repaint);
  final _SdrScreenState state;
  final SdrRadarSource source;
  final bool showAi;

  @override
  void paint(Canvas canvas, Size size) {
    // Sector fits a 2:1 box: radar at the bottom centre.
    final w = math.min(size.width - 16, (size.height - 30) * 2);
    final h = w / 2;
    final r = Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
    final origin = Offset(r.center.dx, r.bottom);
    final maxR = source.cfg.maxRange;
    final scale = h / maxR;

    if (!source.hasAngle) {
      paintLabel(
          canvas,
          'This link carries range-Doppler frames only.\n'
          'Top-down imaging needs raw multi-channel IQ.',
          r.center - const Offset(150, 10),
          kAmber,
          size: 11);
      return;
    }
    final img = state._raImage;
    if (img != null) {
      canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          r,
          Paint()..filterQuality = FilterQuality.medium);
    }
    final ring = Paint()
      ..color = kPhosphor.withOpacity(0.22)
      ..style = PaintingStyle.stroke;
    const fov = math.pi / 3;
    for (int i = 1; i <= 4; i++) {
      canvas.drawArc(Rect.fromCircle(center: origin, radius: h * i / 4),
          -math.pi / 2 - fov, 2 * fov, false, ring);
      paintLabel(canvas, '${(maxR * i / 4).toStringAsFixed(0)} m',
          origin + Offset(4, -h * i / 4 + 2), kPhosphor.withOpacity(0.5),
          size: 9);
    }
    for (final s in [-1.0, 1.0]) {
      canvas.drawLine(
          origin,
          origin + Offset(math.sin(fov) * s, -math.cos(fov)) * h,
          ring);
    }
    canvas.drawCircle(origin, 4, Paint()..color = kPhosphor);

    if (!showAi) return;
    for (final c in source.clusters) {
      final color = c.label == 'person'
          ? kAlert
          : c.label == 'object'
              ? kAmber
              : const Color(0xFF4FC3F7);
      final box = Rect.fromLTRB(
        origin.dx + c.minX * scale - 6,
        origin.dy - c.maxY * scale - 6,
        origin.dx + c.maxX * scale + 6,
        origin.dy - c.minY * scale + 6,
      );
      canvas.drawRect(
          box,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6);
      paintLabel(canvas, c.label, Offset(box.left, box.top - 13), color,
          size: 9, background: true);
      if (c.label == 'person') {
        // Crude stick figure at the cluster centre.
        final p = Offset(origin.dx + c.cx * scale, origin.dy - c.cy * scale);
        final pen = Paint()
          ..color = color
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(p + const Offset(0, -9), 3, pen);
        canvas.drawLine(p + const Offset(0, -6), p + const Offset(0, 3), pen);
        canvas.drawLine(p + const Offset(-5, -2), p + const Offset(5, -2), pen);
        canvas.drawLine(p + const Offset(0, 3), p + const Offset(-4, 10), pen);
        canvas.drawLine(p + const Offset(0, 3), p + const Offset(4, 10), pen);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TopDownPainter oldDelegate) =>
      oldDelegate.showAi != showAi;
}
