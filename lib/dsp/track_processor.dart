import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';
import 'radar_constants.dart';

/// One position/velocity measurement from a block of dwell chirps.
class DwellMeasurement {
  const DwellMeasurement(
      this.range, this.angleOffset, this.radialVelocity, this.excess);
  final double range; // fractional range bin
  final double angleOffset; // rad, target bearing minus dwell boresight
  final double radialVelocity; // m/s, + receding
  final double excess; // gate power over noise, linear (0 = noise only)
}

/// Signature features over the last few seconds of a track.
class SignatureFeatures {
  bool detected = false;
  double span = 0; // micro-Doppler extent, m/s (80th percentile)
  double symmetry = 0; // 1 = evenly spread about 0 m/s (rotating parts)
  double cadence = 0; // Hz, dominant periodicity of the signature
  double cadenceSnr = 0;
  double torsoVelocity = 0; // m/s, median |Doppler of the strongest return|
  double rcsDbsm = double.nan; // estimated radar cross-section, dBsm
  double breathBpm = double.nan;
  double breathSnr = 0;
}

/// Signal processing for one track dwell: receives the two monopulse
/// receive channels over a range gate for every chirp and turns them into
/// measurements (range, angle, Doppler) and signature features.
///
/// Steps, in order:
///  1. Sum/difference channels from the two squinted lobes.
///  2. Clutter map per absolute range bin (exponential average, 2 s):
///     subtracting it removes walls and furniture (MTI).
///  3. Coherent range-gate sum -> one slow-time sample per chirp.
///  4. Every 8 chirps: power-weighted range, amplitude-comparison monopulse
///     angle, pulse-pair Doppler; and one 64-point micro-Doppler column.
///  5. On request: span / symmetry / cadence-velocity diagram / RCS /
///     breathing rate from the stored columns and slow-time history.
///
/// It sees only the channel samples. It never reads the simulated scene.
class TrackProcessor {
  TrackProcessor(this.noise);

  /// UI noise setting (0..1). A real receiver knows its noise floor from
  /// calibration; this is that calibration value.
  double noise;

  static const int g = Radar.gate;
  static const int half = Radar.gate ~/ 2;
  static const int sigHalf = Radar.sigGate ~/ 2;
  static const int nd = Radar.nDoppler;
  static const int maxCols = 400; // 12.5 s of columns
  static const int slowLen = 1024; // chirps kept for the spectrogram (4 s)
  static const int breathLen = 512; // 32 s at 16 Hz

  static const double _clutterTau = 2.0;
  static final double _clutterA =
      1 - math.exp(-1 / (Radar.prf * _clutterTau));

  // Clutter maps (absolute bins, with margin), sum and difference channels.
  static const int _mapLen = Radar.bins + 64;
  final Float64List _cSr = Float64List(_mapLen), _cSi = Float64List(_mapLen);
  final Float64List _cDr = Float64List(_mapLen), _cDi = Float64List(_mapLen);
  final Uint8List _seen = Uint8List(_mapLen);
  double _mapBearing = double.nan;

  // Block accumulators.
  final Float64List _binPow = Float64List(g);
  final Float64List _cross = Float64List(g);
  double _ppRe = 0, _ppIm = 0, _prevRe = 0, _prevIm = 0;
  double _gatePow = 0;
  int _blockN = 0;
  int _blockK0 = 0;

  // Slow-time history of the gate sum.
  final Float64List _gRe = Float64List(slowLen), _gIm = Float64List(slowLen);
  int _gHead = 0, _gCount = 0;
  int chirps = 0;

  // Spectrogram columns and per-column gate power (for RCS).
  final Float32List cols = Float32List(maxCols * nd);
  final Float32List _colPow = Float32List(maxCols);
  final Float32List _colRange = Float32List(maxCols);
  int colHead = 0, colCount = 0;

  // Breathing history at 16 Hz.
  final Float64List _bRe = Float64List(breathLen), _bIm = Float64List(breathLen);
  int _bHead = 0, _bCount = 0;
  double _bAccRe = 0, _bAccIm = 0;
  int _bAccN = 0;

  final Fft _fftD = Fft(nd);
  final Fft _fft512 = Fft(512);
  final Fft _fft2048 = Fft(2048);
  final Float64List _tr = Float64List(nd), _ti = Float64List(nd);

  /// Columns produced in the first 1.5 s are ignored while the clutter map
  /// settles.
  static const int settleCols = 48;

  double get _sigmaN =>
      Radar.noisePerBin(noise) / (math.sqrt2 * Radar.lobeGain);

  /// Expected noise power of one spectrogram (Doppler) bin.
  double get noisePerDopplerBin {
    double w2 = 0;
    for (final w in _fftD.hann) {
      w2 += w * w;
    }
    final s = _sigmaN;
    return 2 * s * s * w2 * Radar.sigGate;
  }

