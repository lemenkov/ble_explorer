// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

// Timing tests for ClickScheduler — the Geiger cadence logic.
//
// The headline test is `frequent intensity updates do not starve the timer`:
// it reproduces the on-device bug where RSSI updates (arriving ~3x/sec over
// GATT) each reset the click timer, so it never fired and the app was silent.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ble_explorer/ble/click_scheduler.dart';

void main() {
  group('ClickScheduler cadence', () {
    test('closer (higher intensity) ticks faster than farther', () {
      final near = ClickScheduler(onTick: () {});
      final far = ClickScheduler(onTick: () {});
      near.setIntensity(0.9);
      far.setIntensity(0.2);
      expect(near.currentIntervalMs(), lessThan(far.currentIntervalMs()));
    });

    test('interval spans the configured envelope', () {
      final s = ClickScheduler(onTick: () {});
      s.setIntensity(0.0);
      expect(s.currentIntervalMs(), 1500); // far end
      s.setIntensity(1.0);
      expect(s.currentIntervalMs(), 55); // near end
    });

    test('below the floor it stays silent (no ticks)', () {
      fakeAsync((async) {
        var ticks = 0;
        final s = ClickScheduler(onTick: () => ticks++, floor: 0.02);
        s.setIntensity(0.0);
        async.elapse(const Duration(seconds: 10));
        expect(ticks, 0);
        expect(s.isRunning, isFalse);
        s.dispose();
      });
    });
  });

  group('ClickScheduler regression: timer starvation', () {
    test('frequent intensity updates do not starve the timer', () {
      fakeAsync((async) {
        var ticks = 0;
        final s = ClickScheduler(onTick: () => ticks++);

        // Simulate a far target (~1.3 s cadence) being polled every 300 ms —
        // the exact GATT-update rate that used to reset the timer forever.
        for (var i = 0; i < 40; i++) {
          s.setIntensity(0.34); // interval ~1333 ms, updates every 300 ms
          async.elapse(const Duration(milliseconds: 300));
        }
        // 40 * 300 ms = 12 s of wall time. At ~1.3 s per tick we expect several
        // clicks; the pre-fix code produced exactly zero.
        expect(ticks, greaterThan(5));
        s.dispose();
      });
    });

    test('a running loop keeps firing while intensity is nudged', () {
      fakeAsync((async) {
        var ticks = 0;
        final s = ClickScheduler(onTick: () => ticks++);
        s.setIntensity(1.0); // 55 ms cadence
        // Nudge intensity every 10 ms (faster than the interval) for 1 s.
        for (var i = 0; i < 100; i++) {
          s.setIntensity(1.0);
          async.elapse(const Duration(milliseconds: 10));
        }
        // ~1000 ms / 55 ms ≈ 18 ticks; certainly more than a handful.
        expect(ticks, greaterThan(10));
        s.dispose();
      });
    });

    test('muting stops ticks; unmuting resumes them', () {
      fakeAsync((async) {
        var ticks = 0;
        final s = ClickScheduler(onTick: () => ticks++);
        s.setIntensity(1.0);
        async.elapse(const Duration(milliseconds: 500));
        final afterRunning = ticks;
        expect(afterRunning, greaterThan(0));

        s.setMuted(true);
        async.elapse(const Duration(seconds: 2));
        expect(ticks, afterRunning); // no new ticks while muted

        s.setMuted(false);
        async.elapse(const Duration(milliseconds: 500));
        expect(ticks, greaterThan(afterRunning)); // resumed
        s.dispose();
      });
    });
  });
}
