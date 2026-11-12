import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/csi_radar_source.dart';
import '../core/settings.dart';
import '../dsp/motion_detector.dart';
import 'theme.dart';

const String kCsiLimitations =
    'This mode detects presence and motion only. It cannot produce an image '
    'of the person. For imaging, use Tier 3.';

/// Tier 2: Wi-Fi presence/motion view.
class CsiScreen extends ConsumerStatefulWidget {
  const CsiScreen({super.key});

  @override
  ConsumerState<CsiScreen> createState() => _CsiScreenState();
}

class _CsiScreenState extends ConsumerState<CsiScreen>
    with SingleTickerProviderStateMixin {
  final CsiRadarSource _source = CsiRadarSource();
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _source.start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowBanner());
  }

  void _maybeShowBanner() {
    if (!mounted) return;
    final s = ref.read(settingsProvider);
    if (s.csiBannerSeen) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Wi-Fi sensing limits',
            style: TextStyle(color: kAmber)),
        content: const Text(kCsiLimitations),
        actions: [
          TextButton(
            onPressed: () {
              ref
                  .read(settingsProvider.notifier)
                  .update(ref.read(settingsProvider).copyWith(csiBannerSeen: true));
              Navigator.of(ctx).pop();
            },
            child: const Text('UNDERSTOOD'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_source, _pulse]),
      builder: (context, _) {
        final det = _source.detector;
        final moving = det.state == MotionState.motion;
        final trend = switch (det.trend) {
          MotionTrend.approaching => 'LEVEL RISING (approaching?)',
          MotionTrend.receding => 'LEVEL FALLING (receding?)',
          MotionTrend.none => '-',
        };
        final sourceNote = switch (_source.input) {
          CsiInput.probing => 'Looking for a Wi-Fi signal source...',
          CsiInput.rssi =>
            'Live RSSI from the connected access point (coarse fallback). '
                'Raw CSI is not available on this device.',
          CsiInput.simulated =>
            'SIMULATED DATA. No Wi-Fi RSSI on this platform or Wi-Fi is off. '
                'Real sensing needs Android with Wi-Fi connected.',
        };
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: kPanel,
                  border: Border.all(
                      color: _source.input == CsiInput.simulated
                          ? kAmber
                          : const Color(0xFF1E3A1E)),
                ),
                child: Text('[${_source.label}]  $sourceNote',
                    style: TextStyle(
                        fontSize: 11,
                        color: _source.input == CsiInput.simulated
                            ? kAmber
                            : kDim)),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    // Single-column heatmap: residual energy over time,
                    // newest at the top.
                    SizedBox(
                      width: 64,
                      child: CustomPaint(
                        painter: _ColumnPainter(_source),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Motion indicator: pulses while someone moves.
                          Container(
                            width: 120,
                            height: 120,
                            alignment: Alignment.center,
                            child: Container(
                              width: moving ? 60 + 50 * _pulse.value : 36.0,
                              height: moving ? 60 + 50 * _pulse.value : 36.0,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: moving
                                    ? kPhosphor.withOpacity(
                                        0.55 + 0.45 * (1 - _pulse.value))
                                    : const Color(0xFF173017),
                                boxShadow: moving
                                    ? [
                                        BoxShadow(
                                            color: kPhosphor.withOpacity(0.5),
                                            blurRadius: 30,
                                            spreadRadius: 4)
                                      ]
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(moving ? 'MOTION DETECTED' : 'STILL',
                              style: TextStyle(
                                  fontSize: 22,
                                  letterSpacing: 2,
                                  color: moving ? kPhosphor : kDim)),
                          const SizedBox(height: 6),
                          Text(
                              _source.present
                                  ? 'PERSON PRESENT (heuristic)'
                                  : 'ROOM APPEARS EMPTY (heuristic)',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: _source.present ? kAmber : kDim)),
                          const SizedBox(height: 18),
                          _kv('Level',
                              '${_source.lastRssi.toStringAsFixed(1)} dBm'),
                          _kv('Residual energy',
                              '${det.energy.toStringAsFixed(2)} dB²'),
                          _kv('Threshold',
                              '${det.threshold.toStringAsFixed(2)} dB²'),
                          _kv('Trend', trend),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text(kCsiLimitations,
                  style: TextStyle(fontSize: 11, color: kDim)),
            ],
          ),
        );
      },
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
                child: Text(k,
                    style: const TextStyle(fontSize: 12, color: kDim))),
            Text(v, style: const TextStyle(fontSize: 12, color: kPhosphor)),
          ],
        ),
      );
}

class _ColumnPainter extends CustomPainter {
  _ColumnPainter(this.source) : super(repaint: source);
  final CsiRadarSource source;
  static final _cmap = buildColormap(0);

  @override
  void paint(Canvas canvas, Size size) {
    const n = CsiRadarSource.historyLength;
    final h = size.height / n;
    final paint = Paint();
    canvas.drawRect(Offset.zero & size, paint..color = const Color(0xFF010201));
    for (int i = 0; i < source.samples; i++) {
      final idx = (source.head - 1 - i + 2 * n) % n;
      // Log-compress energy: 0.02 dB² -> 0, 20 dB² -> 1.
      final e = source.energyHistory[idx];
      double v = (math.log(e + 1e-6) / math.ln10 + 1.7) / 3.0;
      v = v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
      final c = _cmap[(v * 255).toInt()];
      paint.color = Color.fromARGB(
          255, c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF);
      canvas.drawRect(Rect.fromLTWH(0, i * h, size.width, h + 0.5), paint);
    }
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..color = kPhosphor.withOpacity(0.5)
          ..style = PaintingStyle.stroke);
    paintLabel(canvas, 'now', const Offset(4, 2), kPhosphor, size: 9);
    paintLabel(canvas, '-30 s', Offset(4, size.height - 14), kPhosphor,
        size: 9);
  }

  @override
  bool shouldRepaint(covariant _ColumnPainter oldDelegate) => false;
}