  /// Clears the clutter map, e.g. after the dwell beam jumps.
  void resetClutter() => _seen.fillRange(0, _mapLen, 0);

  /// Feeds one chirp. [lr]/[li] and [rr]/[ri] are the left and right lobe
  /// gate samples (bins k0-7 .. k0+7). Returns a measurement every 8 chirps.
  DwellMeasurement? push(int k0, double bearing, Float64List lr, Float64List li,
      Float64List rr, Float64List ri) {
    if (_mapBearing.isNaN || (bearing - _mapBearing).abs() > 0.035) {
      resetClutter();
      _mapBearing = bearing;
    } else {
      _mapBearing += 0.05 * (bearing - _mapBearing);
    }
    final norm = 1 / (2 * Radar.lobeGain);
    double gRe = 0, gIm = 0;
    if (_blockN == 0) _blockK0 = k0;
    for (int j = 0; j < g; j++) {
      final k = k0 - half + j;
      final m = k + 32;
      final sr = (lr[j] + rr[j]) * norm, si = (li[j] + ri[j]) * norm;
      final dr = (rr[j] - lr[j]) * norm, di = (ri[j] - li[j]) * norm;
      if (m < 0 || m >= _mapLen) continue;
      if (_seen[m] == 0) {
        _cSr[m] = sr;
        _cSi[m] = si;
        _cDr[m] = dr;
        _cDi[m] = di;
        _seen[m] = 1;
      }
      final ysr = sr - _cSr[m], ysi = si - _cSi[m];
      final ydr = dr - _cDr[m], ydi = di - _cDi[m];
      _cSr[m] += _clutterA * ysr;
      _cSi[m] += _clutterA * ysi;
      _cDr[m] += _clutterA * ydr;
      _cDi[m] += _clutterA * ydi;
      final p = ysr * ysr + ysi * ysi;
      // Bins relative to the block's first gate position.
      final jj = k - (_blockK0 - half);
      if (jj >= 0 && jj < g) {
        _binPow[jj] += p;
        _cross[jj] += ydr * ysr + ydi * ysi; // Re(D conj(S))
      }
      if ((j - half).abs() > sigHalf) continue;
      _gatePow += p;
      if ((k & 1) == 0) {
        gRe += ysr;
        gIm += ysi;
      } else {
        gRe -= ysr;
        gIm -= ysi;
      }
    }
    // Slow-time history.
    _gRe[_gHead] = gRe;
    _gIm[_gHead] = gIm;
    _gHead = (_gHead + 1) % slowLen;
    if (_gCount < slowLen) _gCount++;
    chirps++;
    // Pulse-pair Doppler.
    _ppRe += gRe * _prevRe + gIm * _prevIm;
    _ppIm += gIm * _prevRe - gRe * _prevIm;
    _prevRe = gRe;
    _prevIm = gIm;
    // Breathing decimation.
    _bAccRe += gRe;
    _bAccIm += gIm;
    if (++_bAccN == 16) {
      _bRe[_bHead] = _bAccRe / 16;
      _bIm[_bHead] = _bAccIm / 16;
      _bHead = (_bHead + 1) % breathLen;
      if (_bCount < breathLen) _bCount++;
      _bAccRe = _bAccIm = 0;
      _bAccN = 0;
    }
    if (++_blockN < Radar.hop) return null;
    return _finishBlock(k0);
  }

  DwellMeasurement _finishBlock(int k0) {
    final n = _blockN.toDouble();
    final s2 = _sigmaN * _sigmaN * 2; // noise power per bin
    double wSum = 0, kSum = 0, cSum = 0, pSum = 0;
    double best = 0;
    for (int j = 0; j < g; j++) {
      final p = _binPow[j] / n - s2;
      if (p > best) best = p;
    }
    for (int j = 0; j < g; j++) {
      final p = _binPow[j] / n - s2;
      if (p <= best * 0.25 || p <= 0) continue;
      wSum += p;
      kSum += p * (_blockK0 - half + j);
      cSum += _cross[j] / n;
      pSum += _binPow[j] / n;
    }
    final excess = _gatePow / n / (Radar.sigGate * s2) - 1;
    double range = k0 * 1.0, angle = 0;
    if (wSum > 0) {
      range = kSum / wSum;
      final ratio = (cSum / math.max(pSum, 1e-18)).clamp(-0.95, 0.95);
      final atanh = 0.5 * math.log((1 + ratio) / (1 - ratio));
      angle = Radar.dwellSigma * Radar.dwellSigma / Radar.squint * atanh;
    }
    final vr = math.atan2(_ppIm, _ppRe) / (4 * math.pi) * Radar.lambda * Radar.prf;

    // Spectrogram column.
    if (_gCount >= nd) {
      final hann = _fftD.hann;
      for (int i = 0; i < nd; i++) {
        final idx = (_gHead - nd + i + slowLen) % slowLen;
        _tr[i] = _gRe[idx] * hann[i];
        _ti[i] = _gIm[idx] * hann[i];
      }
      _fftD.transform(_tr, _ti);
      final base = colHead * nd;
      for (int d = 0; d < nd; d++) {
        final src = (d + nd ~/ 2) % nd; // fftshift: column index 32 = 0 m/s
        cols[base + d] = (_tr[src] * _tr[src] + _ti[src] * _ti[src]);
      }
      _colPow[colHead] = _gatePow / n;
      _colRange[colHead] = k0.toDouble();
      colHead = (colHead + 1) % maxCols;
      if (colCount < maxCols) colCount++;
    }

    _binPow.fillRange(0, g, 0);
    _cross.fillRange(0, g, 0);
    _gatePow = 0;
    _ppRe = _ppIm = 0;
    _blockN = 0;
    return DwellMeasurement(range, angle, vr, excess);
  }

