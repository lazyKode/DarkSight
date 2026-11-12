#include "dsp_core.h"

#include <cmath>
#include <complex>
#include <vector>

namespace {

using cf = std::complex<float>;
const float kPi = 3.14159265358979323846f;

bool is_pow2(int32_t n) { return n > 1 && (n & (n - 1)) == 0; }

// In-place iterative radix-2 FFT.
void fft(std::vector<cf>& a) {
  const size_t n = a.size();
  for (size_t i = 1, j = 0; i < n; i++) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const float ang = -2 * kPi / static_cast<float>(len);
    const cf wl(std::cos(ang), std::sin(ang));
    for (size_t i = 0; i < n; i += len) {
      cf w(1, 0);
      for (size_t k = 0; k < len / 2; k++) {
        const cf u = a[i + k], v = a[i + k + len / 2] * w;
        a[i + k] = u + v;
        a[i + k + len / 2] = u - v;
        w *= wl;
      }
    }
  }
}

std::vector<float> hann(int32_t n) {
  std::vector<float> w(n);
  for (int32_t i = 0; i < n; i++) {
    w[i] = 0.5f - 0.5f * std::cos(2 * kPi * i / static_cast<float>(n - 1));
  }
  return w;
}

}  // namespace

extern "C" {

int32_t ds_version(void) { return 1; }

int32_t ds_range_doppler(const float* re, const float* im, int32_t rx,
                         int32_t chirps, int32_t samples, float* out) {
  if (!re || !im || !out || rx < 1 || !is_pow2(chirps) || !is_pow2(samples)) {
    return -1;
  }
  const std::vector<float> wr = hann(samples), wd = hann(chirps);
  std::vector<cf> range(static_cast<size_t>(chirps) * samples);
  std::vector<cf> fast(samples), slow(chirps);
  std::vector<double> power(static_cast<size_t>(samples) * chirps, 0.0);
  const int32_t half = chirps / 2;

  for (int32_t r = 0; r < rx; r++) {
    for (int32_t m = 0; m < chirps; m++) {
      const size_t o = (static_cast<size_t>(r) * chirps + m) * samples;
      for (int32_t n = 0; n < samples; n++) {
        fast[n] = cf(re[o + n], im[o + n]) * wr[n];
      }
      fft(fast);
      for (int32_t n = 0; n < samples; n++) {
        range[static_cast<size_t>(m) * samples + n] = fast[n];
      }
    }
    for (int32_t k = 0; k < samples; k++) {
      for (int32_t m = 0; m < chirps; m++) {
        slow[m] = range[static_cast<size_t>(m) * samples + k] * wd[m];
      }
      fft(slow);
      for (int32_t d = 0; d < chirps; d++) {
        power[static_cast<size_t>(k) * chirps + (d + half) % chirps] +=
            std::norm(slow[d]);
      }
    }
  }
  const double gain = (samples / 2.0) * (chirps / 2.0);
  const double norm = 1.0 / (gain * gain * rx);
  for (size_t i = 0; i < power.size(); i++) {
    double v = (10.0 * std::log10(power[i] * norm + 1e-12) + 60.0) / 60.0;
    out[i] = static_cast<float>(v < 0 ? 0 : (v > 1 ? 1 : v));
  }
  return 0;
}

int32_t ds_cfar_1d(const float* x, int32_t n, int32_t guard, int32_t train,
                   float offset, uint8_t* hits) {
  if (!x || !hits || n <= 0 || guard < 0 || train < 1) return -1;
  int32_t count = 0;
  for (int32_t i = 0; i < n; i++) {
    double sum = 0;
    int32_t cnt = 0;
    for (int32_t j = i - guard - train; j <= i + guard + train; j++) {
      if (j < 0 || j >= n || std::abs(j - i) <= guard) continue;
      sum += x[j];
      cnt++;
    }
    hits[i] = (cnt > 0 && x[i] - sum / cnt > offset) ? 1 : 0;
    count += hits[i];
  }
  return count;
}

}  // extern "C"
