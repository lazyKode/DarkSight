import 'dart:math' as math;

/// Kinds of moving thing the simulator can animate.
enum BodyKind { human, dog, cat, fan }

/// Physical description of one simulated individual.
///
/// Every instance gets its own size, gait and breathing drawn around a
/// population mean, so the classifier never sees two identical targets.
/// The numbers are biomechanics ballparks, not measurements of any animal:
///   radar cross-section (m^2): adult ~0.5-1, dog ~0.1-0.3, cat ~0.02-0.05
///   leg cycle frequency rises with speed and falls with leg length
///   resting breathing: adult 12-20 /min, dog 18-34, cat 20-36
class BodyParams {
  BodyParams(this.kind, int seed) {
    final rng = math.Random(seed);
    double j([double s = 0.12]) => 1 + _gauss(rng) * s;
    double u(double a, double b) => a + rng.nextDouble() * (b - a);
    phase0 = rng.nextDouble() * 2 * math.pi;
    switch (kind) {
      case BodyKind.human:
        rcs = 0.8 * math.pow(j(0.35), 2).toDouble();
        legF0 = 0.55 * j();
        legFk = 0.35 * j();
        legA = 0.28 * j();
        armA = 0.2 * j();
        breathHz = u(12, 20) / 60;
        chest = 0.004 * j(0.3);
        parts = const [
          _Part(_P.torso, 0, 0, 0, 0.6),
          _Part(_P.arm, 0, 0.2, 0, 0.18),
          _Part(_P.arm, math.pi, -0.2, 0, 0.18),
          _Part(_P.leg, math.pi, 0.1, 0, 0.22),
          _Part(_P.leg, 0, -0.1, 0, 0.22),
        ];
        break;
      case BodyKind.dog:
        rcs = 0.15 * math.pow(j(0.4), 2).toDouble();
        legF0 = 1.2 * j();
        legFk = 0.9 * j();
        legA = 0.12 * j();
        breathHz = u(18, 34) / 60;
        chest = 0.002 * j(0.3);
        cruise = u(0.7, 1.8);
        parts = const [
          _Part(_P.torso, 0, 0, 0, 0.7),
          _Part(_P.leg, 0, 0.08, 0.25, 0.13),
          _Part(_P.leg, math.pi, -0.08, 0.25, 0.13),
          _Part(_P.leg, math.pi, 0.08, -0.25, 0.13),
          _Part(_P.leg, 0, -0.08, -0.25, 0.13),
        ];
        break;
      case BodyKind.cat:
        rcs = 0.03 * math.pow(j(0.4), 2).toDouble();
        legF0 = 1.8 * j();
        legFk = 1.0 * j();
        legA = 0.07 * j();
        breathHz = u(20, 36) / 60;
        chest = 0.0012 * j(0.3);
        cruise = u(0.4, 1.2);
        parts = const [
          _Part(_P.torso, 0, 0, 0, 0.7),
          _Part(_P.leg, 0, 0.05, 0.12, 0.13),
          _Part(_P.leg, math.pi, -0.05, 0.12, 0.13),
          _Part(_P.leg, math.pi, 0.05, -0.12, 0.13),
          _Part(_P.leg, 0, -0.05, -0.12, 0.13),
        ];
        break;
      case BodyKind.fan:
        rcs = 0.3 * math.pow(j(0.4), 2).toDouble();
        rps = u(2.0, 4.5);
        bladeR = 0.2 * j();
        parts = const [];
        break;
    }
  }

  final BodyKind kind;
  double rcs = 1;
  double legF0 = 0, legFk = 0, legA = 0, armA = 0;
  double breathHz = 0.25, chest = 0;
  double rps = 0, bladeR = 0;
  double cruise = 1;
  double phase0 = 0;
  List<_Part> parts = const [];

  static double _gauss(math.Random r) {
    final u1 = r.nextDouble() + 1e-12, u2 = r.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// Leg cycle frequency (Hz) at a given ground speed.
  double legFreq(double speed) =>
      kind == BodyKind.fan ? 0 : legF0 + legFk * math.min(speed, 1.8);

  /// Typical walking speed for an animal, m/s.
  double get cruiseSpeed => cruise;
}

enum _P { torso, arm, leg }

class _Part {
  const _Part(this.type, this.phase, this.w, this.u0, this.frac);
  final _P type;
  final double phase; // gait phase offset
  final double w; // lateral offset, m
  final double u0; // fore-aft offset, m
  final double frac; // share of the body's RCS
}

/// Writes a body's point scatterers at time [t] into the output lists:
/// world x, y, amplitude before path loss (G * sqrt(rcs share)), and a
/// common range offset (breathing). Returns the number written.
int emitScatterers(
  BodyParams b,
  double t,
  double x,
  double y,
  double heading,
  double speed,
  double gait,
  double gain,
  List<double> outX,
  List<double> outY,
  List<double> outA,
) {
  final a0 = gain * math.sqrt(b.rcs);
  if (b.kind == BodyKind.fan) {
    outX.add(x);
    outY.add(y);
    outA.add(a0 * 0.5);
    for (int k = 0; k < 3; k++) {
      final th = 2 * math.pi * b.rps * t + 2 * math.pi * k / 3 + b.phase0;
      outX.add(x + b.bladeR * math.cos(th));
      outY.add(y + b.bladeR * math.sin(th));
      outA.add(a0 * 0.35);
    }
    return 4;
  }
  final ch = math.cos(heading), sh = math.sin(heading);
  final v = math.min(speed, 1.8);
  for (final p in b.parts) {
    double u = p.u0;
    if (p.type == _P.arm) u += b.armA * v * math.sin(gait + p.phase);
    if (p.type == _P.leg) u += b.legA * v * math.sin(gait + p.phase);
    outX.add(x + u * ch - p.w * sh);
    outY.add(y + u * sh + p.w * ch);
    outA.add(a0 * math.sqrt(p.frac));
  }
  return b.parts.length;
}

/// Breathing displacement of the body surface toward the radar, metres.
double breathingOffset(BodyParams b, double t) => b.kind == BodyKind.fan
    ? 0
    : b.chest * math.sin(2 * math.pi * b.breathHz * t + b.phase0);
