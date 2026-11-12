#include <cmath>
#include <cstdio>
#include <thread>
#include <vector>

#include "dsp_core.h"
#include "ring_buffer.h"

static int failures = 0;
#define CHECK(cond)                                              \
  do {                                                           \
    if (!(cond)) {                                               \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                \
    }                                                            \
  } while (0)

int main() {
  // One target at range bin 20, Doppler bin +5, amplitude 0.1 (-20 dB).
  const int rx = 4, chirps = 32, samples = 64;
  std::vector<float> re(rx * chirps * samples), im(re.size());
  const double pi = 3.14159265358979323846;
  for (int r = 0; r < rx; r++)
    for (int m = 0; m < chirps; m++)
      for (int n = 0; n < samples; n++) {
        const double ph = 2 * pi * (20.0 * n / samples + 5.0 * m / chirps) + 0.5 * r;
        const size_t i = (static_cast<size_t>(r) * chirps + m) * samples + n;
        re[i] = static_cast<float>(0.1 * std::cos(ph));
        im[i] = static_cast<float>(0.1 * std::sin(ph));
      }
  std::vector<float> rd(samples * chirps);
  CHECK(ds_range_doppler(re.data(), im.data(), rx, chirps, samples, rd.data()) == 0);
  int best = 0;
  for (int i = 1; i < samples * chirps; i++)
    if (rd[i] > rd[best]) best = i;
  CHECK(best / chirps == 20);
  CHECK(best % chirps == 5 + chirps / 2);
  // -20 dB on a 60 dB scale = 0.667
  CHECK(std::fabs(rd[best] - 0.6667f) < 0.02f);
  std::printf("peak: range bin %d, doppler bin %d, level %.3f\n", best / chirps,
              best % chirps - chirps / 2, rd[best]);

  // CFAR finds the peak in that Doppler column and nothing far from it.
  std::vector<float> col(samples);
  for (int k = 0; k < samples; k++) col[k] = rd[k * chirps + 5 + chirps / 2];
  std::vector<uint8_t> hits(samples);
  const int n = ds_cfar_1d(col.data(), samples, 2, 6, 0.2f, hits.data());
  CHECK(n >= 1 && hits[20] == 1);
  CHECK(hits[40] == 0 && hits[5] == 0);

  CHECK(ds_range_doppler(re.data(), im.data(), rx, 30, samples, rd.data()) == -1);

  // Ring buffer: wrap-around integrity, then SPSC across two threads.
  darksight::RingBuffer rb(1024);
  CHECK(rb.capacity() == 1024);
  std::vector<uint8_t> a(700), b(700);
  for (int i = 0; i < 700; i++) a[i] = static_cast<uint8_t>(i * 7);
  CHECK(rb.write(a.data(), 700) == 700);
  CHECK(rb.write(a.data(), 700) == 324);  // only what fits
  CHECK(rb.read(b.data(), 700) == 700 && a == b);
  CHECK(rb.read(b.data(), 700) == 324);
  CHECK(rb.write(a.data(), 700) == 700);  // crosses the wrap point
  CHECK(rb.read(b.data(), 700) == 700 && a == b);

  darksight::RingBuffer big(1 << 16);
  const size_t total = 4u << 20;
  bool ok = true;
  std::thread prod([&] {
    uint8_t chunk[997];
    size_t sent = 0;
    while (sent < total) {
      const size_t want = std::min(sizeof(chunk), total - sent);
      for (size_t i = 0; i < want; i++) chunk[i] = static_cast<uint8_t>((sent + i) * 31);
      size_t off = 0;
      while (off < want) off += big.write(chunk + off, want - off);
      sent += want;
    }
  });
  size_t got = 0;
  uint8_t buf[4096];
  while (got < total) {
    const size_t n2 = big.read(buf, sizeof(buf));
    for (size_t i = 0; i < n2; i++)
      if (buf[i] != static_cast<uint8_t>((got + i) * 31)) ok = false;
    got += n2;
  }
  prod.join();
  CHECK(ok);

  std::printf(failures ? "%d FAILURES\n" : "all native tests passed\n", failures);
  return failures ? 1 : 0;
}
