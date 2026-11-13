import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/settings.dart';
import 'ui/csi_screen.dart';
import 'ui/sdr_screen.dart';
import 'ui/sim_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const ProviderScope(child: DarkSightApp()));
}

class DarkSightApp extends StatelessWidget {
  const DarkSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DarkSight',
      debugShowCheckedModeBanner: false,
      theme: darkSightTheme(),
      darkTheme: darkSightTheme(),
      themeMode: ThemeMode.dark,
      home: const HomeShell(),
    );
  }
}

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.mode));
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        titleSpacing: 12,
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('DARKSIGHT',
              style: TextStyle(letterSpacing: 4, fontSize: 16)),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<RadarMode>(
              // Compact enough for a 320 px wide phone.
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 10)),
              ),
              segments: const [
                ButtonSegment(value: RadarMode.sim, label: Text('SIM')),
                ButtonSegment(value: RadarMode.csi, label: Text('CSI')),
                ButtonSegment(value: RadarMode.sdr, label: Text('SDR')),
              ],
              selected: {mode},
              onSelectionChanged: (sel) {
                final n = ref.read(settingsProvider.notifier);
                n.update(ref.read(settingsProvider).copyWith(mode: sel.first));
              },
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: switch (mode) {
          RadarMode.sim => const SimScreen(),
          RadarMode.csi => const CsiScreen(),
          RadarMode.sdr => const SdrScreen(),
        },
      ),
    );
  }
}
