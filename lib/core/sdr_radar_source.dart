import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/fmcw_pipeline.dart';
import '../ml/classifier.dart';
import 'radar_source.dart';

enum SdrTransport { mock, ble, udp }

/// A known external radio and how DarkSight expects to talk to it.
class SdrProfile {
  const SdrProfile(this.name, this.match, this.transport, this.protocol,
      this.note);
  final String name;
  final List<String> match; // lower-case substrings of the advertised name
  final SdrTransport transport;
  final String protocol;
  final String note;

  Map<String, dynamic> toJson() => {
        'name': name,
        'transport': transport.name,
        'protocol': protocol,
      };
}

/// Supported-device list. None of these radios speak BLE or Wi-Fi natively;
/// each needs a small bridge (ESP32 for UART modules, a Raspberry Pi or
/// laptop for USB SDRs) that forwards frames. See README "Tier 3 wiring".
const List<SdrProfile> kSdrProfiles = [
  SdrProfile('TI IWR6843 (60 GHz FMCW)', ['iwr6843', 'iwr68'],
      SdrTransport.ble, 'TI mmWave TLV over UART bridge',
      'Point cloud + range profile TLVs. 60 GHz does not pass through walls.'),
  SdrProfile('TI IWR1443 (77 GHz FMCW)', ['iwr1443', 'iwr14'],
      SdrTransport.ble, 'TI mmWave TLV over UART bridge',
      'Same framing as IWR6843.'),
  SdrProfile('Infineon BGT60TR13C (60 GHz FMCW)', ['bgt60'],
      SdrTransport.ble, 'Raw ADC frames over SPI bridge',
      'Short range; needs an MCU bridge to reach the phone.'),
  SdrProfile('ADALM-Pluto (AD9363)', ['pluto'], SdrTransport.udp,
      'DSRD range-Doppler frames over UDP',
      'TX+RX capable: the realistic choice for sub-6 GHz through-wall work.'),
  SdrProfile('HackRF One', ['hackrf'], SdrTransport.udp,
      'DSRD range-Doppler frames over UDP',
      'Half duplex: needs a second receiver for radar use.'),
  SdrProfile('RTL-SDR Blog V4', ['rtl'], SdrTransport.udp,
      'DSRD range-Doppler frames over UDP',
      'Receive only: usable as the receiver of a passive/bistatic setup.'),
];

SdrProfile? matchProfile(String advertisedName) {
  final n = advertisedName.toLowerCase();
  for (final p in kSdrProfiles) {
    for (final m in p.match) {
      if (n.contains(m)) return p;
    }
  }
  return null;
}

class SdrDevice {
  const SdrDevice(
      {required this.id,
      required this.name,
      required this.transport,
      this.rssi,
      this.profile});
  final String id;
  final String name;
  final SdrTransport transport;
  final int? rssi;
  final SdrProfile? profile;
}

/// Tier 3 source. Two links are implemented:
///
///  * mock - synthesises a raw IQ radar cube (4 RX x 32 chirps x 64 samples)
///    for a small scene and runs the full DSP chain on it, so every view and
///    the overlay are testable with no hardware.
///  * udp  - listens for pre-computed range-Doppler frames ("DSRD" packets,
///    see README) from a bridge on the local network. tools/
///    mock_sdr_streamer.py sends compatible frames from a PC.
///
/// TODO(sdr): raw IQ over UDP into the native ring buffer
/// (native/dsp_core/ring_buffer.h) and per-device protocol decoders.
class SdrRadarSource extends RadarSource {
  SdrRadarSource(this.device)
      : cfg = const FmcwConfig(),
        pipeline = FmcwPipeline(const FmcwConfig()) {
    _re = Float32List(cfg.cubeLength);
    _im = Float32List(cfg.cubeLength);
  }

  final SdrDevice device;
  final FmcwConfig cfg;
  final FmcwPipeline pipeline;
  final PointClassifier classifier = PointClassifier();

  static const int udpPort = 4210;
  static const double frameHz = 15;

  late final Float32List _re, _im;
  final math.Random _rng = math.Random(5);
  double _t = 0, _acc = 0;
  RawDatagramSocket? _socket;

  /// Bumped whenever new data is available for the views.
  int frameCount = 0;
  int packets = 0;
  String status = 'idle';

  /// Recent detections, newest last, for the point cloud's persistence.
  final List<List<RadarPoint>> history = [];
  List<Cluster> clusters = const [];

  /// Range-Doppler grid dimensions currently in [pipeline.rangeDoppler] (UDP
  /// frames may differ from the mock's; they are resampled on receipt).
  bool get hasAngle => device.transport == SdrTransport.mock;

  @override
  String get label => 'SDR';

  @override
  void start() {
    if (device.transport == SdrTransport.udp) {
      _bindUdp();
    } else if (device.transport == SdrTransport.mock) {
      status = 'streaming (mock IQ)';
    } else {
      status = 'linked; no decoder for this device yet';
    }
  }

  @override
  void stop() {
    _socket?.close();
    _socket = null;
  }

  @override
  void dispose() => stop();

