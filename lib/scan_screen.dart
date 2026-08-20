// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble/ble_labels.dart';
import 'ble/name_resolver.dart';
import 'ble/rssi_smoother.dart';
import 'hunt_screen.dart';

enum SortMode { signal, name }

enum _ResolveState { none, resolving, resolved, failed }

/// Per-device row state. Keeps a smoothed RSSI so the sort key doesn't bounce
/// on every advertisement packet, and caches a GATT-resolved name if we got one.
class _Entry {
  _Entry(this.result) {
    update(result);
  }

  ScanResult result;
  final RssiSmoother smoother = RssiSmoother(alpha: 0.3);
  double smoothed = 0;
  DateTime lastSeen = DateTime.now();
  String? resolvedName;
  _ResolveState resolve = _ResolveState.none;

  void update(ScanResult r) {
    result = r;
    smoothed = smoother.add(r.rssi.toDouble());
    lastSeen = DateTime.now();
  }

  String get id => result.device.remoteId.str;
  bool get connectable => result.advertisementData.connectable;

  String? get advertisedName {
    final a = result.advertisementData.advName;
    if (a.isNotEmpty) return a;
    final p = result.device.platformName;
    if (p.isNotEmpty) return p;
    return null;
  }

  String? get displayName =>
      (resolvedName != null && resolvedName!.isNotEmpty)
          ? resolvedName
          : advertisedName;

  bool get named => displayName != null;

  /// Sort key for signal mode: 5-dBm buckets so the order only changes when a
  /// device's smoothed signal crosses a boundary — kills the micro-reshuffle.
  int get signalBucket => (smoothed / 5).round();
}

