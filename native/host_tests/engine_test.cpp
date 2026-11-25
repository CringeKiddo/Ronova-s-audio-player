#include <cmath>
#include <cstdio>
#include <fstream>
#include <thread>
#include <chrono>
#include "ronova_audio_engine.h"
#include "ronova_dsp_bridge.h"
using namespace std::chrono_literals;
static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { ++failures; std::printf("FAIL: "); } else std::printf("ok:   "); std::printf(__VA_ARGS__); std::printf("\n"); } while (0)
static void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// zero-crossing frequency of channel 0 over the most recent `ms` of captured audio
static double capturedFreq(int ms) {
  auto& c = oboe::capture(); std::lock_guard<std::mutex> l(c.m);
  int rate = c.rate; size_t n = std::min<size_t>(c.samples.size() / 2, (size_t)rate * ms / 1000); if (n < 100) return 0;
  size_t start = c.samples.size() / 2 - n; int zc = 0;
  for (size_t i = start + 1; i < start + n; ++i) if (c.samples[2*(i-1)] < 0 && c.samples[2*i] >= 0) ++zc;
  return zc * 1000.0 / ms;
}
static double capturedPeak(int ms) {
  auto& c = oboe::capture(); std::lock_guard<std::mutex> l(c.m);
  int rate = c.rate; size_t n = std::min<size_t>(c.samples.size() / 2, (size_t)rate * ms / 1000); double pk = 0;
  for (size_t i = c.samples.size() / 2 - n; i < c.samples.size() / 2; ++i) pk = std::max<double>(pk, std::fabs(c.samples[2*i]));
  return pk;
}

