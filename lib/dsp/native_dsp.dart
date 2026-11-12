import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _VersionC = Int32 Function();
typedef _VersionDart = int Function();
typedef _RangeDopplerC = Int32 Function(Pointer<Float> re, Pointer<Float> im,
    Int32 rx, Int32 chirps, Int32 samples, Pointer<Float> out);
typedef _RangeDopplerDart = int Function(Pointer<Float> re, Pointer<Float> im,
    int rx, int chirps, int samples, Pointer<Float> out);

/// Optional FFI binding to native/dsp_core.
///
/// The app runs on the pure-Dart pipeline (fmcw_pipeline.dart) by default.
/// Once libdsp_core is wired into the Android/iOS build (README, "Native
/// DSP"), [tryLoad] returns a binding and callers can switch to it for the
/// range-Doppler step. Returns null when the library is not bundled.
class NativeDsp {
  NativeDsp._(DynamicLibrary lib)
      : _version = lib.lookupFunction<_VersionC, _VersionDart>('ds_version'),
        _rangeDoppler = lib.lookupFunction<_RangeDopplerC, _RangeDopplerDart>(
            'ds_range_doppler');

  final _VersionDart _version;
  final _RangeDopplerDart _rangeDoppler;

  static NativeDsp? tryLoad() {
    try {
      final DynamicLibrary lib;
      if (Platform.isAndroid || Platform.isLinux) {
        lib = DynamicLibrary.open('libdsp_core.so');
      } else if (Platform.isIOS || Platform.isMacOS) {
        lib = DynamicLibrary.process();
      } else if (Platform.isWindows) {
        lib = DynamicLibrary.open('dsp_core.dll');
      } else {
        return null;
      }
      return NativeDsp._(lib);
    } catch (_) {
      return null;
    }
  }

  int get version => _version();

  /// Same contract as ds_range_doppler in dsp_core.h. Returns null on error.
  Float32List? rangeDoppler(
      Float32List re, Float32List im, int rx, int chirps, int samples) {
    final n = rx * chirps * samples;
    if (re.length < n || im.length < n) return null;
    final pRe = calloc<Float>(n);
    final pIm = calloc<Float>(n);
    final pOut = calloc<Float>(samples * chirps);
    try {
      pRe.asTypedList(n).setRange(0, n, re);
      pIm.asTypedList(n).setRange(0, n, im);
      final rc = _rangeDoppler(pRe, pIm, rx, chirps, samples, pOut);
      if (rc != 0) return null;
      return Float32List.fromList(pOut.asTypedList(samples * chirps));
    } finally {
      calloc.free(pRe);
      calloc.free(pIm);
      calloc.free(pOut);
    }
  }
}