/// Screen 1 — the radar. Groups named devices above anonymous ones, smooths the
/// signal, offers signal/name sort + a freeze, and can connect to read a hidden
/// name on demand.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final Map<String, _Entry> _entries = {};
  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  String? _error;
  bool _permsOk = false;

  SortMode _sort = SortMode.signal;
  bool _frozen = false;
  bool _autoResolve = false;

  // Frozen display order (per group). Captured when freeze turns on.
  List<String> _frozenNamed = [];
  List<String> _frozenAnon = [];

  // Serialized name-resolution queue.
  final List<String> _resolveQueue = [];
  bool _resolveBusy = false;

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
      if (s == BluetoothAdapterState.on && _permsOk) _startScan();
    });
    final ok = await _ensurePermissions();
    setState(() => _permsOk = ok);
    if (!ok) {
      setState(() => _error =
          'Bluetooth scan/connect permission denied. Enable it in Settings.');
      return;
    }
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {/* adapterState listener handles the rest */}
    }
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // Android < 12 only; capped in manifest
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
        final id = r.device.remoteId.str;
        final e = _entries[id];
        if (e == null) {
          _entries[id] = _Entry(r);
        } else {
          e.update(r);
        }
      }
      if (_autoResolve) _enqueueEligible();
      if (mounted) setState(() {});
    }, onError: (e) {
      if (mounted) setState(() => _error = 'Scan error: $e');
    });

    try {
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 15),
        timeout: const Duration(minutes: 30),
        androidScanMode: AndroidScanMode.lowLatency,
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start scan: $e');
    }
  }

  Future<void> _restart() async {
    setState(() => _entries.clear());
    await FlutterBluePlus.stopScan();
    await _startScan();
  }

  // ---- sorting / grouping ----

  List<_Entry> get _liveEntries => _entries.values.toList();

  List<String> _sortedIds(bool named) {
    final list = _liveEntries.where((e) => e.named == named).toList();
    switch (_sort) {
      case SortMode.signal:
        list.sort((a, b) {
          final c = b.signalBucket.compareTo(a.signalBucket); // strongest first
          if (c != 0) return c;
          return _tiebreak(a, b);
        });
      case SortMode.name:
        list.sort((a, b) {
          final an = (a.displayName ?? a.id).toLowerCase();
          final bn = (b.displayName ?? b.id).toLowerCase();
          final c = an.compareTo(bn);
          if (c != 0) return c;
          return a.id.compareTo(b.id);
        });
    }
    return list.map((e) => e.id).toList();
  }

  int _tiebreak(_Entry a, _Entry b) {
    final an = (a.displayName ?? a.id).toLowerCase();
    final bn = (b.displayName ?? b.id).toLowerCase();
    final c = an.compareTo(bn);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  /// Keep frozen order, drop devices that aged out, append newly-seen at the end.
  List<String> _applyFreeze(List<String> frozen, List<String> live) {
    final liveSet = live.toSet();
    final kept = frozen.where(liveSet.contains).toList();
    final keptSet = kept.toSet();
    for (final id in live) {
      if (!keptSet.contains(id)) kept.add(id);
    }
    return kept;
  }

  void _toggleFreeze() {
    setState(() {
      _frozen = !_frozen;
      if (_frozen) {
        _frozenNamed = _sortedIds(true);
        _frozenAnon = _sortedIds(false);
      }
    });
  }

  // ---- name resolution ----

  void _enqueueResolve(String id) {
    final e = _entries[id];
    if (e == null || !e.connectable) return;
    if (e.resolve == _ResolveState.resolving ||
        e.resolve == _ResolveState.resolved) return;
    if (_resolveQueue.contains(id)) return;
    _resolveQueue.add(id);
    _pumpResolve();
  }

  void _enqueueEligible() {
    for (final e in _liveEntries) {
      if (!e.named &&
          e.connectable &&
          e.resolve == _ResolveState.none &&
          !_resolveQueue.contains(e.id)) {
        _resolveQueue.add(e.id);
      }
    }
    _pumpResolve();
  }

  Future<void> _pumpResolve() async {
    if (_resolveBusy) return;
    _resolveBusy = true;
    while (_resolveQueue.isNotEmpty) {
      final id = _resolveQueue.removeAt(0);
      final e = _entries[id];
      if (e == null) continue;
      setState(() => e.resolve = _ResolveState.resolving);
      final name = await resolveDeviceName(e.result.device);
      if (!mounted) return;
      setState(() {
        if (name != null) {
          e.resolvedName = name;
          e.resolve = _ResolveState.resolved;
        } else {
          e.resolve = _ResolveState.failed;
        }
      });
      await Future.delayed(const Duration(milliseconds: 250)); // breathe
    }
    _resolveBusy = false;
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
    var namedIds = _sortedIds(true);
    var anonIds = _sortedIds(false);
    if (_frozen) {
      namedIds = _applyFreeze(_frozenNamed, namedIds);
      anonIds = _applyFreeze(_frozenAnon, anonIds);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio world'),
        actions: [
          IconButton(
            tooltip: _sort == SortMode.signal ? 'Sort: signal' : 'Sort: name',
            onPressed: () => setState(() => _sort =
                _sort == SortMode.signal ? SortMode.name : SortMode.signal),
            icon: Icon(_sort == SortMode.signal
                ? Icons.wifi_tethering
                : Icons.sort_by_alpha),
          ),
          IconButton(
            tooltip: _frozen ? 'Frozen — tap to resume' : 'Freeze order',
            onPressed: _toggleFreeze,
            icon: Icon(_frozen ? Icons.pause_circle : Icons.play_circle),
          ),
          IconButton(
            tooltip: _autoResolve
                ? 'Auto-identify: on'
                : 'Auto-identify hidden names',
            onPressed: () {
              setState(() => _autoResolve = !_autoResolve);
              if (_autoResolve) _enqueueEligible();
            },
            icon: Icon(_autoResolve ? Icons.search : Icons.search_off),
          ),
          IconButton(
            tooltip: 'Rescan',
            onPressed: _permsOk ? _restart : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(namedIds, anonIds),
    );
  }

  Widget _buildBody(List<String> namedIds, List<String> anonIds) {
    if (_error != null) {
      return _centeredNote(_error!, icon: Icons.error_outline);
    }
    if (_adapter != BluetoothAdapterState.on) {
      return _centeredNote('Bluetooth is off. Turn it on to explore.',
          icon: Icons.bluetooth_disabled);
    }
    if (namedIds.isEmpty && anonIds.isEmpty) {
      return _centeredNote('Listening…\nnothing in range yet.',
          icon: Icons.radar);
    }

    final rows = <Widget>[];
    if (namedIds.isNotEmpty) {
      rows.add(_sectionHeader('Named', namedIds.length));
      rows.addAll(namedIds.map(_rowFor));
    }
    if (anonIds.isNotEmpty) {
      rows.add(_sectionHeader('Anonymous', anonIds.length));
      rows.addAll(anonIds.map(_rowFor));
    }
    return ListView(children: rows);
  }

  Widget _sectionHeader(String label, int count) => Container(
        color: Colors.white10,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Text(label.toUpperCase(),
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('$count',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      );

  Widget _rowFor(String id) {
    final e = _entries[id];
    if (e == null) return const SizedBox.shrink();
    final summary = summariseAdvertisement(e.result);
    final subtitleParts = <String>[
      if (summary.maker != null) summary.maker!,
      if (summary.kind != null) summary.kind!,
      e.id,
    ];

    return ListTile(
      key: ValueKey(id),
      leading: _signalGlyph(e.smoothed),
      title: Text(e.displayName ?? '(anonymous)',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitleParts.join('  ·  '),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _trailing(e),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => HuntScreen(
              device: e.result.device,
              label: e.displayName ?? '(anonymous)'),
        ));
      },
    );
  }

  Widget _trailing(_Entry e) {
    final dbm = Text('${e.smoothed.round()} dBm',
        style:
            const TextStyle(fontFeatures: [FontFeature.tabularFigures()]));

    Widget? action;
    if (!e.named && e.connectable) {
      switch (e.resolve) {
        case _ResolveState.resolving:
          action = const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2));
        case _ResolveState.failed:
          action = IconButton(
            tooltip: 'No name available — retry',
            icon: const Icon(Icons.person_off, size: 18, color: Colors.white38),
            onPressed: () => setState(() {
              e.resolve = _ResolveState.none;
              _enqueueResolve(e.id);
            }),
          );
        case _ResolveState.none:
        case _ResolveState.resolved:
          action = IconButton(
            tooltip: 'Identify (connect & read name)',
            icon: const Icon(Icons.badge_outlined, size: 20),
            onPressed: () => _enqueueResolve(e.id),
          );
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [dbm, if (action != null) ...[const SizedBox(width: 4), action]],
    );
  }

  Widget _signalGlyph(double rssi) {
    final t = ((rssi + 95) / 50).clamp(0.0, 1.0);
    final bars = (t * 4).round();
    final color =
        Color.lerp(const Color(0xFF3B6FE0), const Color(0xFFE0483B), t)!;
    return Icon(
      switch (bars) {
        0 || 1 => Icons.signal_cellular_alt_1_bar,
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
