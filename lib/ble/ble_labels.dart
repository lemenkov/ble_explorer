// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Curated subset of Bluetooth SIG "Company Identifiers" -> maker name.
/// The full authoritative list lives in the SIG's Assigned Numbers document;
/// this covers the makers you actually see advertising in a flat. Extend freely.
const Map<int, String> kCompanyIds = {
  0x0006: 'Microsoft',
  0x004C: 'Apple',
  0x0075: 'Samsung',
  0x00E0: 'Google',
  0x0059: 'Nordic Semiconductor',
  0x0157: 'Xiaomi',
  0x012D: 'Sony',
  0x009E: 'Bose',
  0x0087: 'Garmin',
  0x00CD: 'Tile',
  0x004F: 'Logitech',
  0x027D: 'Huawei',
  0x02E5: 'Espressif', // ESP32 & friends
  0x0499: 'Ruuvi',
  0x0171: 'Amazon',
  0x0201: 'JBL / Harman',
  0x0A12: 'Sonos',
  0x038F: 'Xiaomi (Mi)',
  0x0131: 'Cypress / Infineon',
  0x0303: 'Fitbit',
  0x00D2: 'Polar',
  0x0060: 'Realtek',
  0x000F: 'Broadcom',
  0x001D: 'Qualcomm',
  0x0072: 'Texas Instruments',
  0x0822: 'Shenzhen (generic OEM)',
  0x05A7: 'Anker',
};

/// Common GATT service UUIDs (16-bit short form) -> human "what is it".
/// Advertised service UUIDs often reveal a device's *kind* even before you
/// connect. Keyed by the lowercased 16-bit hex (e.g. "180d").
const Map<String, String> kServiceKinds = {
  '180d': 'Heart-rate sensor',
  '180f': 'Battery service',
  '1809': 'Health thermometer',
  '181a': 'Environmental sensor',
  '1816': 'Cycling speed/cadence',
  '1818': 'Cycling power',
  '1802': 'Proximity / Find-me tag',
  '1812': 'HID (keyboard/mouse)',
  'fd6f': 'Exposure notification',
  'feaa': 'Eddystone beacon',
  'fe9f': 'Google device',
  'fd5a': 'Tracking tag',
  'fe07': 'Sonos',
  'fdcd': 'Xiaomi sensor',
};

class BleSummary {
  BleSummary({
    required this.name,
    required this.maker,
    required this.kind,
    required this.privacyHint,
  });

  final String name;
  final String? maker;
  final String? kind;
  final String? privacyHint;
}

BleSummary summariseAdvertisement(ScanResult r) {
  final adv = r.advertisementData;

  final advName = adv.advName;
  final platName = r.device.platformName;
  final name = advName.isNotEmpty
      ? advName
      : (platName.isNotEmpty ? platName : '(unknown device)');

  String? maker;
  if (adv.manufacturerData.isNotEmpty) {
    final companyId = adv.manufacturerData.keys.first;
    maker = kCompanyIds[companyId] ??
        '0x${companyId.toRadixString(16).padLeft(4, '0')}';
  }

  String? kind;
  for (final g in adv.serviceUuids) {
    final short = _short16(g);
    if (short != null && kServiceKinds.containsKey(short)) {
      kind = kServiceKinds[short];
      break;
    }
  }

  // Heuristic privacy read. Real public-vs-random address-type detection needs
  // a platform channel on Android (deferred to v2); this is the soft signal:
  // a device advertising manufacturer data but withholding a name is often
  // being deliberately quiet about its identity.
  String? privacyHint;
  if (advName.isEmpty && platName.isEmpty) {
    privacyHint = 'no name advertised — may be hiding its identity';
  }

  return BleSummary(
    name: name,
    maker: maker,
    kind: kind,
    privacyHint: privacyHint,
  );
}

/// Return the lowercased 16-bit short form of a Guid if it sits inside the
/// standard Bluetooth base UUID, else null.
String? _short16(Guid g) {
  final s = g.str.toLowerCase();
  if (s.length == 4) return s; // already short form on some platforms
  // 0000XXXX-0000-1000-8000-00805f9b34fb
  final m = RegExp(r'^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$')
      .firstMatch(s);
  return m?.group(1);
}
