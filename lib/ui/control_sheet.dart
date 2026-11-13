import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'theme.dart';

void showControlSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kSurface,
    builder: (_) => const ControlSheet(),
  );
}

class ControlSheet extends ConsumerWidget {
  const ControlSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);

    Widget slider(String label, String value, double v, double min, double max,
        void Function(double) onChanged) {
      return Row(
        children: [
          SizedBox(
              width: 104,
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: kDim))),
          Expanded(
            child: Slider(
                value: v.clamp(min, max).toDouble(),
                min: min,
                max: max,
                onChanged: onChanged),
          ),
          SizedBox(
              width: 72,
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12, color: kPhosphor))),
        ],
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('CONTROLS',
                      style: TextStyle(
                          color: kPhosphor, fontSize: 14, letterSpacing: 2)),
                  const Spacer(),
                  IconButton(
                    tooltip: s.playing ? 'Pause animation' : 'Play animation',
                    icon: Icon(s.playing
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline),
                    color: kPhosphor,
                    iconSize: 32,
                    onPressed: () => n.update(s.copyWith(playing: !s.playing)),
                  ),
                ],
              ),
              slider('Sweep rate', '${s.sweepRate.toStringAsFixed(2)} rev/s',
                  s.sweepRate, 0.1, 2.0, (v) => n.update(s.copyWith(sweepRate: v))),
              slider('Range window', '${s.maxRange.toStringAsFixed(0)} m',
                  s.maxRange, 4, 16,
                  (v) => n.update(s.copyWith(maxRange: v.roundToDouble()))),
              slider('Noise level', '${(s.noise * 100).round()} %', s.noise, 0,
                  1, (v) => n.update(s.copyWith(noise: v))),
              slider(
                  'Walking speed',
                  '${s.personSpeed.toStringAsFixed(1)} m/s',
                  s.personSpeed,
                  0,
                  2,
                  (v) => n.update(s.copyWith(personSpeed: v))),
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(
                      width: 104,
                      child: Text('Trajectory',
                          style: TextStyle(fontSize: 12, color: kDim))),
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final m in const [
                          (3, 'Natural'),
                          (0, 'Circle'),
                          (1, 'Patrol'),
                          (2, 'Wander'),
                        ])
                          ChoiceChip(
                            label: Text(m.$2,
                                style: const TextStyle(fontSize: 12)),
                            selected: s.trajectory == m.$1,
                            onSelected: (_) =>
                                n.update(s.copyWith(trajectory: m.$1)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const SizedBox(
                      width: 104,
                      child: Text('Colormap',
                          style: TextStyle(fontSize: 12, color: kDim))),
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (int i = 0; i < kColormapNames.length; i++)
                          ChoiceChip(
                            label: Text(kColormapNames[i],
                                style: const TextStyle(fontSize: 12)),
                            selected: s.colormap == i,
                            onSelected: (_) =>
                                n.update(s.copyWith(colormap: i)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('AI overlay (labelled boxes)',
                    style: TextStyle(fontSize: 13)),
                value: s.aiOverlay,
                onChanged: (v) => n.update(s.copyWith(aiOverlay: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Ghosted floor plan (20 %)',
                    style: TextStyle(fontSize: 13)),
                value: s.ghostPlan,
                onChanged: (v) => n.update(s.copyWith(ghostPlan: v)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
