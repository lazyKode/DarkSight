import 'package:flutter/material.dart';

import '../core/sdr_radar_source.dart';
import '../platform/ble_scanner.dart';
import 'theme.dart';

/// Tier 3 pairing: scan BLE / offer the Wi-Fi bridge listener / offer the
/// built-in mock, pick a device, detect its protocol, report link status.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.onConnected});
  final void Function(SdrDevice device) onConnected;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final BleScanner _ble = BleScanner();
  List<BleFound> _found = const [];
  bool _scanning = false;
  String? _bleNote;
  String? _busyId;
  String _stage = '';

  static const SdrDevice _mock = SdrDevice(
      id: 'mock', name: 'DarkSight mock FMCW (built in)', transport: SdrTransport.mock);
  static const SdrDevice _udp = SdrDevice(
      id: 'udp',
      name: 'Wi-Fi bridge (UDP ${SdrRadarSource.udpPort})',
      transport: SdrTransport.udp);

  @override
  void dispose() {
    _ble.stop();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _bleNote = null;
      _found = const [];
    });
    final err = await _ble.start((list) {
      if (mounted) setState(() => _found = list);
    });
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _bleNote = err ??
          (_found.isEmpty ? 'Scan finished: no named BLE devices nearby.' : null);
    });
  }

  Future<void> _connect(SdrDevice d) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = d.id;
      _stage = 'Connecting...';
    });
    String linkNote = '';
    if (d.transport == SdrTransport.ble) {
      await _ble.stop();
      linkNote = await _ble.connect(d.id);
      if (!mounted) return;
      if (!linkNote.startsWith('Connected')) {
        setState(() {
          _busyId = null;
          _stage = '';
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(linkNote)));
        return;
      }
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    if (!mounted) return;
    setState(() => _stage = 'Detecting protocol...');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    final profile = d.profile ?? matchProfile(d.name);
    final protocol = switch (d.transport) {
      SdrTransport.mock => 'Raw IQ cube (in-process)',
      SdrTransport.udp => 'DSRD range-Doppler frames',
      SdrTransport.ble => profile?.protocol ?? 'Unknown GATT device',
    };
    setState(() => _stage = 'Connected: $protocol');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() {
      _busyId = null;
      _stage = '';
    });
    widget.onConnected(SdrDevice(
        id: d.id,
        name: d.name,
        transport: d.transport,
        rssi: d.rssi,
        profile: profile));
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
        subtitle: Text(busy ? _stage : subtitle,
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