  /// Column i counted back from the newest (0 = newest), Doppler bin d.
  double column(int i, int d) =>
      cols[((colHead - 1 - i + maxCols) % maxCols) * nd + d];

  /// Signature features over the last [seconds] of valid columns.
  /// [rangeM] and [walls] (walls detected between radar and target) are used
  /// for the RCS estimate.
  SignatureFeatures features(
      {required double rangeM,
      required double maxRange,
      required int walls,
      double seconds = 8.5,
      bool still = false,
      double stillSeconds = 0}) {
    final f = SignatureFeatures();
    final usable = math.min(colCount, (chirps ~/ Radar.hop) - settleCols);
    final n = math.min(usable, (seconds * Radar.columnRate).round());
    if (n < 96) return f;
    final nf = noisePerDopplerBin;
    const vres = Radar.velocityRes;

    // Rows oldest -> newest.
    final s = List<Float64List>.generate(n, (i) {
      final row = Float64List(nd);
      for (int d = 0; d < nd; d++) {
        row[d] = column(n - 1 - i, d);
      }
      return row;
    });

    final spans = <double>[], syms = <double>[], torso = <double>[];
    int active = 0;
    final mean = Float64List(nd);
    for (final row in s) {
      double sum = 0, mx = 0;
      int pk = 0;
      for (int d = 0; d < nd; d++) {
        sum += row[d];
        mean[d] += row[d] / n;
        if (row[d] > mx) {
          mx = row[d];
          pk = d;
        }
      }
      final excess = sum / (nd * nf) - 1;
      if (excess <= 0.6) continue;
      active++;
      double hi = -1e9, lo = 1e9;
      for (int d = 0; d < nd; d++) {
        if (row[d] > nf * 10 && row[d] > mx * 0.0031623) {
          final v = (d - nd / 2) * vres;
          if (v > hi) hi = v;
          if (v < lo) lo = v;
        }
      }
      if (hi < lo) {
        hi = 0;
        lo = 0;
      }
      spans.add(hi - lo);
      final big = math.max(math.max(hi, -lo), vres);
      syms.add(math.min(hi, -lo) / big);
      torso.add(((pk - nd / 2) * vres).abs());
    }
    f.detected = active > 0.5 * n;
    if (!f.detected) return f;
    f.span = _percentile(spans, 80);
    f.symmetry = _percentile(syms, 50);
    f.torsoVelocity = _percentile(torso, 50);

    // Cadence-velocity diagram.
    final lg = List<Float64List>.generate(
        n, (i) => Float64List.fromList(s[i].map((v) => math.log(v + nf)).toList()));
    final hp = List<Float64List>.generate(n, (_) => Float64List(nd));
    for (int d = 0; d < nd; d++) {
      for (int i = 0; i < n; i++) {
        double acc = 0;
        for (int k = i - 8; k <= i + 7; k++) {
          if (k >= 0 && k < n) acc += lg[k][d];
        }
        hp[i][d] = lg[i][d] - acc / 16;
      }
    }
    const nfft = 512;
    final cvd = Float64List(nfft ~/ 2 + 1);
    final re = Float64List(nfft), im = Float64List(nfft);
    for (int d = 0; d < nd; d++) {
      if (mean[d] <= nf * 6.3096) continue; // 8 dB over noise
      re.fillRange(0, nfft, 0);
      im.fillRange(0, nfft, 0);
      for (int i = 0; i < n; i++) {
        final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
        re[i] = hp[i][d] * w;
      }
      _fft512.transform(re, im);
      for (int k = 0; k <= nfft ~/ 2; k++) {
        cvd[k] += math.sqrt(re[k] * re[k] + im[k] * im[k]);
      }
    }
    int bestK = 0;
    double bestV = -1;
    final band = <double>[];
    for (int k = 0; k <= nfft ~/ 2; k++) {
      final fr = k * Radar.columnRate / nfft;
      if (fr < 1.0 || fr > 15) continue;
      band.add(cvd[k]);
      if (cvd[k] > bestV) {
        bestV = cvd[k];
        bestK = k;
      }
    }
    f.cadence = bestK * Radar.columnRate / nfft;
    f.cadenceSnr = bestV / (_percentile(band, 50) + 1e-12);

    // RCS from MTI gate power, compensated for range and detected walls.
    double p = 0;
    for (int i = 0; i < n; i++) {
      p += _colPow[(colHead - 1 - i + maxCols) % maxCols] / n;
    }
    p -= 2 * _sigmaN * _sigmaN * Radar.sigGate;
    final a2 = math.max(p, 1e-14) / HannResponse.gatePowerFactor();
    final att2 = math.pow(Radar.wallLoss, 2 * walls).toDouble();
    final rcs =
        a2 * math.pow(rangeM, 4) / (Radar.gain * Radar.gain) / att2;
    f.rcsDbsm = 10 * math.log(rcs + 1e-12) / math.ln10;

    // Breathing: only meaningful once the target has been still a while.
    if (still && stillSeconds >= 10) {
      final m = math.min(_bCount, math.min(breathLen, (stillSeconds * 16).floor()));
      if (m >= 160) _breathing(f, m);
    }
    return f;
  }

