import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/tracker.dart';
import '../dsp/radar_constants.dart';
import '../ml/target_classifier.dart';
import 'heatmap.dart';
import 'ppi_view.dart';
import 'theme.dart';

/// Compass bearing (0 = up, clockwise) of a radar-relative point.
double compassDeg(double x, double y) =>
    ((math.atan2(y, x) * 180 / math.pi) + 90 + 360) % 360;

/// Target dossier: classification, telemetry, signature evidence, live
/// micro-Doppler waterfall and breathing trace for the selected track.
class TargetPanel extends StatefulWidget {
  const TargetPanel({
    super.key,
    required this.tracks,
    required this.selected,
    required this.onSelect,
    required this.repaint,
  });

  final List<Track> Function() tracks;
  final int? Function() selected;
  final void Function(int id) onSelect;
  final Listenable repaint;

  @override
  State<TargetPanel> createState() => _TargetPanelState();
}

class _TargetPanelState extends State<TargetPanel> {
  final GridImager _imager = GridImager(128, Radar.nDoppler);
  final Float32List _wf = Float32List(128 * Radar.nDoppler);
  final Uint32List _cmap = buildColormap(0);
  ui.Image? _waterfall;
  int _lastCols = -1;
  int _frame = 0;

  @override
  void dispose() {
    _waterfall?.dispose();
    super.dispose();
  }

  Track? _current() {
    final ts = widget.tracks();
    final sel = widget.selected();
    for (final t in ts) {
      if (t.id == sel) return t;
    }
    for (final t in ts) {
      if (t.status != TrackStatus.tentative && t.ghostOf == null) return t;
    }
    return ts.isEmpty ? null : ts.first;
  }

  void _updateWaterfall(Track t) {
    if (++_frame % 4 != 0) return;
    final p = t.processor;
    if (p.chirps == _lastCols) return;
    _lastCols = p.chirps;
    final nf = p.noisePerDopplerBin;
    const w = 128, h = Radar.nDoppler;
    final have = math.min(p.colCount, w);
    // Rows = velocity (top = approaching... we put +velocity up), cols = time.
    for (int x = 0; x < w; x++) {
      final age = w - 1 - x; // newest on the right
      for (int y = 0; y < h; y++) {
        double v = 0;
        if (age < have) {
          final d = h - 1 - y; // +velocity at the top
          final pw = p.column(age, d);
          v = (10 * math.log(pw / nf + 1e-9) / math.ln10) / 40; // 0..40 dB SNR
        }
        _wf[y * w + x] = v.clamp(0.0, 1.0).toDouble();
      }
    }
    if (_imager.busy) return;
    _imager.render(_wf, _cmap).then((img) {
      if (img == null) return;
      if (!mounted) {
        img.dispose();
        return;
      }
      _waterfall?.dispose();
      setState(() => _waterfall = img);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.repaint,
      builder: (context, _) {
        final ts = widget.tracks();
        final t = _current();
        if (t == null) {
          return const _Empty();
        }
        _updateWaterfall(t);
        final cls = t.classifier.best;
        final post = t.classifier.posterior;
        final f = t.features;
        final color = classColor(cls);
        final status = t.ghostOf != null
            ? 'LIKELY MULTIPATH OF T-${t.ghostOf.toString().padLeft(2, '0')}'
            : switch (t.status) {
                TrackStatus.tentative => 'ACQUIRING',
                TrackStatus.confirmed => 'TRACKING',
                TrackStatus.coasting => 'SIGNAL LOST',
              };
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          children: [
            // Track chips.
            SizedBox(
              height: 28,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final tt in ts)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => widget.onSelect(tt.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: tt.id == t.id
                                    ? classColor(tt.classifier.best)
                                    : const Color(0xFF1E3A1E)),
                            color: tt.id == t.id ? kPanel : Colors.transparent,
                          ),
                          child: Text(
                            'T-${tt.id.toString().padLeft(2, '0')} '
                            '${tt.classifier.best?.label ?? '?'}',
                            style: TextStyle(
                                fontSize: 10,
                                color: classColor(tt.classifier.best)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'TARGET T-${t.id.toString().padLeft(2, '0')} · $status',
                          style: const TextStyle(
                              color: kDim, fontSize: 10, letterSpacing: 1.5)),
                      const SizedBox(height: 2),
                      Text(cls?.label ?? 'ANALYSING',
                          style: TextStyle(
                              color: color,
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 3)),
                      Text(
                          cls == null
                              ? 'collecting signature (${t.classifier.updates}/3 s)'
                              : '${cls.detail} · ${(t.classifier.confidence * 100).round()}% confidence',
                          style: const TextStyle(color: kDim, fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final c in TargetClass.values)
              _Bar(c.label, post[c] ?? 0, classColor(c)),
            const SizedBox(height: 12),
            _section('TELEMETRY'),
            _grid([
              ('RANGE', '${t.range.toStringAsFixed(2)} m'),
              ('BEARING', '${compassDeg(t.x, t.y).round().toString().padLeft(3, '0')}°'),
              ('SPEED', '${t.speed.toStringAsFixed(2)} m/s'),
              ('HEADING', t.speed > 0.2
                  ? '${compassDeg(t.vx, t.vy).round().toString().padLeft(3, '0')}°'
                  : '—'),
              ('RADIAL', '${t.radialVelocity >= 0 ? '+' : ''}${t.radialVelocity.toStringAsFixed(2)} m/s'),
              ('WALLS', '${t.walls} detected'),
            ]),
            const SizedBox(height: 10),
            _section('SIGNATURE'),
            _grid([
              ('RCS', t.classifier.rcsMoving.isFinite
                  ? '${t.classifier.rcsMoving.toStringAsFixed(1)} dBsm'
                  : (f.rcsDbsm.isFinite ? '${f.rcsDbsm.toStringAsFixed(1)} dBsm' : '—')),
              ('µ-DOPPLER', f.detected ? '${f.span.toStringAsFixed(1)} m/s span' : '—'),
              ('RHYTHM', f.detected && f.cadenceSnr > 4
                  ? '${f.cadence.toStringAsFixed(2)} Hz'
                  : 'no clear rhythm'),
              ('BREATHING', f.breathBpm.isFinite && f.breathSnr > 4
                  ? '${f.breathBpm.round()} /min'
                  : (t.still ? 'measuring (${t.stillTime.round()}/10 s)' : 'needs target still')),
            ]),
            const SizedBox(height: 10),
            _section('MICRO-DOPPLER  ·  last 4 s  ·  ±8 m/s'),
            const SizedBox(height: 4),
            AspectRatio(
              aspectRatio: 2.4,
              child: CustomPaint(painter: _ImagePainter(_waterfall)),
            ),
            const SizedBox(height: 10),
            _section('CHEST MOTION  ·  last 16 s'),
            const SizedBox(height: 4),
            SizedBox(
              height: 44,
              child: CustomPaint(
                painter: _TracePainter(
                    t.still ? t.processor.breathingTrace(256) : Float64List(0),
                    color),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Classified from the radar returns only: body size (radar '
              'cross-section, corrected for range and detected walls), limb '
              'motion (micro-Doppler), gait rhythm and breathing. Class models '
              'were fitted on simulated targets; real hardware needs '
              'calibration with recorded data.',
              style: TextStyle(color: kDim, fontSize: 10, height: 1.35),
            ),
          ],
        );
      },
    );
  }

  Widget _section(String s) => Text(s,
      style: const TextStyle(color: kPhosphor, fontSize: 10, letterSpacing: 2));

  Widget _grid(List<(String, String)> items) => Wrap(
        runSpacing: 4,
        children: [
          for (final it in items)
            SizedBox(
              width: 150,
              child: Row(
                children: [
                  SizedBox(
                      width: 70,
                      child: Text(it.$1,
                          style: const TextStyle(color: kDim, fontSize: 10))),
                  Expanded(
                    child: Text(it.$2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Color(0xFFD8FFD0), fontSize: 11)),
                  ),
                ],
              ),
            ),
        ],
      );
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'NO TARGETS\n\nTracks start when the sweep sees something move. '
            'Add a person, dog, cat or fan on the floor plan.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kDim, fontSize: 12, height: 1.5),
          ),
        ),
      );
}

