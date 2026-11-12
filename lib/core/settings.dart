import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RadarMode { sim, csi, sdr }

class AppSettings {
  const AppSettings({
    this.mode = RadarMode.sim,
    this.sweepRate = 0.5,
    this.maxRange = 10,
    this.noise = 0.25,
    this.playing = true,
    this.personSpeed = 0.8,
    this.trajectory = 0,
    this.colormap = 0,
    this.aiOverlay = true,
    this.ghostPlan = true,
    this.csiBannerSeen = false,
  });

  final RadarMode mode;

  /// Antenna revolutions per second.
  final double sweepRate;

  /// Range window in metres.
  final double maxRange;

  /// 0..1, mapped logarithmically to receiver noise sigma.
  final double noise;
  final bool playing;

  /// Person walking speed, m/s.
  final double personSpeed;

  /// 0 circle, 1 back-and-forth, 2 wander.
  final int trajectory;

  /// 0 inferno, 1 phosphor green, 2 amber, 3 grey.
  final int colormap;
  final bool aiOverlay;
  final bool ghostPlan;
  final bool csiBannerSeen;

  AppSettings copyWith({
    RadarMode? mode,
    double? sweepRate,
    double? maxRange,
    double? noise,
    bool? playing,
    double? personSpeed,
    int? trajectory,
    int? colormap,
    bool? aiOverlay,
    bool? ghostPlan,
    bool? csiBannerSeen,
  }) =>
      AppSettings(
        mode: mode ?? this.mode,
        sweepRate: sweepRate ?? this.sweepRate,
        maxRange: maxRange ?? this.maxRange,
        noise: noise ?? this.noise,
        playing: playing ?? this.playing,
        personSpeed: personSpeed ?? this.personSpeed,
        trajectory: trajectory ?? this.trajectory,
        colormap: colormap ?? this.colormap,
        aiOverlay: aiOverlay ?? this.aiOverlay,
        ghostPlan: ghostPlan ?? this.ghostPlan,
        csiBannerSeen: csiBannerSeen ?? this.csiBannerSeen,
      );
}

class SettingsNotifier extends Notifier<AppSettings> {
  SharedPreferences? _prefs;

  @override
  AppSettings build() {
    _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _prefs = p;
      final m = p.getInt('mode') ?? 0;
      state = state.copyWith(
        mode: RadarMode.values[m < 0 || m > 2 ? 0 : m],
        sweepRate: p.getDouble('sweepRate'),
        maxRange: p.getDouble('maxRange'),
        noise: p.getDouble('noise'),
        personSpeed: p.getDouble('personSpeed'),
        trajectory: p.getInt('trajectory'),
        colormap: p.getInt('colormap'),
        aiOverlay: p.getBool('aiOverlay2'),
        ghostPlan: p.getBool('ghostPlan'),
        csiBannerSeen: p.getBool('csiBannerSeen'),
      );
    } catch (_) {
      // Preferences are a convenience; run on defaults if unavailable.
    }
  }

  void update(AppSettings s) {
    state = s;
    final p = _prefs;
    if (p == null) return;
    p.setInt('mode', s.mode.index);
    p.setDouble('sweepRate', s.sweepRate);
    p.setDouble('maxRange', s.maxRange);
    p.setDouble('noise', s.noise);
    p.setDouble('personSpeed', s.personSpeed);
    p.setInt('trajectory', s.trajectory);
    p.setInt('colormap', s.colormap);
    p.setBool('aiOverlay2', s.aiOverlay);
    p.setBool('ghostPlan', s.ghostPlan);
    p.setBool('csiBannerSeen', s.csiBannerSeen);
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
