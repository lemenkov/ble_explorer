// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:soundpool/soundpool.dart';

/// Parking-sensor / Geiger-counter audio feedback.
///
/// A single short "tick" sample is synthesised at startup (no bundled asset)
/// and replayed on a self-rescheduling timer whose interval shrinks as the
/// target gets closer. soundpool gives low-latency, rapid-fire playback that a
/// normal audio player can't sustain.
class ClickEngine {
  final Soundpool _pool = Soundpool.fromOptions(
    options: const SoundpoolOptions(streamType: StreamType.notification),
  );
  int? _soundId;
  Timer? _timer;
  bool _muted = false;
  double _t = 0.0; // 0 = far/cold, 1 = near/hot

  // Click cadence bounds.
  static const double _minIntervalMs = 55.0; // fastest, right on top of it
  static const double _maxIntervalMs = 1500.0; // slowest, faint contact
  static const double _floor = 0.02; // below this: silence, not a slow tick

  Future<void> init() async {
    _soundId = await _pool.loadUint8List(_buildClickWav());
  }

  bool get muted => _muted;

  void setMuted(bool value) {
    _muted = value;
    if (value) {
      _timer?.cancel();
    } else {
      _reschedule();
    }
  }

  /// Feed the smoothed proximity in [0, 1].
  void setIntensity(double t) {
    _t = t.clamp(0.0, 1.0);
    _reschedule();
  }

  void _reschedule() {
    _timer?.cancel();
    if (_muted || _soundId == null || _t < _floor) return;
    // Ease so the cadence ramps up sharply near the target — more satisfying.
    final eased = _t * _t;
    final interval =
        _maxIntervalMs + (_minIntervalMs - _maxIntervalMs) * eased;
    _timer = Timer(Duration(milliseconds: interval.round()), () {
      final id = _soundId;
      if (id != null) _pool.play(id);
      _reschedule();
    });
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _pool.dispose();
  }

  // ---- click synthesis: a ~9.5 ms decaying noise burst + faint 2.7 kHz tone ----

  Uint8List _buildClickWav() {
    const int sampleRate = 44100;
    const int samples = 420; // ~9.5 ms
    const double decay = 130.0; // exponential decay, in samples
    final rnd = Random(1);
    final pcm = Int16List(samples);
    for (int n = 0; n < samples; n++) {
      final env = exp(-n / decay);
      final noise = rnd.nextDouble() * 2 - 1;
      final tone = sin(2 * pi * 2700 * n / sampleRate);
      final s = env * (0.7 * noise + 0.3 * tone);
      pcm[n] = (s * 32767).clamp(-32768.0, 32767.0).toInt();
    }
    return _wrapWav(pcm, sampleRate);
  }

  Uint8List _wrapWav(Int16List pcm, int sampleRate) {
    final data = pcm.buffer.asUint8List();
    final byteRate = sampleRate * 2; // mono, 16-bit
    final b = BytesBuilder();
    void ascii(String x) => b.add(x.codeUnits);
    void u32(int v) =>
        b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
    void u16(int v) => b.add([v & 255, (v >> 8) & 255]);

    ascii('RIFF');
    u32(36 + data.length);
    ascii('WAVE');
    ascii('fmt ');
    u32(16); // PCM fmt chunk size
    u16(1); // audio format = PCM
    u16(1); // channels = mono
    u32(sampleRate);
    u32(byteRate);
    u16(2); // block align
    u16(16); // bits per sample
    ascii('data');
    u32(data.length);
    b.add(data);
    return b.toBytes();
  }
}
