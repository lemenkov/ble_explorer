// SPDX-FileCopyrightText: 2026 Peter Lemenkov <lemenkov@gmail.com>
//
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'click_scheduler.dart';

/// Parking-sensor / Geiger-counter audio feedback.
///
/// A single short "tick" sample is synthesised at startup (no bundled asset)
/// and replayed by a [ClickScheduler] whose interval shrinks as the target gets
/// closer. flutter_soloud gives low-latency, fire-and-forget playback — the
/// click is ~9.5 ms and the fastest cadence is 55 ms, so ticks never overlap,
/// but the latency still has to be tight for the effect to feel like a real
/// Geiger counter.
///
/// This class owns only the *audio*; the cadence timing (and the subtle
/// don't-starve-the-timer invariant) lives in [ClickScheduler], where it is
/// unit-tested.
///
/// (Replaces the discontinued `soundpool`, whose Android plugin still used the
/// long-removed Flutter v1-embedding `Registrar` API and no longer compiles.)
class ClickEngine {
  ClickEngine() {
    _scheduler = ClickScheduler(onTick: _playClick);
  }

  final SoLoud _soloud = SoLoud.instance;
  AudioSource? _source;
  late final ClickScheduler _scheduler;

  Future<void> init() async {
    if (!_soloud.isInitialized) {
      // lowLatency defaults to true — exactly what a click engine wants.
      await _soloud.init(sampleRate: 44100);
    }
    _source = await _soloud.loadMem('geiger_click.wav', _buildClickWav());
  }

  void setMuted(bool value) => _scheduler.setMuted(value);

  /// Feed the smoothed proximity in [0, 1].
  void setIntensity(double t) => _scheduler.setIntensity(t);

  void _playClick() {
    final src = _source;
    if (src != null && _soloud.isInitialized) _soloud.play(src);
  }

  void dispose() {
    _scheduler.dispose();
    _source = null;
    // Tear the engine down so we release the audio device / native memory when
    // the hunt ends. A fresh HuntScreen re-inits on its way in.
    if (_soloud.isInitialized) _soloud.deinit();
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
