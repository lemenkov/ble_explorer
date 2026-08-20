// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble/click_engine.dart';
import 'ble/rssi_smoother.dart';

/// Screen 2 — the hunt. Locks onto one device, drives a full-screen
/// blue(cold) -> red(hot) colour off smoothed RSSI, and fires Geiger clicks
/// whose cadence rises as you close in.
///
/// Source strategy (best-available, chosen automatically):
///   1. Start a filtered advertisement scan for this device -> always works,
///      but sparse/slow, cadence depends on how often the device advertises.
///   2. Try a GATT connection in parallel. If it connects, poll readRssi()
///      ~3x/sec for a fast, smooth signal and stop leaning on advertisements.
///      If it drops or the device refuses, fall back to the advertisement scan.
class HuntScreen extends StatefulWidget {
  const HuntScreen({super.key, required this.device, required this.label});

  final BluetoothDevice device;
  final String label;

  @override
  State<HuntScreen> createState() => _HuntScreenState();
}

class _HuntScreenState extends State<HuntScreen> {
  // Tunables. "near" = arm's reach; "far" = faint contact.
  static const double _farDbm = -95;
  static const double _nearDbm = -45;

  final RssiSmoother _smoother = RssiSmoother(alpha: 0.25);
  final ClickEngine _clicks = ClickEngine();

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _gattPoll;

  double _t = 0.0; // 0..1 proximity
  int? _rawRssi;
  double? _smoothedRssi;
  String _source = 'searching…';
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    _start();
  }

  Future<void> _start() async {
    await _clicks.init();
    await _startAdvScan(); // always-available baseline
    _tryConnect(); // opportunistic upgrade to the fast GATT source
  }

  Future<void> _startAdvScan() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId == widget.device.remoteId) {
          _onRssi(r.rssi, 'advertisement · slow');
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withRemoteIds: [widget.device.remoteId.str],
        continuousUpdates: true,
        timeout: const Duration(minutes: 30),
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (_) {/* surfaced as a stale source label */}
  }

  Future<void> _tryConnect() async {
    _connSub = widget.device.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.connected) {
        // We have the good source now — stop leaning on advertisements.
        await FlutterBluePlus.stopScan();
        _startGattPolling();
      } else if (state == BluetoothConnectionState.disconnected) {
        _gattPoll?.cancel();
        _gattPoll = null;
        // Fall back to advertisements if we lose the link.
        if (mounted) await _startAdvScan();
      }
    });

    try {
      await widget.device.connect(
        timeout: const Duration(seconds: 8),
        autoConnect: false,
      );
    } catch (_) {
      // Many devices refuse connections — that's fine, we stay on adv scan.
    }
  }

  void _startGattPolling() {
    _gattPoll?.cancel();
    _gattPoll = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      try {
        final rssi = await widget.device.readRssi();
        _onRssi(rssi, 'live · GATT · fast');
      } catch (_) {/* transient; next tick retries */}
    });
  }

  void _onRssi(int rssi, String source) {
    final smoothed = _smoother.add(rssi.toDouble());
    final t = ((smoothed - _farDbm) / (_nearDbm - _farDbm)).clamp(0.0, 1.0);
    _clicks.setIntensity(t);
    if (!mounted) return;
    setState(() {
      _rawRssi = rssi;
      _smoothedRssi = smoothed;
      _t = t;
      _source = source;
    });
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _clicks.setMuted(_muted);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scanSub?.cancel();
    _connSub?.cancel();
    _gattPoll?.cancel();
    _clicks.dispose();
    FlutterBluePlus.stopScan();
    widget.device.disconnect().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cold = const Color(0xFF0A2C7A);
    final hot = const Color(0xFFC01F1F);
    final bg = Color.lerp(cold, hot, _t)!;
    final shadow = [
      const Shadow(blurRadius: 8, color: Colors.black54, offset: Offset(0, 1)),
    ];

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white),
                onPressed: _toggleMute,
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          shadows: shadow)),
                  const SizedBox(height: 8),
                  Text(widget.device.remoteId.str,
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          shadows: shadow)),
                  const SizedBox(height: 40),
                  Text(
                    _smoothedRssi == null
                        ? '—'
                        : '${_smoothedRssi!.round()} dBm',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 64,
                        fontWeight: FontWeight.w200,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        shadows: shadow),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _rawRssi == null ? '' : 'raw ${_rawRssi} dBm',
                    style: TextStyle(color: Colors.white54, shadows: shadow),
                  ),
                  const SizedBox(height: 28),
                  _sourceChip(shadow),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(List<Shadow> shadow) {
    final live = _source.startsWith('live');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.25),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(live ? Icons.bolt : Icons.wifi_tethering,
              size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(_source,
              style: TextStyle(color: Colors.white, shadows: shadow)),
        ],
      ),
    );
  }
}