class _Bar extends StatelessWidget {
  const _Bar(this.label, this.p, this.color);
  final String label;
  final double p;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
                width: 80,
                child: Text(label,
                    style: const TextStyle(color: kDim, fontSize: 10))),
            Expanded(
              child: Stack(
                children: [
                  Container(height: 8, color: const Color(0xFF0F1F0F)),
                  FractionallySizedBox(
                    widthFactor: p.clamp(0.0, 1.0).toDouble(),
                    child: Container(height: 8, color: color),
                  ),
                ],
              ),
            ),
            SizedBox(
                width: 40,
                child: Text('${(p * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: color, fontSize: 10))),
          ],
        ),
      );
}

class _ImagePainter extends CustomPainter {
  _ImagePainter(this.img);
  final ui.Image? img;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = const Color(0xFF010201));
    final i = img;
    if (i != null) {
      canvas.drawImageRect(
          i,
          Rect.fromLTWH(0, 0, i.width.toDouble(), i.height.toDouble()),
          r,
          Paint()..filterQuality = FilterQuality.low);
    }
    final mid = Paint()..color = kPhosphor.withOpacity(0.25);
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), mid);
    canvas.drawRect(
        r,
        Paint()
          ..color = kPhosphor.withOpacity(0.4)
          ..style = PaintingStyle.stroke);
    paintLabel(canvas, '+8', const Offset(3, 2), kDim, size: 8);
    paintLabel(canvas, '0', Offset(3, size.height / 2 - 10), kDim, size: 8);
    paintLabel(canvas, '-8 m/s', Offset(3, size.height - 12), kDim, size: 8);
  }

  @override
  bool shouldRepaint(covariant _ImagePainter old) => old.img != img;
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.v, this.color);
  final Float64List v;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = const Color(0xFF010201));
    canvas.drawRect(
        r,
        Paint()
          ..color = kPhosphor.withOpacity(0.4)
          ..style = PaintingStyle.stroke);
    if (v.length < 8) {
      paintLabel(canvas, 'available when the target is still',
          Offset(6, size.height / 2 - 6), kDim,
          size: 9);
      return;
    }
    double mx = 1e-12;
    for (final x in v) {
      mx = math.max(mx, x.abs());
    }
    final path = Path();
    for (int i = 0; i < v.length; i++) {
      final x = i / (v.length - 1) * size.width;
      final y = size.height / 2 - v[i] / mx * size.height * 0.42;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
  }

  @override
  bool shouldRepaint(covariant _TracePainter old) => true;
}