int main() {
  { std::ofstream f("/tmp/ronova_fake.mp3", std::ios::binary); f << "fake audio bytes"; }
  CHECK(ronova_engine_init(48000, 192) == RONOVA_OK, "engine init");
  CHECK(ronova_load_file("/nonexistent.mp3") == RONOVA_ERR_FILE_NOT_FOUND, "missing file -> FILE_NOT_FOUND");
  CHECK(ronova_load_file("/tmp/ronova_fake.mp3") == RONOVA_OK, "load fake 10 s track");
  CHECK(ronova_get_duration_ms() == 10000, "duration %lld ms", (long long)ronova_get_duration_ms());
  CHECK(ronova_get_position_ms() == 0, "position 0 after load (%lld)", (long long)ronova_get_position_ms());

  oboe::capture().clear();
  ronova_play(); sleepMs(1200);
  long long p1 = ronova_get_position_ms();
  CHECK(ronova_is_playing() == 1, "is playing");
  CHECK(p1 > 800 && p1 < 1500, "position after ~1.2 s of play: %lld ms", p1);
  CHECK(std::fabs(capturedFreq(300) - 1000) < 40, "bit-exact path plays a 1 kHz tone (%.0f Hz), stream at %d Hz", capturedFreq(300), oboe::capture().rate.load());
  CHECK(capturedPeak(300) > 0.45 && capturedPeak(300) < 0.52, "level preserved (peak %.3f)", capturedPeak(300));

  ronova_pause(); sleepMs(300); long long pp = ronova_get_position_ms(); sleepMs(500);
  CHECK(std::llabs(ronova_get_position_ms() - pp) < 20 && ronova_is_playing() == 0, "paused: position frozen at %lld ms", pp);

  ronova_seek_ms(6000);
  CHECK(std::llabs(ronova_get_position_ms() - 6000) < 5, "seek reports target immediately (%lld)", (long long)ronova_get_position_ms());
  ronova_play(); sleepMs(900);
  long long p2 = ronova_get_position_ms();
  CHECK(p2 > 6500 && p2 < 7100, "after seek to 6000 + 0.9 s play: %lld ms", p2);
  CHECK(std::fabs(capturedFreq(300) - 1000) < 40, "tone intact after sample-accurate seek (%.0f Hz)", capturedFreq(300));

  ronova_seek_ms(1000); sleepMs(300);
  // Tape mode: reverb on + 0.8x -> pitch drops to 800 Hz, position advances at 0.8x.
  ronova_set_room_space(0.2f); ronova_set_speed(0.8f); ronova_set_reverb_enabled(1); sleepMs(900);
  long long t0 = ronova_get_position_ms(); sleepMs(1000); long long t1 = ronova_get_position_ms();
  CHECK(std::fabs((t1 - t0) / 1000.0 - 0.8) < 0.1, "tape mode 0.8x: position advanced %.2f s per second", (t1 - t0) / 1000.0);
  { double f = capturedFreq(500); CHECK(std::fabs(f - 800) < 60, "tape mode pitch followed speed: %.0f Hz (want ~800)", f); }

  // Back to pitch-preserving tempo (fake stretcher is naive, so only check timing here).
  ronova_set_reverb_enabled(0); sleepMs(900);
  long long u0 = ronova_get_position_ms(); sleepMs(1000); long long u1 = ronova_get_position_ms();
  CHECK(std::fabs((u1 - u0) / 1000.0 - 0.8) < 0.12, "tempo mode 0.8x: position advanced %.2f s per second", (u1 - u0) / 1000.0);
  CHECK(u0 >= t1 - 100, "mode switch did not jump backwards (%lld -> %lld)", t1, u0);
  ronova_set_speed(1.0f); sleepMs(900);
  { long long a = ronova_get_position_ms(); sleepMs(1000); long long b = ronova_get_position_ms(); CHECK(std::fabs((b - a) / 1000.0 - 1.0) < 0.1, "speed back to 1.0: %.2f s/s", (b - a) / 1000.0); }

  // End of track.
  ronova_seek_ms(9300); ronova_play(); sleepMs(1800);
  CHECK(ronova_is_playing() == 0 && ronova_get_position_ms() == 10000, "track end: stopped, position %lld", (long long)ronova_get_position_ms());
  ronova_play(); sleepMs(600);
  CHECK(ronova_get_position_ms() < 1500 && ronova_is_playing() == 1, "play after end restarts from the top (%lld ms)", (long long)ronova_get_position_ms());

  // Volume upscaler: +24 dB must stay under the -0.1 dBFS ceiling, GR meter active.
  ronova_set_volume_upscaler_gain(24.0f); sleepMs(700);
  CHECK(capturedPeak(300) <= 0.9885 + 1e-4, "+24 dB upscaler peak %.4f (ceiling 0.9885)", capturedPeak(300));
  CHECK(ronova_get_peak_reduction_db() > 3.0f, "peak reduction meter %.1f dB", ronova_get_peak_reduction_db());
  ronova_set_volume_upscaler_gain(0.0f); ronova_set_master_volume(0.5f); sleepMs(500);
  CHECK(std::fabs(capturedPeak(200) - 0.25) < 0.03, "master volume 0.5 -> peak %.3f", capturedPeak(200));
  ronova_set_master_volume(1.0f);

  // Pre-amp trim (-12..+12 dB, in front of the EQ): -6.02 dB halves the level, +6.02 dB doubles it.
  ronova_set_preamp_db(-6.0206f); sleepMs(500);
  CHECK(std::fabs(capturedPeak(200) - 0.25) < 0.03, "pre-amp -6 dB -> peak %.3f (want ~0.25)", capturedPeak(200));
  ronova_set_preamp_db(6.0206f); sleepMs(500);
  CHECK(std::fabs(capturedPeak(200) - 1.0) < 0.06, "pre-amp +6 dB -> peak %.3f (want ~1.00)", capturedPeak(200));
  ronova_set_preamp_db(99.0f); sleepMs(500);
  CHECK(capturedPeak(200) <= 0.9885 + 1e-4, "pre-amp +12 dB (clamped from 99) stays under the limiter ceiling (peak %.4f)", capturedPeak(200));
  ronova_set_preamp_db(0.0f); sleepMs(500);
  CHECK(std::fabs(capturedPeak(200) - 0.5) < 0.01, "pre-amp back at 0 dB is transparent (peak %.3f)", capturedPeak(200));

  // Ronova mode: engages without touching playback, then disengages.
  ronova_set_hardware_profile(RONOVA_HW_PROFILE_BLUETOOTH);
  CHECK(ronova_engage_ronova_mode(1) == RONOVA_OK, "engage Ronova mode (Bluetooth profile)");
  sleepMs(600); CHECK(ronova_is_playing() == 1 && capturedPeak(200) > 0.2, "still playing in Ronova mode (peak %.3f)", capturedPeak(200));
  CHECK(ronova_engage_ronova_mode(0) == RONOVA_OK, "disengage Ronova mode");

  // Rapid parameter hammering from another thread while audio runs (race check; run under TSAN separately).
  std::thread hammer([] { for (int i = 0; i < 400; ++i) { ronova_set_eq_band(i % 16, 100 + i * 20.0f, (i % 13) - 6.0f, 1.4f); ronova_set_room_space((i % 10) / 10.0f);
      ronova_set_sub_bass_boost((i % 7) / 7.0f); ronova_set_stereo_width((i % 9) / 4.0f); ronova_set_speed(0.9f + (i % 5) * 0.02f); sleepMs(2); } });
  for (int i = 0; i < 12; ++i) { ronova_seek_ms((i * 777) % 8000); sleepMs(60); }
  hammer.join(); sleepMs(300);
  CHECK(ronova_is_playing() == 1 || ronova_get_position_ms() >= 9000, "survived parameter + seek hammering (pos %lld)", (long long)ronova_get_position_ms());

  std::printf("diagnostics: %s\n", ronova_get_diagnostics());
  ronova_engine_shutdown();
  CHECK(ronova_is_playing() == 0, "shutdown");
  ronova_engine_init(44100, 192); CHECK(ronova_load_file("/tmp/ronova_fake.mp3") == RONOVA_OK, "re-init + reload works"); ronova_engine_shutdown();
  std::printf("\n%s (%d failures)\n", failures ? "ENGINE TESTS FAILED" : "ENGINE TESTS PASSED", failures);
  return failures;
}
