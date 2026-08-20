// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Connect to a device, read the GAP "Device Name" characteristic (0x2A00),
/// and return the decoded name — a way to un-hide a name that isn't in the
/// advertisement. Returns null if the device refuses the connection, has no
/// readable 0x2A00, or the name is empty.
///
/// Honest expectations: privacy-conscious advertisers (Apple, modern phones)
/// are usually non-connectable or expose no useful name here. This mostly wins
/// for peripherals and DIY gear (e.g. ESP32) that keep their name in GATT.
///
/// The caller MUST serialize these — one connection at a time — to avoid
/// thrashing the radio and fighting the ongoing scan.
Future<String?> resolveDeviceName(
  BluetoothDevice device, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  try {
    await device.connect(timeout: timeout, autoConnect: false);
    final services = await device.discoverServices();
    for (final s in services) {
      for (final c in s.characteristics) {
        if (short16(c.uuid) == '2a00' && c.properties.read) {
          final bytes = await c.read();
          final name = utf8.decode(bytes, allowMalformed: true).trim();
          if (name.isNotEmpty) return name;
        }
      }
    }
    return null;
  } catch (_) {
    return null; // refused / timed out / no such characteristic
  } finally {
    try {
      await device.disconnect();
    } catch (_) {/* ignore */}
  }
}

/// Lowercased 16-bit short form of a Guid if it lives in the standard
/// Bluetooth base UUID, else null.
String? short16(Guid g) {
  final s = g.str.toLowerCase();
  if (s.length == 4) return s;
  final m = RegExp(r'^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$')
      .firstMatch(s);
  return m?.group(1);
}
