# DarkSight

Radio-wave sensing rendered as a human-readable "night vision" view.

**Live web app:** https://lazykode.github.io/DarkSight/

**Downloads (APK / IPA):** open the [Actions tab](https://github.com/lazyKode/DarkSight/actions/workflows/build.yml), pick the latest successful **Build** run, and grab `DarkSight-apk` or `DarkSight-ipa` under Artifacts.
Flutter (Dart 3), dark-only, three tiers behind one mode switch (SIM / CSI / SDR).

| Tier | What it does | State |
|---|---|---|
| 1. Simulation | Synthetic rotating-beam FMCW radar over an editable floor plan, PPI view, detector overlay, photo export | Complete |
| 2. Wi-Fi sensing | Presence/motion from the phone's Wi-Fi | RSSI fallback working (Android); raw CSI is a TODO |
| 3. External radar | Pairing flow, DSP chain, three views, overlay | Runs end to end on a built-in mock IQ stream and on UDP range-Doppler frames; real device decoders are TODOs |

> **Build status.** The Dart code in this repo was written without access to
> a Flutter toolchain, so it has not yet been through `flutter analyze` or a
> device run. The native C++ core was compiled and tested, and the simulator
> and detector maths were checked with a numerical port. Expect to fix a few
> analyzer complaints on first build; `flutter analyze` then `flutter test`
> is the fastest way to find them.

## Setup

Requires Flutter 3.19 or newer (Dart 3.3+).

```powershell
# Windows
cd darksight
.\setup.ps1          # flutter create for android/ios, permissions, pub get
flutter analyze
flutter test
flutter run
```

```bash
# macOS / Linux
./setup.sh && flutter analyze && flutter test && flutter run
```

The setup script runs `flutter create .` (which keeps every file already
here, including `MainActivity.kt`), deletes the template widget test, and
adds Bluetooth / Wi-Fi / network permissions to `AndroidManifest.xml` and
`Info.plist`.

If Gradle rejects a plugin on a newer Flutter, run
`flutter pub upgrade --major-versions`. Two APIs are version-sensitive:
`share_plus` 11+ replaces `Share.shareXFiles` with `SharePlus.instance.share`
(`lib/ui/photo_mode.dart`), and `flutter_blue_plus` 2.x adds a licence
argument to `connect` (`lib/platform/ble_scanner.dart`).

## Tier 1: simulation

`lib/core/sim_radar_source.dart`. For each 1 degree beam the engine
synthesises one 256-sample chirp of complex baseband signal and FFTs it into
a range profile; the image is whatever the processing recovers.

- Walls: point scatterers every 8 cm, specular-weighted. Door objects cut
  gaps. Furniture: perimeter scatterers.
- Person: torso plus four limb scatterers with gait swing, about 6 dB lost
  per wall crossed.
- Multipath: each person is mirrored in every wall that can reflect them
  (wall-person-wall path at the image position, plus a weaker mixed path).
- Thermal noise, transmit leakage at the centre, slow clutter drift.
- Trajectories: circle, patrol, wander; speed 0 to 2 m/s.

Rendering (`lib/ui/ppi_view.dart`): polar buffer to a 360 px RGBA image via
a lookup table with per-beam phosphor decay, uploaded as a GPU image, with
sweep glow, range rings, 20 % ghosted floor plan and boxes drawn as vectors
on top. Dragging a person re-illuminates the sectors they left and entered
on the next frame, so the image follows the finger rather than the sweep.

Controls (tune button): sweep rate, range window, noise, person speed,
trajectory, play/pause, colormap, AI overlay, ghost plan.

**AI overlay.** A classical detector, not a neural network
(`lib/ml/detector.dart`): CA-CFAR, sweep-to-sweep change detection,
run-length wall extraction, connected components, size/motion rules, and a
short track memory. Labels: person / object / wall. Multipath ghosts get
labelled "person" too, as they would on a real set. `models/README.md` has
the plan for training and dropping in a TFLite / Core ML model behind the
same interface.

**Photo mode.** Freezes the frame, resamples to a square, histogram stretch,
unsharp mask, green intensifier palette, vignette, grain, scan lines, HUD,
then PNG via the share sheet. It is a top-down map styled as night vision,
not a camera-like view of the room.

## Tier 2: Wi-Fi sensing

What works: `MainActivity.kt` exposes the connected access point's RSSI over
the `darksight/wifi` channel; `lib/dsp/motion_detector.dart` removes the
static level, integrates residual energy, and applies an adaptive threshold
with hysteresis. RSSI is coarse (1 dB steps, refreshed every few seconds by
most drivers), so expect it to catch someone walking through the line
between phone and router, not subtle motion.

On iOS, desktop, or with Wi-Fi off, the screen switches to a synthetic
signal and says so in an amber banner.

What does not: raw CSI. No stock Android phone exposes it and
`CHANGE_WIFI_STATE` does not unlock it. It needs root plus patched firmware
(Nexmon CSI on certain Broadcom chips). The Intel AX200/AX210 and MediaTek
MT7921 are laptop cards. Details and the integration point are in
`native/csi_android/README.md`. The 90 % recall / 1 false alarm per 10 min
target has not been measured and is unlikely to be met on RSSI alone.

## Tier 3: external radar

Pairing screen: built-in mock, Wi-Fi bridge listener (UDP 4210), and a BLE
scan that matches advertised names against the profile list.

- **Mock** generates a raw IQ cube (4 RX x 32 chirps x 64 samples) for a
  small scene and runs the whole chain in `lib/dsp/fmcw_pipeline.dart`:
  range FFT, Doppler FFT, CA-CFAR, angle FFT across the array, giving
  (range, angle, velocity) points plus range-Doppler and range-angle maps.
- **UDP** accepts pre-computed range-Doppler frames (format below).
  `tools/mock_sdr_streamer.py <phone-ip>` sends them from a PC.
- **BLE** connects and lists GATT services; no device protocol is decoded yet.

Views (swipe): top-down sector heatmap with DBSCAN boxes and stick figures,
range-Doppler map, 3D point cloud (z is radial velocity, since a linear
array has no elevation; drag vertically to rotate). The point cloud is
software-projected on a Canvas, which is ample for a few hundred points.

Not done: back-projection photo mode, GIF export, raw IQ over UDP into the
native ring buffer, per-device decoders.

### Hardware notes

None of the listed radios speak BLE or Wi-Fi themselves; each needs a bridge.

| Radio | Reality check |
|---|---|
| ADALM-Pluto | Transmits and receives, 325 MHz to 3.8 GHz (hackable to 6 GHz). The realistic choice for through-wall experiments. |
| HackRF One | Half duplex. Needs a second receiver to act as a radar. |
| RTL-SDR Blog V4 | Receive only. Useful as the receiver in a passive or bistatic setup, not as a radar on its own. |
| TI IWR6843 / IWR1443 | 60 / 77 GHz. Excellent point clouds in a room; millimetre waves do not get through walls. |
| Infineon BGT60TR13C | 60 GHz (not 24), SPI rather than UART. Short range, same wall limitation. |

### Wiring

```
USB SDR (Pluto / HackRF / RTL-SDR)

  [antennas] -- [SDR] --USB-- [Raspberry Pi / laptop] ==Wi-Fi UDP 4210==> [phone]
                               GNU Radio or Python:
                               chirp TX, dechirp RX,
                               range-Doppler -> DSRD frames

UART mmWave module (IWR6843 / IWR1443)

  [IWR6843]  TX -> RX  [ESP32]  ~~BLE notify~~>  [phone]
             RX <- TX            (or Wi-Fi UDP)
             GND -- GND
             5 V supply, 3.3 V logic; data UART 921600 baud
```

### DSRD frame, version 1 (little endian)

```
 0  char[4]  "DSRD"          4  u16  version = 1
 6  u16      nRange          8  u16  nDoppler        10  u16 reserved
12  f32      maxRange (m)   16  f32  maxVelocity (m/s)
20  u8[nRange * nDoppler]   log intensity, row = range bin, column = Doppler
                            (centre column = 0 m/s)
```

## Native DSP

`native/dsp_core` holds a C++ range-Doppler + CFAR implementation with a C
ABI and a lock-free 4 MB SPSC ring buffer, with a host test:

```bash
cd native/dsp_core && g++ -std=c++17 -O2 -pthread test_dsp.cpp dsp_core.cpp -o t && ./t
```

The app runs on the pure-Dart pipeline by default so it builds with no NDK.
To switch: add the CMake project to `android/app/build.gradle`
(`externalNativeBuild { cmake { path "../../native/dsp_core/CMakeLists.txt" } }`),
add the sources to the iOS Runner target, then use
`NativeDsp.tryLoad()` from `lib/dsp/native_dsp.dart`.

## Layout

```
lib/
  main.dart
  core/      radar_source, sim/csi/sdr sources, scene, settings, storage
  dsp/       fft, fmcw_pipeline, motion_detector, native_dsp (FFI)
  ml/        detector (Tier 1), classifier (Tier 3)
  ui/        ppi_view, floor_plan_editor, control_sheet, photo_mode,
             sim/csi/sdr screens, pairing_screen, point_cloud_view, theme
  platform/  ble_scanner
android/.../MainActivity.kt   Wi-Fi RSSI channel
native/      dsp_core (C++), csi_android (notes + stub)
models/      placeholder + training plan
tools/       mock_sdr_streamer.py
test/        dsp_test.dart
```

## Acceptance criteria

| # | Criterion | Status |
|---|---|---|
| 1 | Tier 1 animated sweep on `flutter run` | Implemented, not yet run |
| 2 | Drag updates radar image within 100 ms | Implemented via sector re-illumination, not measured |
| 3 | AI overlay boxes within 200 ms | Detector runs on the frame the toggle changes; not measured |
| 4 | Photo mode PNG reads as night vision | Implemented; judge by eye |
| 5 | Tier 2 CSI recall / false alarms | Not met: RSSI only, unmeasured |
| 6 | RTL-SDR live range-Doppler within 3 s | UDP path implemented and testable with the streamer; no real bridge yet |
| 7 | 30 fps on mid-range phones | Designed for it (a few beams and one 130 k pixel pass per frame); not profiled |
| 8 | Battery budgets | Not measured |

## Use

Radio sensing of spaces you do not control can be illegal (privacy law) and
transmitting with an SDR needs a licence or licence-exempt band. Use this on
your own premises.
