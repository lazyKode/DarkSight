import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

/// Geometry of one FMCW frame (a "radar cube").
class FmcwConfig {
  const FmcwConfig({
    this.samples = 64,
    this.chirps = 32,
    this.rx = 4,
    this.angleBins = 32,
    this.maxRange = 10,
    this.maxVelocity = 4,
  });

  final int samples; // per chirp (fast time)  -> range bins
  final int chirps; // per frame (slow time)  -> Doppler bins
  final int rx; // receive channels, lambda/2 spacing (virtual array)
  final int angleBins; // zero-padded angle FFT size
  final double maxRange; // m
  final double maxVelocity; // m/s, unambiguous +/-

  double get rangeRes => maxRange / samples;
  double get velocityRes => 2 * maxVelocity / chirps;
  int get cubeLength => rx * chirps * samples;
}

/// One CFAR detection.
class RadarPoint {
  const RadarPoint(this.range, this.angle, this.velocity, this.power);
  final double range; // m
  final double angle; // rad, 0 = boresight, + to the right
  final double velocity; // m/s, + receding
  final double power; // 0..1 log scale
  double get x => range * math.sin(angle);
  double get y => range * math.cos(angle);
}

/// Pure-Dart reference implementation of the Tier 3 DSP chain:
///   1. range FFT per chirp      2. Doppler FFT across chirps
///   3. CA-CFAR detection        4. angle FFT across the (virtual) array
///   5. (range, angle, Doppler) tuples + range-Doppler and range-angle maps
///
/// native/dsp_core implements the same steps in C++ for FFI; this version is
/// what runs by default so the app needs no NDK toolchain to build.
///
/// Cube layout: index = (rx * chirps + chirp) * samples + sample.
class FmcwPipeline {
  FmcwPipeline(this.cfg)
      : _fftR = Fft(cfg.samples),
        _fftD = Fft(cfg.chirps),
        _fftA = Fft(cfg.angleBins),
        _dRe = Float32List(cfg.cubeLength),
        _dIm = Float32List(cfg.cubeLength),
        rangeDoppler = Float32List(cfg.samples * cfg.chirps),
        rangeAngle = Float32List(cfg.samples * cfg.angleBins);

  final FmcwConfig cfg;
  final Fft _fftR, _fftD, _fftA;
  final Float32List _dRe, _dIm; // [(rx * samples + k) * chirps + d]

  /// [k * chirps + d], log scale 0..1, Doppler fft-shifted (centre = 0 m/s).
  final Float32List rangeDoppler;

  /// [k * angleBins + a], log scale 0..1, angle fft-shifted (centre = 0 rad).
  final Float32List rangeAngle;

  List<RadarPoint> points = const [];

  static double _logScale(double p) {
    final v = (4.342944819 * math.log(p + 1e-12) + 60) / 60;
    return v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
  }

  void process(Float32List re, Float32List im) {
    final ns = cfg.samples, nc = cfg.chirps, nrx = cfg.rx, na = cfg.angleBins;
    final tr = Float64List(ns), ti = Float64List(ns);
    final cr = Float64List(nc), ci = Float64List(nc);
    final rRe = Float32List(cfg.cubeLength), rIm = Float32List(cfg.cubeLength);

    // 1. Range FFT.
    for (int c = 0; c < nrx * nc; c++) {
      final o = c * ns;
      for (int n = 0; n < ns; n++) {
        tr[n] = re[o + n] * _fftR.hann[n];
        ti[n] = im[o + n] * _fftR.hann[n];
      }
      _fftR.transform(tr, ti);
      for (int n = 0; n < ns; n++) {
        rRe[o + n] = tr[n];
        rIm[o + n] = ti[n];
      }
    }

    // 2. Doppler FFT, fft-shifted, and non-coherent sum over channels.
    final half = nc ~/ 2;
    final gain = (ns / 2) * (nc / 2);
    final norm = 1 / (gain * gain * nrx);
    final power = Float64List(ns * nc);
    for (int rx = 0; rx < nrx; rx++) {
      for (int k = 0; k < ns; k++) {
        for (int m = 0; m < nc; m++) {
          final i = (rx * nc + m) * ns + k;
          cr[m] = rRe[i] * _fftD.hann[m];
          ci[m] = rIm[i] * _fftD.hann[m];
        }
        _fftD.transform(cr, ci);
        final o = (rx * ns + k) * nc;
        for (int d = 0; d < nc; d++) {
          final s = (d + half) % nc;
          _dRe[o + s] = cr[d];
          _dIm[o + s] = ci[d];
          power[k * nc + s] += cr[d] * cr[d] + ci[d] * ci[d];
        }
      }
    }
    for (int i = 0; i < ns * nc; i++) {
      rangeDoppler[i] = _logScale(power[i] * norm);
    }

    // 3. CA-CFAR along range in each Doppler column, thinned to local maxima.
    // 4. Angle FFT at each detection.
    const guard = 2, train = 6;
    final rd = rangeDoppler;
    final ar = Float64List(na), ai = Float64List(na);
    final aPower = Float64List(ns * na);
    final out = <RadarPoint>[];
    final aNorm = 1 / (gain * gain * nrx * nrx);
    for (int k = 2; k < ns; k++) {
      for (int d = 0; d < nc; d++) {
        final v = rd[k * nc + d];
        if (v < 0.25) continue;
        // Range-angle map accumulates every cell with energy in it.
        for (int a = 0; a < na; a++) {
          ar[a] = 0;
          ai[a] = 0;
        }
        for (int rx = 0; rx < nrx; rx++) {
          ar[rx] = _dRe[(rx * ns + k) * nc + d];
          ai[rx] = _dIm[(rx * ns + k) * nc + d];
        }
        _fftA.transform(ar, ai);
        int best = 0;
        double bestP = -1;
        for (int a = 0; a < na; a++) {
          final p = ar[a] * ar[a] + ai[a] * ai[a];
          final s = (a + na ~/ 2) % na;
          aPower[k * na + s] += p;
          if (p > bestP) {
            bestP = p;
            best = s;
          }
        }

        if (v < 0.32) continue;
        double sum = 0;
        int cnt = 0;
        for (int j = k - guard - train; j <= k + guard + train; j++) {
          if (j < 0 || j >= ns || (j - k).abs() <= guard) continue;
          sum += rd[j * nc + d];
          cnt++;
        }
        // Strong cells pass outright: extended structure fills the
        // training window and would otherwise mask itself.
        if (v < 0.6 && (cnt == 0 || v - sum / cnt < 0.2)) continue;
        final up = k + 1 < ns ? rd[(k + 1) * nc + d] : 0.0;
        final down = rd[(k - 1) * nc + d];
        final left = rd[k * nc + (d + nc - 1) % nc];
        final right = rd[k * nc + (d + 1) % nc];
        if (v < up || v < down || v < left || v < right) continue;

        double sinTheta = (best - na / 2) / (na / 2);
        if (sinTheta > 1) sinTheta = 1;
        if (sinTheta < -1) sinTheta = -1;
        out.add(RadarPoint(
          (k + 0.5) * cfg.rangeRes,
          math.asin(sinTheta),
          (d - half) * cfg.velocityRes,
          v,
        ));
      }
    }
    for (int i = 0; i < ns * na; i++) {
      rangeAngle[i] = _logScale(aPower[i] * aNorm);
    }
    points = out;
  }
}