  @override
  void tick(double dt) {
    if (device.transport != SdrTransport.mock) return;
    if (dt > 0.2) dt = 0.2;
    _acc += dt;
    final period = 1 / frameHz;
    if (_acc < period) return;
    _acc = _acc % period;
    _t += period;
    _synthCube();
    pipeline.process(_re, _im);
    _publish(pipeline.points);
  }

  void _publish(List<RadarPoint> pts) {
    history.add(pts);
    if (history.length > 8) history.removeAt(0);
    clusters = classifier.classify(pts);
    frameCount++;
  }

  // ---- mock IQ generation ----

  void _target(double x, double y, double radialVel, double amp) {
    final ns = cfg.samples, nc = cfg.chirps, nrx = cfg.rx;
    final r = math.sqrt(x * x + y * y);
    if (r < 0.3 || r >= cfg.maxRange) return;
    final a = amp / r;
    final kr = r / cfg.rangeRes;
    final kd = radialVel / cfg.velocityRes;
    final sinTh = x / r;
    final phi0 = 4 * math.pi * r / 0.005; // 60 GHz carrier phase
    final wr = 2 * math.pi * kr / ns, wd = 2 * math.pi * kd / nc;
    for (int rx = 0; rx < nrx; rx++) {
      for (int m = 0; m < nc; m++) {
        final base = phi0 + math.pi * sinTh * rx + wd * m;
        final o = (rx * nc + m) * ns;
        // Phasor recurrence along fast time.
        double pr = a * math.cos(base), pq = a * math.sin(base);
        final cr = math.cos(wr), ci = math.sin(wr);
        for (int n = 0; n < ns; n++) {
          _re[o + n] += pr;
          _im[o + n] += pq;
          final t = pr * cr - pq * ci;
          pq = pr * ci + pq * cr;
          pr = t;
        }
      }
    }
  }

  void _synthCube() {
    const sigma = 0.1;
    for (int i = 0; i < _re.length; i++) {
      final u1 = _rng.nextDouble() + 1e-12, u2 = _rng.nextDouble();
      final m = sigma * math.sqrt(-2 * math.log(u1));
      _re[i] = m * math.cos(2 * math.pi * u2);
      _im[i] = m * math.sin(2 * math.pi * u2);
    }
    // Structure: a back wall and a side wall (static).
    for (double x = -1; x <= 5; x += 0.45) {
      _target(x, 8, 0, 0.9);
    }
    for (double y = 3; y <= 7; y += 0.45) {
      _target(-4.2, y, 0, 0.8);
    }
    // A person walking a loop; radial velocity from finite differences.
    double px(double t) => 1.8 * math.sin(0.5 * t);
    double py(double t) => 4.5 + 1.6 * math.cos(0.33 * t);
    double range(double t) => math.sqrt(px(t) * px(t) + py(t) * py(t));
    final v = (range(_t) - range(_t - 0.05)) / 0.05;
    final x = px(_t), y = py(_t);
    final swing = 0.9 * math.sin(_t * 6);
    _target(x, y, v, 0.9);
    _target(x + 0.2, y + 0.15, v + swing, 0.4);
    _target(x - 0.2, y - 0.15, v - swing, 0.4);
    // A small moving object (think desk fan / swinging door).
    final ov = 0.9 * math.cos(_t * 3);
    _target(3.4, 2.6 + 0.3 * math.sin(_t * 3), ov, 0.22);
    _target(3.5, 2.7 + 0.3 * math.sin(_t * 3), ov, 0.18);
  }

  // ---- UDP link ----

  Future<void> _bindUdp() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
      _socket = s;
      status = 'listening on UDP $udpPort';
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d = s.receive();
        while (d != null) {
          _onPacket(d.data);
          d = s.receive();
        }
      });
    } catch (e) {
      status = 'UDP bind failed: $e';
    }
  }

  /// DSRD v1 (little endian):
  ///   0  char[4] "DSRD"      4  u16 version (1)
  ///   6  u16 nRange          8  u16 nDoppler      10 u16 reserved
  ///   12 f32 maxRange (m)    16 f32 maxVelocity (m/s)
  ///   20 u8[nRange * nDoppler] log intensity, row = range bin
  void _onPacket(Uint8List data) {
    if (data.length < 20) return;
    if (data[0] != 0x44 || data[1] != 0x53 || data[2] != 0x52 || data[3] != 0x44) {
      return;
    }
    final bd = ByteData.sublistView(data);
    if (bd.getUint16(4, Endian.little) != 1) return;
    final nr = bd.getUint16(6, Endian.little);
    final nd = bd.getUint16(8, Endian.little);
    if (nr == 0 || nd == 0 || data.length < 20 + nr * nd) return;
    // Nearest-neighbour resample onto the display grid.
    final ns = cfg.samples, nc = cfg.chirps;
    final rd = pipeline.rangeDoppler;
    for (int k = 0; k < ns; k++) {
      final sk = k * nr ~/ ns;
      for (int d = 0; d < nc; d++) {
        final sd = d * nd ~/ nc;
        rd[k * nc + d] = data[20 + sk * nd + sd] / 255.0;
      }
    }
    packets++;
    status = 'receiving DSRD frames ($packets)';
    frameCount++;
  }
}
