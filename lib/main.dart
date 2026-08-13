// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'scan_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep BLE logs quiet in release; bump to LogLevel.verbose while debugging.
  FlutterBluePlus.setLogLevel(LogLevel.warning, color: false);
  runApp(const BleExplorerApp());
}

class BleExplorerApp extends StatelessWidget {
  const BleExplorerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'BLE Explorer',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
        listTileTheme: const ListTileThemeData(iconColor: Colors.white70),
      ),
      home: const ScanScreen(),
    );
  }
}
