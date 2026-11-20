import 'package:flutter/material.dart';

import '../core/sdr_radar_source.dart';
import '../platform/ble_scanner.dart';
import 'theme.dart';

/// Tier 3 pairing: scan BLE / offer the Wi-Fi bridge listener / offer the
/// built-in mock, pick a device, detect its protocol, report link status.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.onConnected});
  /// [release] closes the link (BLE); call it on disconnect.
  final void Function(SdrDevice device, Future<void> Function()? release)
      onConnected;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

/// Pairing flow. One device at a time; scanning and pairing exclude each
/// other.
///
///   idle --tap device--> connecting --> detecting --> connected --> (handed off)
///   connecting --link failed--> idle
///   idle --SCAN--> scanning --finished / tap device--> idle / connecting
enum _Pairing { idle, scanning, connecting, detecting, connected }

class _PairingScreenState extends State<PairingScreen> {
  final BleScanner _ble = BleScanner();
  List<BleFound> _found = const [];
  _Pairing _stage = _Pairing.idle;
  String? _busyId; // device being paired, in connecting..connected
  String _protocol = '';
  String? _bleNote;
  int _scanRun = 0; // identifies the current scan; stale results are ignored
  bool _handedOff = false;

  bool get _scanning => _stage == _Pairing.scanning;

  String get _stageText => switch (_stage) {
        _Pairing.connecting => 'Connecting...',
        _Pairing.detecting => 'Detecting protocol...',
        _Pairing.connected => 'Connected: $_protocol',
        _ => '',
      };

  static const SdrDevice _mock = SdrDevice(
      id: 'mock', name: 'DarkSight mock FMCW (built in)', transport: SdrTransport.mock);
  static const SdrDevice _udp = SdrDevice(
      id: 'udp',
      name: 'Wi-Fi bridge (UDP ${SdrRadarSource.udpPort})',
      transport: SdrTransport.udp);

  @override
  void dispose() {
    _ble.stop();
    // A link opened here but never handed to the radar screen is closed.
    final id = _busyId;
    if (id != null && !_handedOff) _ble.disconnect(id);
    super.dispose();
  }

  Future<void> _scan() async {
    if (_stage != _Pairing.idle) return;
    final run = ++_scanRun;
    setState(() {
      _stage = _Pairing.scanning;
      _bleNote = null;
      _found = const [];
    });
    final err = await _ble.start((list) {
      if (mounted && run == _scanRun) setState(() => _found = list);
    });
    if (!mounted || run != _scanRun || _stage != _Pairing.scanning) return;
    setState(() {
      _stage = _Pairing.idle;
      _bleNote = err ??
          (_found.isEmpty ? 'Scan finished: no named BLE devices nearby.' : null);
    });
  }

  Future<void> _connect(SdrDevice d) async {
    if (_stage != _Pairing.idle && _stage != _Pairing.scanning) return;
    _scanRun++; // abandon any scan in progress
    setState(() {
      _stage = _Pairing.connecting;
      _busyId = d.id;
    });
    await _ble.stop();
    if (d.transport == SdrTransport.ble) {
      final link = await _ble.connect(d.id);
      if (!mounted) return;
      if (!link.ok) {
        setState(() {
          _stage = _Pairing.idle;
          _busyId = null;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(link.message)));
        return;
      }
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    if (!mounted) return;
    setState(() => _stage = _Pairing.detecting);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    final profile = d.profile ?? matchProfile(d.name);
    setState(() {
      _protocol = switch (d.transport) {
        SdrTransport.mock => 'Raw IQ cube (in-process)',
        SdrTransport.udp => 'DSRD range-Doppler frames',
        SdrTransport.ble => profile?.protocol ?? 'Unknown GATT device',
      };
      _stage = _Pairing.connected;
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    _handedOff = true;
    final ble = _ble;
    final id = d.id;
    widget.onConnected(
        SdrDevice(
            id: d.id,
            name: d.name,
            transport: d.transport,
            rssi: d.rssi,
            profile: profile),
        d.transport == SdrTransport.ble ? () => ble.disconnect(id) : null);
  }

  Widget _tile(SdrDevice d, IconData icon, String subtitle) {
    final busy = _busyId == d.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: kPanel,
        border: Border.all(color: busy ? kPhosphor : const Color(0xFF1E3A1E)),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: kPhosphor),
        title: Text(d.name, style: const TextStyle(fontSize: 13)),
        subtitle: Text(busy ? _stageText : subtitle,
            style: TextStyle(fontSize: 11, color: busy ? kAmber : kDim)),
        trailing: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : (d.rssi != null
                ? Text('${d.rssi} dBm',
                    style: const TextStyle(fontSize: 11, color: kDim))
                : const Icon(Icons.chevron_right, color: kDim)),
        onTap: () => _connect(d),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('PAIR A RADIO',
            style: TextStyle(color: kPhosphor, letterSpacing: 2, fontSize: 14)),
        const SizedBox(height: 4),
        const Text(
            'The phone is display and controller; the radio does the sensing.',
            style: TextStyle(color: kDim, fontSize: 11)),
        const SizedBox(height: 12),
        _tile(_mock, Icons.memory,
            'Synthetic IQ stream. Exercises the full DSP chain, no hardware.'),
        _tile(_udp, Icons.wifi_tethering,
            'Listen for a bridge streaming range-Doppler frames on the LAN.'),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
                child: Text('BLUETOOTH LE',
                    style: TextStyle(color: kDim, fontSize: 11))),
            TextButton.icon(
              onPressed: _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bluetooth_searching, size: 18),
              label: Text(_scanning ? 'SCANNING' : 'SCAN'),
            ),
          ],
        ),
        for (final f in _found)
          _tile(
            SdrDevice(
                id: f.id,
                name: f.name,
                transport: SdrTransport.ble,
                rssi: f.rssi,
                profile: matchProfile(f.name)),
            Icons.bluetooth,
            matchProfile(f.name)?.name ?? 'Unrecognised device',
          ),
        if (_bleNote != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_bleNote!,
                style: const TextStyle(color: kAmber, fontSize: 11)),
          ),
        const SizedBox(height: 16),
        const Text('SUPPORTED RADIOS',
            style: TextStyle(color: kDim, fontSize: 11)),
        const SizedBox(height: 6),
        for (final p in kSdrProfiles)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${p.name}\n  ${p.protocol}\n  ${p.note}',
                style: const TextStyle(fontSize: 11, color: kDim, height: 1.3)),
          ),
      ],
    );
  }
}
