// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

/// Exponential moving average for RSSI.
///
/// Raw BLE RSSI bounces roughly +/-10 dBm even while standing still, so
/// smoothing is mandatory, not polish. Alpha trades responsiveness against
/// flicker: higher = snappier but jumpier, lower = smoother but laggier.
/// 0.25 is a decent starting point for a hand-in-hand hunt.
class RssiSmoother {
  RssiSmoother({this.alpha = 0.25});

  final double alpha;
  double? _value;

  double add(double sample) {
    final v = _value;
    _value = (v == null) ? sample : v + alpha * (sample - v);
    return _value!;
  }

  double? get value => _value;
  void reset() => _value = null;
}
