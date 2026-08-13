// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

// Unit tests for the pure-logic pieces of BLE Explorer.
//
// The UI (ScanScreen/HuntScreen) needs live BLE platform channels that don't
// exist in the test VM, so widget-pumping isn't meaningful here. The signal
// math, however, is plain Dart and is exactly the part worth pinning down.

import 'package:flutter_test/flutter_test.dart';

import 'package:ble_explorer/ble/rssi_smoother.dart';

void main() {
  group('RssiSmoother', () {
    test('first sample passes through unchanged', () {
      final s = RssiSmoother(alpha: 0.25);
      expect(s.value, isNull);
      expect(s.add(-60), -60);
      expect(s.value, -60);
    });

    test('EMA moves toward new samples by alpha', () {
      final s = RssiSmoother(alpha: 0.25);
      s.add(-60); // seed
      // v + alpha * (sample - v) = -60 + 0.25 * (-40 - -60) = -55
      expect(s.add(-40), closeTo(-55, 1e-9));
    });

    test('a steady stream converges toward the true value', () {
      final s = RssiSmoother(alpha: 0.25);
      s.add(-90); // seed far
      for (var i = 0; i < 100; i++) {
        s.add(-50);
      }
      expect(s.value, closeTo(-50, 0.5));
    });

    test('smoothing rejects a single-sample spike', () {
      final s = RssiSmoother(alpha: 0.25);
      s.add(-70);
      final afterSpike = s.add(-30); // +40 dBm jump
      // Output should lag well behind the raw spike.
      expect(afterSpike, greaterThan(-70));
      expect(afterSpike, lessThan(-50));
    });

    test('reset clears state', () {
      final s = RssiSmoother(alpha: 0.25);
      s.add(-60);
      s.reset();
      expect(s.value, isNull);
      expect(s.add(-80), -80);
    });

    test('higher alpha is snappier than lower alpha', () {
      final slow = RssiSmoother(alpha: 0.1)..add(-80);
      final fast = RssiSmoother(alpha: 0.5)..add(-80);
      final slowOut = slow.add(-40);
      final fastOut = fast.add(-40);
      // Both move toward -40; the faster one gets there quicker (less negative).
      expect(fastOut, greaterThan(slowOut));
    });
  });
}
