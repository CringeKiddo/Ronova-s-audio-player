#ifndef RONOVA_DSP_BRIDGE_H
#define RONOVA_DSP_BRIDGE_H

/*
 * Ronova DSP FFI boundary (pure C ABI, 32-bit IEEE float engine).
 *
 * Threading contract:
 *   - Control functions are called from the Dart UI isolate (one thread at a time).
 *   - All parameter state is stored in lock-free atomics so the realtime audio
 *     callback never blocks on a control call.
 *
 * Return-code convention for int32_t status functions: 0 = success, negative = error.
 */

#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define RONOVA_API __attribute__((visibility("default")))
#else
#define RONOVA_API
#endif

#define RONOVA_OK 0
#define RONOVA_ERR_NOT_INITIALISED (-1)
#define RONOVA_ERR_INVALID_ARGUMENT (-2)
#define RONOVA_ERR_FILE_NOT_FOUND (-3)
#define RONOVA_ERR_UNSUPPORTED (-4)

#define RONOVA_EQ_BAND_COUNT 16

#define RONOVA_FILTER_PEAKING 0
#define RONOVA_FILTER_LOW_SHELF 1
#define RONOVA_FILTER_HIGH_SHELF 2
#define RONOVA_FILTER_HIGH_PASS 3
#define RONOVA_FILTER_LOW_PASS 4

#define RONOVA_HW_PROFILE_AUTO 0
#define RONOVA_HW_PROFILE_SPEAKER 1
#define RONOVA_HW_PROFILE_WIRED_HEADPHONES 2
#define RONOVA_HW_PROFILE_BLUETOOTH 3
#define RONOVA_HW_PROFILE_USB_DAC 4

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Diagnostics ------------------------------------------------------- */

/* Static, NUL-terminated engine version string. Never freed by the caller. */
RONOVA_API const char* ronova_get_version(void);

/* Human-readable link/build diagnostics (Oboe + SoundTouch versions, format).
 * The returned pointer is valid until the next call from the same thread. */
RONOVA_API const char* ronova_get_diagnostics(void);

/* ---- Engine lifecycle -------------------------------------------------- */

RONOVA_API int32_t ronova_engine_init(int32_t sample_rate_hz, int32_t frames_per_burst);
RONOVA_API void ronova_engine_shutdown(void);

/* ---- Playback & seeking ------------------------------------------------ */

RONOVA_API int32_t ronova_load_file(const char* utf8_path);
RONOVA_API void ronova_play(void);
RONOVA_API void ronova_pause(void);
RONOVA_API void ronova_seek_ms(int64_t position_ms);
RONOVA_API int64_t ronova_get_position_ms(void);
RONOVA_API int64_t ronova_get_duration_ms(void);
RONOVA_API int32_t ronova_is_playing(void);

/* ---- Speed & pitch-linked reverb ---------------------------------------
 * Reverb OFF: SoundTouch tempo change, vocal pitch preserved.
 * Reverb ON : true tape/vinyl slowdown, pitch follows speed, feeding the FDN reverb tank. */

RONOVA_API void ronova_set_speed(float speed_ratio);          /* 0.10 .. 1.50 */
RONOVA_API void ronova_set_reverb_enabled(int32_t enabled);   /* 0 / 1 */
RONOVA_API void ronova_set_room_space(float room_space);      /* 0.0 .. 1.0 */

/* ---- Zero-distortion lookahead brickwall volume upscaler --------------- */

RONOVA_API void ronova_set_master_volume(float linear_gain);          /* 0.0 .. 1.0 */
RONOVA_API void ronova_set_volume_upscaler_gain(float gain_db);       /* 0.0 .. 24.0 dB */
RONOVA_API float ronova_get_peak_reduction_db(void);                  /* >= 0 dB of limiting */

/* ---- 16-band parametric biquad EQ, 808 sub-bass, stereo width, mono ---- */

RONOVA_API void ronova_set_preamp_db(float gain_db);           /* -12.0 .. +12.0 dB, in front of the EQ */
RONOVA_API void ronova_set_eq_band(int32_t band_index, float freq_hz, float gain_db, float q);
RONOVA_API void ronova_set_eq_band_type(int32_t band_index, int32_t filter_type);  /* RONOVA_FILTER_* */
RONOVA_API void ronova_set_sub_bass_boost(float amount);      /* 0.0 .. 1.0 */
RONOVA_API void ronova_set_stereo_width(float width);         /* 0.0 (mono) .. 2.0 (wide), 1.0 = neutral */
RONOVA_API void ronova_set_mono_mode(int32_t enabled);        /* 0 stereo, 1 mono */

/* ---- Spec-named aliases (same behaviour as the functions above) ---------- */

RONOVA_API void ronova_set_upscaler_gain_db(float gain_db);   /* = ronova_set_volume_upscaler_gain */
RONOVA_API float ronova_get_gain_reduction_db(void);          /* = ronova_get_peak_reduction_db */
RONOVA_API void ronova_set_sub_bass_808(float amount);        /* = ronova_set_sub_bass_boost */

/* ---- Ronova hardware calibration & low-level overhaul ------------------ */

RONOVA_API int32_t ronova_engage_ronova_mode(int32_t enabled);
RONOVA_API void ronova_set_hardware_profile(int32_t profile_id);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* RONOVA_DSP_BRIDGE_H */