  void _breathing(SignatureFeatures f, int m) {
    final xr = Float64List(m), xi = Float64List(m);
    double mr = 0, mi = 0;
    for (int i = 0; i < m; i++) {
      final idx = (_bHead - m + i + breathLen) % breathLen;
      xr[i] = _bRe[idx];
      xi[i] = _bIm[idx];
      mr += xr[i] / m;
      mi += xi[i] / m;
    }
    double a = 0, b = 0, c = 0;
    for (int i = 0; i < m; i++) {
      xr[i] -= mr;
      xi[i] -= mi;
      a += xr[i] * xr[i];
      b += xr[i] * xi[i];
      c += xi[i] * xi[i];
    }
    // Principal axis of the I/Q cloud (linear demodulation).
    final th = 0.5 * math.atan2(2 * b, a - c);
    final ca = math.cos(th), sa = math.sin(th);
    const nfft = 2048;
    final re = Float64List(nfft), im = Float64List(nfft);
    for (int i = 0; i < m; i++) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (m - 1));
      re[i] = (xr[i] * ca + xi[i] * sa) * w;
    }
    _fft2048.transform(re, im);
    int best = 0;
    double bv = -1;
    final ref = <double>[];
    for (int k = 0; k <= nfft ~/ 2; k++) {
      final fr = k * 16.0 / nfft;
      final mag = math.sqrt(re[k] * re[k] + im[k] * im[k]);
      if (fr > 0.1 && fr < 3) ref.add(mag);
      if (fr > 0.12 && fr < 0.9 && mag > bv) {
        bv = mag;
        best = k;
      }
    }
    f.breathBpm = best * 16.0 / nfft * 60;
    f.breathSnr = bv / (_percentile(ref, 50) + 1e-12);
  }

  /// Latest breathing waveform (16 Hz, mean removed, principal axis), for
  /// display. Up to [count] samples.
  Float64List breathingTrace(int count) {
    final m = math.min(count, _bCount);
    final out = Float64List(m);
    if (m < 4) return out;
    double mr = 0, mi = 0;
    for (int i = 0; i < m; i++) {
      final idx = (_bHead - m + i + breathLen) % breathLen;
      mr += _bRe[idx] / m;
      mi += _bIm[idx] / m;
    }
    double a = 0, b = 0, c = 0;
    for (int i = 0; i < m; i++) {
      final idx = (_bHead - m + i + breathLen) % breathLen;
      final x = _bRe[idx] - mr, y = _bIm[idx] - mi;
      a += x * x;
      b += x * y;
      c += y * y;
    }
    final th = 0.5 * math.atan2(2 * b, a - c);
    for (int i = 0; i < m; i++) {
      final idx = (_bHead - m + i + breathLen) % breathLen;
      out[i] = (_bRe[idx] - mr) * math.cos(th) + (_bIm[idx] - mi) * math.sin(th);
    }
    return out;
  }

  static double _percentile(List<double> v, double q) {
    if (v.isEmpty) return 0;
    final s = List<double>.from(v)..sort();
    final pos = (s.length - 1) * q / 100;
    final i = pos.floor();
    final f = pos - i;
    if (i + 1 >= s.length) return s.last;
    return s[i] + (s[i + 1] - s[i]) * f;
  }
}
