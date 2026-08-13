// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

/// Variable-cadence "tick" scheduler — the timing brain of the Geiger click
/// engine, with no audio dependency so it can be unit-tested.
///
/// It fires [onTick] on a self-rescheduling timer whose interval shrinks as the
/// intensity (proximity, 0..1) rises. The load-bearing invariant, learned the
/// hard way on-device: **updating the intensity must not cancel a pending
/// tick.** RSSI updates arrive ~3x/sec (every ~300 ms over GATT), which is far
/// more often than the click interval when the target is more than arm's reach
/// away (up to 1500 ms). If every update did a cancel-and-restart, the timer
/// would be perpetually reset and never fire — silence. Instead, intensity
/// updates only change the value and *start* the loop if idle; the running loop
/// reads the latest intensity on its own next tick.
class ClickScheduler {
  ClickScheduler({
    required this.onTick,
    this.minIntervalMs = 55.0, // fastest, right on top of it
    this.maxIntervalMs = 1500.0, // slowest, faint contact
    this.floor = 0.02, // below this: silence, not a slow tick
  });

  final void Function() onTick;
  final double minIntervalMs;
  final double maxIntervalMs;
  final double floor;

  Timer? _timer;
  bool _muted = false;
  double _t = 0.0;

  bool get isRunning => _timer != null;
  double get intensity => _t;

  /// The interval the *next* tick would use at the current intensity.
  int currentIntervalMs() {
    // Ease so the cadence ramps up sharply near the target — more satisfying.
    final eased = _t * _t;
    return (maxIntervalMs + (minIntervalMs - maxIntervalMs) * eased).round();
  }

  void setMuted(bool value) {
    _muted = value;
    if (value) {
      _stop();
    } else {
      _ensureRunning();
    }
  }

  /// Feed the smoothed proximity in [0, 1].
  void setIntensity(double t) {
    _t = t.clamp(0.0, 1.0);
    if (_muted || _t < floor) {
      _stop();
    } else {
      _ensureRunning();
    }
  }

  void _ensureRunning() {
    if (_timer == null) _scheduleNext();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    _timer?.cancel();
    if (_muted || _t < floor) {
      _timer = null;
      return;
    }
    _timer = Timer(Duration(milliseconds: currentIntervalMs()), () {
      onTick();
      _timer = null; // mark idle before scheduling the next tick
      _scheduleNext();
    });
  }

  void dispose() => _stop();
}
