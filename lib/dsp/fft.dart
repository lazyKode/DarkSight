import 'dart:math' as math;
import 'dart:typed_data';

/// In-place radix-2 complex FFT with cached twiddles and a Hann window.
class Fft {
  Fft(this.n)
      : assert(n > 1 && (n & (n - 1)) == 0, 'FFT size must be a power of two'),
        _rev = Uint32List(n),
        _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        hann = Float64List(n) {
    int bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (int i = 0; i < n; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        if ((i & (1 << b)) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
    for (int k = 0; k < n ~/ 2; k++) {
      final a = -2 * math.pi * k / n;
      _cos[k] = math.cos(a);
      _sin[k] = math.sin(a);
    }
    for (int i = 0; i < n; i++) {
      hann[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    }
  }

  final int n;
  final Uint32List _rev;
  final Float64List _cos;
  final Float64List _sin;

  /// Hann window of length [n]. Coherent gain is n/2.
  final Float64List hann;

  /// Forward transform (kernel exp(-j 2 pi k n / N)), unnormalised.
  void transform(Float64List re, Float64List im) {
    for (int i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (int size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (int start = 0; start < n; start += size) {
        int t = 0;
        for (int k = 0; k < half; k++) {
          final wr = _cos[t];
          final wi = _sin[t];
          final a = start + k;
          final b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
          t += step;
        }
      }
    }
  }
}
