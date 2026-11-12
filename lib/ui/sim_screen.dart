import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/scene.dart';
import '../core/settings.dart';
import '../core/sim_radar_source.dart';
import '../ml/detector.dart';
import 'control_sheet.dart';
import 'floor_plan_editor.dart';
import 'photo_mode.dart';
import 'ppi_view.dart';
import 'theme.dart';

/// Tier 1: simulated radar PPI next to an editable floor plan.
class SimScreen extends ConsumerStatefulWidget {
  const SimScreen({super.key});

  @override
  ConsumerState<SimScreen> createState() => _SimScreenState();
}

class _SimScreenState extends ConsumerState<SimScreen>
    with SingleTickerProviderStateMixin {
  late final SceneController _scene;
  late final SimRadarSource _radar;
  late final Ticker _ticker;
  final PpiRenderer _renderer = PpiRenderer(size: 360);
  final RadarDetector _detector = RadarDetector();
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  late final PpiModel _model = PpiModel(_repaint);

  Duration _last = Duration.zero;
  double _fps = 60;
  double _sinceDetect = 1;
  bool _aiWasOn = false;
  int _cmapId = -1;
  Uint32List _cmap = buildColormap(0);

  @override
  void initState() {
    super.initState();
    _scene = ref.read(sceneProvider);
    _radar = SimRadarSource(_scene);
    _model.scene = _scene;
    _model.frame = _radar.frame;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (dt <= 0 || dt > 1) return;
    final s = ref.read(settingsProvider);

    _radar
      ..sweepRate = s.sweepRate
      ..maxRange = s.maxRange
      ..noise = s.noise
      ..playing = s.playing
      ..personSpeed = s.personSpeed
      ..trajectory = s.trajectory;
    _radar.tick(dt);
    _fps += (1 / dt - _fps) * 0.05;

    // Detector: immediately when switched on, then five times a second.
    _sinceDetect += dt;
    if (s.aiOverlay && (!_aiWasOn || _sinceDetect >= 0.2)) {
      _model.detections = _detector.detect(_radar.frame);
      _sinceDetect = 0;
    }
    _aiWasOn = s.aiOverlay;
    _model.showAi = s.aiOverlay;
    _model.showGhost = s.ghostPlan;
    _model.hud = 'SIM  ${_fps.toStringAsFixed(0)} fps  '
        '${_radar.staticScattererCount} scatterers';

    if (_cmapId != s.colormap) {
      _cmapId = s.colormap;
      _cmap = buildColormap(s.colormap);
    }
    if (!_renderer.busy) {
      _renderer
          .render(_radar.frame, _cmap, 1.0 / s.sweepRate)
          .then((img) {
        if (img == null) return;
        if (!mounted) {
          img.dispose();
          return;
        }
        final old = _model.image;
        _model.image = img;
        old?.dispose();
        _repaint.value++;
      });
    }
    _repaint.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _radar.dispose();
    _model.image?.dispose();
    _model.image = null;
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ppi = Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: PpiPainter(_model)),
          ),
        ),
        Positioned(
          right: 6,
          bottom: 6,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton.small(
                heroTag: 'photo',
                tooltip: 'Photo mode',
                backgroundColor: kPanel,
                foregroundColor: kPhosphor,
                onPressed: () => PhotoMode.show(context, _radar.frame),
                child: const Icon(Icons.camera_alt_outlined),
              ),
              const SizedBox(width: 8),
              FloatingActionButton.small(
                heroTag: 'controls',
                tooltip: 'Controls',
                backgroundColor: kPanel,
                foregroundColor: kPhosphor,
                onPressed: () => showControlSheet(context),
                child: const Icon(Icons.tune),
              ),
            ],
          ),
        ),
      ],
    );
    final editor = RepaintBoundary(
      child: FloorPlanEditor(
        scene: _scene,
        repaint: _repaint,
        onPersonMoved: (p, oldX, oldY) {
          // Re-illuminate where the person was and where they are now, so
          // the radar image follows the finger instead of the sweep.
          _radar.illuminate(oldX, oldY);
          _radar.illuminate(p.x, p.y);
        },
        onPersonReleased: _radar.reanchor,
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > box.maxHeight;
        final children = [
          Expanded(flex: 5, child: ppi),
          Expanded(flex: 4, child: editor),
        ];
        return wide ? Row(children: children) : Column(children: children);
      },
    );
  }
}
