// C ABI bridge for Dart FFI. Every function declared in ronova_dsp_bridge.h lives here and simply
// forwards to the RonovaAudioEngine singleton.

#include "ronova_dsp_bridge.h"

#include "ronova_audio_engine.h"

using ronova::RonovaAudioEngine;

extern "C" {

// ---- Diagnostics -------------------------------------------------------------------------------

const char* ronova_get_version(void) { return RonovaAudioEngine::version(); }

const char* ronova_get_diagnostics(void) {
  thread_local std::string snapshot;
  snapshot = RonovaAudioEngine::instance().diagnostics();
  return snapshot.c_str();
}

// ---- Engine lifecycle --------------------------------------------------------------------------

int32_t ronova_engine_init(int32_t sample_rate_hz, int32_t frames_per_burst) {
  return RonovaAudioEngine::instance().init(sample_rate_hz, frames_per_burst);
}

void ronova_engine_shutdown(void) { RonovaAudioEngine::instance().shutdown(); }

// ---- Playback & seeking ------------------------------------------------------------------------

int32_t ronova_load_file(const char* utf8_path) { return RonovaAudioEngine::instance().loadFile(utf8_path); }

void ronova_play(void) { RonovaAudioEngine::instance().play(); }

void ronova_pause(void) { RonovaAudioEngine::instance().pause(); }

void ronova_seek_ms(int64_t position_ms) { RonovaAudioEngine::instance().seekMs(position_ms); }

int64_t ronova_get_position_ms(void) { return RonovaAudioEngine::instance().positionMs(); }

int64_t ronova_get_duration_ms(void) { return RonovaAudioEngine::instance().durationMs(); }

int32_t ronova_is_playing(void) { return RonovaAudioEngine::instance().isPlaying() ? 1 : 0; }

// ---- Speed & pitch-linked reverb ---------------------------------------------------------------

void ronova_set_speed(float speed_ratio) { RonovaAudioEngine::instance().setSpeed(speed_ratio); }

void ronova_set_reverb_enabled(int32_t enabled) { RonovaAudioEngine::instance().setReverbEnabled(enabled != 0); }

void ronova_set_room_space(float room_space) { RonovaAudioEngine::instance().setRoomSpace(room_space); }

// ---- Volume upscaler ---------------------------------------------------------------------------

void ronova_set_master_volume(float linear_gain) { RonovaAudioEngine::instance().setMasterVolume(linear_gain); }

void ronova_set_volume_upscaler_gain(float gain_db) {
  RonovaAudioEngine::instance().setVolumeUpscalerGainDb(gain_db);
}

float ronova_get_peak_reduction_db(void) { return RonovaAudioEngine::instance().peakReductionDb(); }

// ---- EQ / sub-bass / stereo --------------------------------------------------------------------

void ronova_set_preamp_db(float gain_db) { RonovaAudioEngine::instance().setPreampDb(gain_db); }

void ronova_set_eq_band(int32_t band_index, float freq_hz, float gain_db, float q) {
  RonovaAudioEngine::instance().setEqBand(band_index, freq_hz, gain_db, q);
}

void ronova_set_eq_band_type(int32_t band_index, int32_t filter_type) {
  RonovaAudioEngine::instance().setEqBandType(band_index, filter_type);
}

void ronova_set_sub_bass_boost(float amount) { RonovaAudioEngine::instance().setSubBassBoost(amount); }

void ronova_set_stereo_width(float width) { RonovaAudioEngine::instance().setStereoWidth(width); }

void ronova_set_mono_mode(int32_t enabled) { RonovaAudioEngine::instance().setMonoMode(enabled != 0); }

// ---- Spec-named aliases ------------------------------------------------------------------------

void ronova_set_upscaler_gain_db(float gain_db) { ronova_set_volume_upscaler_gain(gain_db); }

float ronova_get_gain_reduction_db(void) { return ronova_get_peak_reduction_db(); }

void ronova_set_sub_bass_808(float amount) { ronova_set_sub_bass_boost(amount); }

// ---- Ronova hardware calibration ---------------------------------------------------------------

int32_t ronova_engage_ronova_mode(int32_t enabled) {
  return RonovaAudioEngine::instance().engageRonovaMode(enabled != 0);
}

void ronova_set_hardware_profile(int32_t profile_id) {
  RonovaAudioEngine::instance().setHardwareProfile(profile_id);
}

}  // extern "C"
