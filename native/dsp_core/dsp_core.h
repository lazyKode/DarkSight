// DarkSight native DSP core. C ABI so it can be bound from Dart FFI
// (lib/dsp/native_dsp.dart) on Android (.so) and iOS (static, in-process).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define DS_EXPORT __declspec(dllexport)
#else
#define DS_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

DS_EXPORT int32_t ds_version(void);

// Range-Doppler map from a raw IQ cube.
//   re/im : [(rx * chirps + chirp) * samples + n]
//   out   : [range * chirps + doppler], log scale 0..1 (0 = -60 dB),
//           Doppler fft-shifted so the centre column is 0 m/s
// samples and chirps must be powers of two. Returns 0 on success.
DS_EXPORT int32_t ds_range_doppler(const float* re, const float* im,
                                   int32_t rx, int32_t chirps, int32_t samples,
                                   float* out);

// Cell-averaging CFAR over a log-scaled vector. hits[i] = 1 where
// x[i] - mean(training cells) > offset. Returns the number of hits.
DS_EXPORT int32_t ds_cfar_1d(const float* x, int32_t n, int32_t guard,
                             int32_t train, float offset, uint8_t* hits);

#ifdef __cplusplus
}
#endif
