import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/scene.dart';
import '../core/settings.dart';
import '../core/sim_radar_source.dart';
import '../core/tracker.dart';
import 'control_sheet.dart';
import 'floor_plan_editor.dart';
import 'photo_mode.dart';
import 'ppi_view.dart';
import 'target_panel.dart';
import 'theme.dart';

/// Tier 1: simulated radar PPI, target dossier and editable floor plan.
class SimScreen extends ConsumerStatefulWidget {
  const SimScreen({super.key});

  @override
  ConsumerState<SimScreen> createState() => _SimScreenState();
}

class _SimScreenState extends ConsumerState<SimScreen>
    with TickerProviderStateMixin {
  late final SceneController _scene;
  late final SimRadarSource _radar;
  late final Ticker _ticker;
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final PpiRenderer _renderer = PpiRenderer(size: 360);
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  late final PpiModel _model = PpiModel(_repaint);

  Duration _last = Duration.zero;
  double _fps = 60;
  int _cmapId = -1;
  Uint32List _cmap = buildColormap(0);
  int? _selected;

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

    final tracks = _radar.tracker.tracks;
    if (_selected != null && !tracks.any((t) => t.id == _selected)) {
      _selected = null;
    }
    _model
      ..structure = _radar.structure
      ..tracks = tracks
      ..selectedTrack = _selected ??
          (tracks.where((t) => t.status != TrackStatus.tentative).isEmpty
              ? null
              : tracks.firstWhere((t) => t.status != TrackStatus.tentative).id)
      ..showAi = s.aiOverlay
      ..showGhost = s.ghostPlan
      ..clock = _radar.time
      ..hud = '';

    if (_cmapId != s.colormap) {
      _cmapId = s.colormap;
      _cmap = buildColormap(s.colormap);
    }
    if (!_renderer.busy) {
      _renderer.render(_radar.frame, _cmap, 1.0 / s.sweepRate).then((img) {
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

  void _tapPpi(TapUpDetails d) {
    final p = (d.localPosition - _model.centre) / _model.scale;
    Track? best;
    double bd = 1.5;
    for (final t in _radar.tracker.tracks) {
      final dist = math.sqrt((t.x - p.dx) * (t.x - p.dx) + (t.y - p.dy) * (t.y - p.dy));
      if (dist < bd) {
        bd = dist;
        best = t;
      }
    }
    if (best != null) {
      setState(() => _selected = best!.id);
      _tabs.animateTo(1);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tabs.dispose();
    _radar.dispose();
    _model.image?.dispose();
    _model.image = null;
    _repaint.dispose();
    super.dispose();
  }

  Widget _statusBar() {
    return ValueListenableBuilder<int>(
      valueListenable: _repaint,
      builder: (context, _, __) {
        final s = ref.read(settingsProvider);
        final n = _radar.tracker.tracks
            .where((t) => t.status != TrackStatus.tentative)
            .length;
        final blink = (_radar.time * 2).floor().isEven;
        return Container(
          height: 22,
          color: kPanel,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: blink ? kAlert : kAlert.withOpacity(0.25)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'SIMULATION · 2.40 GHz FMCW · SWEEP ${s.sweepRate.toStringAsFixed(1)} rps · '
                  'DWELL 256 Hz MONOPULSE · TRACKS $n · ${_fps.round()} fps',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: kPhosphor, fontSize: 10, letterSpacing: 1),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ppi = Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTapUp: _tapPpi,
            child: RepaintBoundary(
              child: CustomPaint(painter: PpiPainter(_model)),
            ),
          ),
        ),
        const Positioned.fill(
          child: IgnorePointer(
              child: CustomPaint(painter: ScanlinePainter())),
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
          // Re-illuminate where the body was and where it is now, so the
          // radar image follows the finger instead of the sweep.
          _radar.illuminate(oldX, oldY);
          _radar.illuminate(p.x, p.y);
        },
        onPersonReleased: _radar.reanchor,
      ),
    );
    final dossier = TargetPanel(
      tracks: () => _radar.tracker.tracks,
      selected: () => _model.selectedTrack,
      onSelect: (id) => setState(() => _selected = id),
      repaint: _repaint,
    );

    return Column(
      children: [
        _statusBar(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth > box.maxHeight * 1.2;
              if (wide) {
                return Row(
                  children: [
                    Expanded(flex: 5, child: ppi),
                    Expanded(
                        flex: 3,
                        child: _framed('TARGET DOSSIER', dossier)),
                    Expanded(flex: 3, child: _framed('FLOOR PLAN', editor)),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(flex: 5, child: ppi),
                  Container(
                    color: kPanel,
                    child: TabBar(
                      controller: _tabs,
                      labelColor: kPhosphor,
                      unselectedLabelColor: kDim,
                      indicatorColor: kPhosphor,
                      labelStyle:
                          const TextStyle(fontSize: 11, letterSpacing: 2),
                      tabs: const [
                        Tab(height: 30, text: 'FLOOR PLAN'),
                        Tab(height: 30, text: 'TARGETS'),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: TabBarView(
                      controller: _tabs,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [editor, dossier],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _framed(String title, Widget child) => Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF1E3A1E)),
          color: kSurface,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: kPanel,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(title,
                  style: const TextStyle(
                      color: kPhosphor, fontSize: 10, letterSpacing: 2)),
            ),
            Expanded(child: child),
          ],
        ),
      );
}
