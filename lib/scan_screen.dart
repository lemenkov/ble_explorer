// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble/ble_labels.dart';
import 'hunt_screen.dart';

/// Screen 1 — the radar. Lists everything advertising nearby, sorted by signal,
/// with maker + kind + a privacy hint. Tap a row to hunt it.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final Map<String, ScanResult> _seen = {}; // keyed by remoteId string
  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  String? _error;
  bool _permsOk = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (!(await FlutterBluePlus.isSupported)) {
      setState(() => _error = 'This device has no Bluetooth LE support.');
      return;
    }

    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      setState(() => _adapter = s);
      if (s == BluetoothAdapterState.on && _permsOk) {
        _startScan();
      }
    });

    final ok = await _ensurePermissions();
    setState(() => _permsOk = ok);
    if (!ok) {
      setState(() => _error =
          'Bluetooth scan/connect permission denied. Enable it in Settings.');
      return;
    }

    // On Android you can nudge the adapter on; on iOS this is a no-op.
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {/* user may decline; adapterState listener handles it */}
    }
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true; // iOS handled by Info.plist prompts
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // needed on Android < 12; capped in manifest
    ].request();
    final scan = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connect = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    return scan && connect;
  }

  Future<void> _startScan() async {
    if (FlutterBluePlus.isScanningNow) return;
    _resultsSub?.cancel();
    _resultsSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        _seen[r.device.remoteId.str] = r;
      }
      if (mounted) setState(() {});
    }, onError: (e) {
      if (mounted) setState(() => _error = 'Scan error: $e');
    });

    try {
      await FlutterBluePlus.startScan(
        // Live radar: we keep reading rssi/timestamp, so this must be on.
        continuousUpdates: true,
        // Drop devices we haven't heard from recently — keeps the list honest.
        removeIfGone: const Duration(seconds: 15),
        // Long timeout so the radar just runs; Stop button ends it.
        timeout: const Duration(minutes: 30),
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start scan: $e');
    }
  }

  Future<void> _restart() async {
    // Android limits startScan to 5x / 30s; the button is best used sparingly.
    setState(() => _seen.clear());
    await FlutterBluePlus.stopScan();
    await _startScan();
  }

  @override
  void dispose() {
    _resultsSub?.cancel();
    _adapterSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _seen.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi)); // strongest first

    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio world'),
        actions: [
          IconButton(
            tooltip: 'Rescan',
            onPressed: _permsOk ? _restart : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(devices),
    );
  }

  Widget _buildBody(List<ScanResult> devices) {
    if (_error != null) {
      return _centeredNote(_error!, icon: Icons.error_outline);
    }
    if (_adapter != BluetoothAdapterState.on) {
      return _centeredNote('Bluetooth is off. Turn it on to explore.',
          icon: Icons.bluetooth_disabled);
    }
    if (devices.isEmpty) {
      return _centeredNote('Listening…\nnothing in range yet.',
          icon: Icons.radar);
    }
    return ListView.separated(
      itemCount: devices.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _deviceTile(devices[i]),
    );
  }

  Widget _deviceTile(ScanResult r) {
    final s = summariseAdvertisement(r);
    final subtitleParts = <String>[
      if (s.maker != null) s.maker!,
      if (s.kind != null) s.kind!,
      r.device.remoteId.str,
    ];

    return ListTile(
      leading: _signalGlyph(r.rssi),
      title: Text(s.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitleParts.join('  ·  '),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (s.privacyHint != null)
            Text(s.privacyHint!,
                style: const TextStyle(
                    color: Colors.amberAccent, fontSize: 12)),
        ],
      ),
      trailing: Text('${r.rssi} dBm',
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => HuntScreen(device: r.device, label: s.name),
        ));
      },
    );
  }

  Widget _signalGlyph(int rssi) {
    // -95 (far) .. -45 (near) mapped to 0..4 bars.
    final t = ((rssi + 95) / 50).clamp(0.0, 1.0);
    final bars = (t * 4).round();
    final color = Color.lerp(
        const Color(0xFF3B6FE0), const Color(0xFFE0483B), t)!;
    return Icon(
      switch (bars) {
        0 => Icons.signal_cellular_alt_1_bar,
        1 => Icons.signal_cellular_alt_1_bar,
        2 => Icons.signal_cellular_alt_2_bar,
        _ => Icons.signal_cellular_alt,
      },
      color: color,
    );
  }

  Widget _centeredNote(String text, {required IconData icon}) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54)),
          ],
        ),
      );
}
