import 'dart:math' as math;
import 'dart:typed_data';

/// Parameters of the simulated 2.4 GHz FMCW radar. Shared by the simulator
/// (which plays the role of the hardware) and the processing chain.
class Radar {
  static const double lambda = 0.125; // m, 2.4 GHz carrier
  static const int samples = 256; // ADC samples per chirp
  static const int bins = 200; // range bins displayed (of samples)
  static const double prf = 256; // track-dwell chirp rate, Hz
  static const double gain = 4; // system gain: amplitude = G sqrt(rcs) / r^2

  /// Two-way beam: amplitude gain exp(-d^2 / 2 sigma^2).
  static const double beamSigma = 1.4 * math.pi / 180;

  /// Monopulse: two receive lobes squinted +/- this angle.
  static const double squint = 1.0 * math.pi / 180;

  /// Range gate (bins) processed around each track.
  static const int gate = 15;

  /// Slow-time FFT length and hop for the micro-Doppler spectrogram.
  static const int nDoppler = 64;
  static const int hop = 8;
  static const double columnRate = prf / hop; // 32 columns / s
  static const double velocityRes = lambda / 2 * prf / nDoppler; // 0.25 m/s

  /// Wall transmission, two-way amplitude factor per wall crossed.
  static const double wallLoss = 0.5;

  /// Receiver noise sigma (per I/Q component, per ADC sample) for the
  /// UI noise slider value 0..1.
  static double noiseSigma(double noise) =>
      0.01 * math.pow(10, 2 * noise).toDouble();

  /// The same noise after the Hann-windowed, (N/2)-normalised range FFT.
  static double noisePerBin(double noise) =>
      noiseSigma(noise) * math.sqrt(3 * samples / 8) / (samples / 2);

  /// Boresight gain of each monopulse lobe.
  static final double lobeGain =
      math.exp(-squint * squint / (2 * beamSigma * beamSigma));
}

/// Response of bin k of the Hann-windowed range FFT to a unit tone at
/// fractional bin k + delta, normalised so an on-bin tone gives 1.
///
/// Closed form of the windowed DFT (the same thing the FFT computes), so the
/// track dwell can synthesise a 15-bin range gate per chirp without running
/// a 256-point FFT. Tabulated at 1/32-bin steps with linear interpolation.
class HannResponse {
  static const double span = 9; // bins either side
  static const int perBin = 32;
  static final int _n = (2 * span * perBin).round() + 1;
  static final Float64List _re = Float64List(_n);
  static final Float64List _im = Float64List(_n);
  static bool _built = false;

  static void _build() {
    const n = Radar.samples;
    final alpha = 2 * math.pi / (n - 1);
    // Sum_{m=0}^{n-1} e^{j w m}
    void dir(double w, List<double> out) {
      final s = math.sin(w / 2);
      double mag;
      if (s.abs() < 1e-9) {
        mag = n.toDouble();
      } else {
        mag = math.sin(n * w / 2) / s;
      }
      final ph = w * (n - 1) / 2;
      out[0] = mag * math.cos(ph);
      out[1] = mag * math.sin(ph);
    }

    final a = [0.0, 0.0], b = [0.0, 0.0], c = [0.0, 0.0];
    for (int i = 0; i < _n; i++) {
      final delta = -span + i / perBin;
      final w = 2 * math.pi * delta / n;
      dir(w, a);
      dir(w + alpha, b);
      dir(w - alpha, c);
      _re[i] = (0.5 * a[0] - 0.25 * b[0] - 0.25 * c[0]) / (n / 2);
      _im[i] = (0.5 * a[1] - 0.25 * b[1] - 0.25 * c[1]) / (n / 2);
    }
    _built = true;
  }

  /// Writes (re, im) of the response at [delta] into [out]; returns false
  /// (and writes zeros) when |delta| is outside the table.
  static bool at(double delta, Float64List out) {
    if (!_built) _build();
    final x = (delta + span) * perBin;
    if (x < 0 || x >= _n - 1) {
      out[0] = 0;
      out[1] = 0;
      return false;
    }
    final i = x.floor();
    final f = x - i;
    out[0] = _re[i] + (_re[i + 1] - _re[i]) * f;
    out[1] = _im[i] + (_im[i + 1] - _im[i]) * f;
    return true;
  }

  /// Sum of |response|^2 over a gate of [Radar.gate] bins centred on the
  /// tone: converts measured gate power to tone amplitude^2.
  static double gatePowerFactor() {
    final o = Float64List(2);
    double s = 0;
    for (int k = -(Radar.gate ~/ 2); k <= Radar.gate ~/ 2; k++) {
      at(k.toDouble(), o);
      s += o[0] * o[0] + o[1] * o[1];
    }
    return s;
  }
}
