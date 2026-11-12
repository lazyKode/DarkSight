import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleFound {
  const BleFound(this.id, this.name, this.rssi);
  final String id;
  final String name;
  final int rssi;
}

/// Thin wrapper over flutter_blue_plus so the rest of the app never touches
/// the plugin directly and every failure (no adapter, permissions denied,
/// unsupported platform, emulator) turns into a message instead of a crash.
class BleScanner {
  StreamSubscription<List<ScanResult>>? _sub;
  final Map<String, BluetoothDevice> _devices = {};

  /// Returns null on success, or a human-readable reason scanning is
  /// unavailable.
  Future<String?> start(void Function(List<BleFound>) onResults) async {
    try {
      if (!await FlutterBluePlus.isSupported) {
        return 'Bluetooth LE is not available on this device.';
      }
      await _sub?.cancel();
      _sub = FlutterBluePlus.scanResults.listen((results) {
        final found = <BleFound>[];
        for (final r in results) {
          final id = r.device.remoteId.str;
          _devices[id] = r.device;
          var name = r.device.platformName;
          if (name.isEmpty) name = r.advertisementData.advName;
          if (name.isEmpty) continue; // skip anonymous beacons
          found.add(BleFound(id, name, r.rssi));
        }
        onResults(found);
      }, onError: (Object _) {});
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      // startScan returns once scanning has begun; wait for it to finish.
      await FlutterBluePlus.isScanning
          .where((scanning) => !scanning)
          .first
          .timeout(const Duration(seconds: 12), onTimeout: () => false);
      return null;
    } catch (e) {
      return 'BLE scan unavailable: $e';
    }
  }

  Future<void> stop() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
  }

  /// Link-level connect + service discovery. Returns a status line.
  Future<String> connect(String id) async {
    final dev = _devices[id];
    if (dev == null) return 'Device no longer in range.';
    try {
      await dev.connect(timeout: const Duration(seconds: 10));
      final services = await dev.discoverServices();
      return 'Connected, ${services.length} GATT services found.';
    } catch (e) {
      return 'Connect failed: $e';
    }
  }

  Future<void> disconnect(String id) async {
    try {
      await _devices[id]?.disconnect();
    } catch (_) {}
  }
}
