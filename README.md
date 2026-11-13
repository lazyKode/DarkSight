# DarkSight

Radio-wave sensing rendered as a human-readable "night vision" view.

**Live web app:** https://lazykode.github.io/DarkSight/

**Downloads (APK / IPA):** open the [Actions tab](https://github.com/lazyKode/DarkSight/actions/workflows/build.yml), pick the latest successful **Build** run, and grab `DarkSight-apk` or `DarkSight-ipa` under Artifacts.
Flutter (Dart 3), dark-only, three tiers behind one mode switch (SIM / CSI / SDR).

| Tier | What it does | State |
|---|---|---|
| 1. Simulation | Simulated 2.4 GHz tracking radar over an editable floor plan: search sweep, monopulse track dwell, micro-Doppler, breathing, human / dog / cat / machinery classification, photo export | Complete |
| 2. Wi-Fi sensing | Presence/motion from the phone's Wi-Fi | RSSI fallback working (Android); raw CSI is a TODO |
| 3. External radar | Pairing flow, DSP chain, three views, overlay | Runs end to end on a built-in mock IQ stream and on UDP range-Doppler frames; real device decoders are TODOs |

> **Build status.** Every push runs `flutter analyze` and `flutter test` in
> GitHub Actions (including the end-to-end classification tests). Pushes to
> `main` also build the APK, the unsigned IPA and the web app, and deploy
> the web app to Pages.

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

The simulator behaves like a phased-array tracking radar at 2.4 GHz.
`lib/core/sim_radar_source.dart` plays the hardware: it is the only code
that knows what is in the room. Everything after the receiver (tracking,
signature analysis, classification) works from the radio samples alone, and
a test (`test/classification_test.dart`) checks that none of that code
imports the scene.

**Scene (simulated).** Nothing in SIM mode is sensed from the real world:
a phone or browser has no radio that can see through walls. The room and
everything in it are made up. What is real is the processing: the radar
signal is computed from physics, and tracking and classification work only
from that signal.

People move naturally by default: they pick a destination anywhere in the
building, route through door gaps (never through walls), steer with a
limited turn rate, slow for corners and on arrival, then stand still for a
few seconds or up to half a minute. Dogs and cats do the same between rest
bouts. Circle, Patrol and Wander remain as test patterns in Controls.

Walls, door gaps, furniture, and four kinds of moving thing:
people, dogs, cats and fans. Each individual gets its own size, gait and
breathing rate drawn around a population mean.

| | Radar cross-section | Motion model | Breathing |
|---|---|---|---|
| Person | ~0.8 m² | torso, two arms, two legs; step rate rises with speed | 12–20 /min, ~4 mm chest |
| Dog | ~0.15 m² | torso, four legs (trot); walks and rests in bouts | 18–34 /min |
| Cat | ~0.03 m² | as dog, smaller, faster legs | 20–36 /min |
| Fan | ~0.3 m² | hub + three blades at 2–4.5 rev/s | none |

**Physics.** Point targets follow the radar equation (amplitude ∝ √RCS / r²),
walls return like flat plates (∝ 1/r), and each wall crossed costs 6 dB. It
also models first-order wall multipath, very slow clutter drift, transmit
leakage and thermal noise.

**The radar runs two jobs, interleaved:**

1. *Search sweep* (the PPI picture). One 256-sample chirp per degree, FFT
   to a range profile, plus a second chirp 15.6 ms later to give a two-pulse
   MTI. Anything that changed between them is motion, and motion starts a
   track.
2. *Track dwell.* For every track the beam stares at the target at 256
   chirps/s with two squinted receive lobes (amplitude-comparison
   monopulse) over a 31-bin range gate. `lib/dsp/track_processor.dart`
   then:
   - subtracts a per-range-bin clutter map (MTI), which removes walls and
     furniture
   - measures range (power centroid), angle (monopulse ratio) and radial
     velocity (pulse-pair) 32 times a second, feeding an alpha-beta tracker
     (`lib/core/tracker.dart`)
   - builds a micro-Doppler spectrogram (64-point FFT every 8 chirps,
     ±8 m/s, 0.25 m/s resolution)
   - extracts the signature:
     - **RCS**: gate power corrected for range⁴ and for the number of walls
       the search sweep has detected along the line of sight
     - **micro-Doppler span**: how fast the limbs move relative to the body
     - **symmetry**: rotating machinery spreads evenly either side of zero
     - **cadence**: the cadence-velocity diagram, i.e. the periodicity of
       each Doppler bin, which gives gait rhythm and blade rate
     - **breathing rate**: once the target has been still for 10 s, from
       the chest's phase modulation, PCA-demodulated and FFT'd

**Classification** (`lib/ml/target_classifier.dart`). A Gaussian
naive-Bayes model over those features, with separate tables for moving and
still targets. Evidence is fused over the life of the track with about 20 s
of memory. The class distributions were fitted with
`tools/classifier_proto/` (a NumPy model of the same chain) on 220 labelled
synthetic tracks and checked on 165 held-out ones:

| True \ predicted | Human | Dog | Cat | Machinery |
|---|---|---|---|---|
| Human | 42 | 3 | 0 | 0 |
| Dog | 4 | 32 | 8 | 0 |
| Cat | 0 | 1 | 34 | 0 |
| Machinery | 0 | 0 | 1 | 27 |

That is from single 10-second looks. Fusing 30 s of evidence took the
held-out accuracy from 33/39 to 35/39. The app's end-to-end test
places each kind of target in and behind walls and checks the label
(`flutter test test/classification_test.dart`).

**Multipath ghosts.** A track at the mirror image of a nearer track across a
detected wall is labelled as that target's reflection instead of being
counted as another target.

**Known weak spot.** Telling a small dog from a cat is the least reliable
decision. When a dog roams behind several walls, the size estimate drops
(walls the radar has not detected go uncorrected), and it can be labelled
CAT. People, fans and nearby animals are reliable in the tests.

**What this does not prove.** The class models were fitted to simulated
bodies, so the simulator and classifier share assumptions. On real hardware
the tables must be refitted from recorded, labelled data. A cat 6 m away
behind a wall is below the noise at these settings, as it would be on a
real 2.4 GHz radar. A body that never moves is not picked up by the search,
because motion starts tracks.

**Display.** The PPI shows the search picture (inferno colormap, phosphor
persistence, 20 % ghosted plan of walls and furniture only) with track
brackets, IDs, trails, velocity vectors and a lock reticle. The **Targets**
panel (tap a track) shows the class probabilities, telemetry (range,
bearing, speed, heading, radial velocity, walls), the signature values, a
live micro-Doppler waterfall and the chest-motion trace.

**Photo mode.** Freezes the frame, resamples it to a square, then applies a
histogram stretch, unsharp mask, green intensifier palette, vignette, grain,
scan lines and a HUD, and exports a PNG via the share sheet.

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
