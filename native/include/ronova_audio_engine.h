#ifndef RONOVA_AUDIO_ENGINE_H
#define RONOVA_AUDIO_ENGINE_H

// Ronova real-time audio engine.
//
//   decoder feeder thread:  AMediaCodec -> [SoundTouch tempo] -> lock-free SPSC ring (262,144 frames)
//   Oboe audio callback  :  ring -> sinc resampler (rate conversion / tape speed) -> pre-amp trim -> 16-band EQ ->
//                           808 exciter -> M/S width -> FDN reverb -> Ronova mode -> volume upscaler
//                           (warmth + lookahead brickwall) -> master volume -> float32 out
//
// The audio callback never allocates, locks, performs file I/O or throws.

#include <oboe/Oboe.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "brickwall_limiter_dsp.h"
#include "lock_free_ring_buffer.h"
#include "native_audio_decoder.h"
#include "parametric_eq_dsp.h"
#include "ronova_mode_dsp.h"
#include "speed_reverb_dsp.h"

namespace ronova {

class EngineStreamCallbacks;

class RonovaAudioEngine {
 public:
  static RonovaAudioEngine& instance();

  // ---- Lifecycle ------------------------------------------------------------------------------
  int32_t init(int32_t sampleRateHz, int32_t framesPerBurst);
  void shutdown();

  // ---- Transport ------------------------------------------------------------------------------
  int32_t loadFile(const char* utf8Path);
  void play();
  void pause();
  void seekMs(int64_t positionMs);
  int64_t positionMs() const;
  int64_t durationMs() const { return durationMs_.load(std::memory_order_acquire); }
  bool isPlaying() const { return playing_.load(std::memory_order_acquire); }

  // ---- Speed / reverb -------------------------------------------------------------------------
  void setSpeed(float speed);
  void setReverbEnabled(bool enabled);
  void setRoomSpace(float roomSpace);

  // ---- Volume upscaler ------------------------------------------------------------------------
  void setMasterVolume(float linearGain);
  void setVolumeUpscalerGainDb(float gainDb);
  float peakReductionDb() const { return limiter_.gainReductionDb(); }

  // ---- Tone shaping ---------------------------------------------------------------------------
  void setPreampDb(float gainDb);  // -12 .. +12 dB trim in front of the EQ (float32, no clipping)
  void setEqBand(int32_t band, float freqHz, float gainDb, float q);
  void setEqBandType(int32_t band, int32_t type);
  void setSubBassBoost(float amount);
  void setStereoWidth(float width);
  void setMonoMode(bool mono);

  // ---- Ronova mode ----------------------------------------------------------------------------
  int32_t engageRonovaMode(bool enabled);
  void setHardwareProfile(int32_t profileId);

  // ---- Diagnostics ----------------------------------------------------------------------------
  static const char* version();
  std::string diagnostics() const;

  // ---- Called by the Oboe callbacks -----------------------------------------------------------
  oboe::DataCallbackResult renderAudio(oboe::AudioStream* stream, float* out, int32_t numFrames) noexcept;
  void onStreamDisconnected();

 private:
  RonovaAudioEngine();
  ~RonovaAudioEngine();
  RonovaAudioEngine(const RonovaAudioEngine&) = delete;
  RonovaAudioEngine& operator=(const RonovaAudioEngine&) = delete;

  struct RingSource {
    StereoRingBuffer* ring;
    int readFrames(float* dst, int maxFrames) noexcept {
      return static_cast<int>(ring->read(dst, static_cast<size_t>(maxFrames)));
    }
  };

  // Stream management (controlMutex_ must be held).
  bool openStreamLocked(int requestedRate);
  bool ensureStreamLocked(bool start);
  void closeStreamLocked();
  int desiredStreamRateLocked() const;
  void prepareDspLocked(int sampleRate);
  int probeHardwareRateLocked(int deviceType);
  void applyRonovaLocked();
  static int deviceTypeForProfile(int profile);

  // Real-time rendering.
  void renderChunk(float* out, int frames) noexcept;
  void tuneLatency(oboe::AudioStream* stream) noexcept;

  // Decoder feeder thread.
  void feederMain();
  void housekeeping();
  void waitFeeder(int milliseconds);
  void takePendingRequests();
  void installDecoder(std::unique_ptr<NativeAudioDecoder> fresh);
  void applySeek(int64_t targetMs);
  void applyPipelineMode();
  void syncPipelineMode();
  void rebuildPipeline();
  void produceChunk(std::vector<float>& chunk, std::vector<float>& tempoOut);
  void drainTempo(std::vector<float>& tempoOut);
  bool writeAll(const float* data, int frames);
  size_t targetFillFrames() const;
  int64_t estimatePositionMs() const;

  static constexpr int kRenderBlock = 512;

  // ---- Control-side state -------------------------------------------------------------------
  mutable std::mutex controlMutex_;
  std::atomic<bool> initialised_{false};
  std::atomic<bool> shuttingDown_{false};
  std::shared_ptr<oboe::AudioStream> stream_;
  std::shared_ptr<EngineStreamCallbacks> callbacks_;
  std::atomic<bool> streamOpen_{false};
  bool streamStarted_ = false;
  int defaultRate_ = 48000;
  int burstHint_ = 192;
  std::atomic<int> loadedFileRate_{0};
  int lockedHardwareRate_ = 0;
  int hardwareRateCacheDevice_ = -1;
  int hardwareRateCacheValue_ = 0;
  std::atomic<int> streamSharing_{0};
  std::atomic<int64_t> lastActiveMs_{0};

  // ---- Shared atomics -----------------------------------------------------------------------
  std::atomic<bool> playing_{false};
  std::atomic<bool> ended_{false};
  std::atomic<bool> trackLoaded_{false};
  std::atomic<float> speed_{1.0f};
  std::atomic<bool> reverbEnabled_{false};
  std::atomic<float> masterVolume_{1.0f};
  std::atomic<float> preampTarget_{1.0f};  // linear gain of the pre-EQ trim
  std::atomic<int> hardwareProfile_{0};
  std::atomic<bool> ronovaEngaged_{false};
  std::atomic<int> streamRate_{48000};
  std::atomic<int> fileRate_{44100};  // sample rate of the audio currently in the ring
  std::atomic<int64_t> durationMs_{0};
  std::atomic<uint32_t> underruns_{0};

  // ---- Producer/consumer coupling ----------------------------------------------------------
  std::unique_ptr<StereoRingBuffer> ring_;
  std::atomic<bool> producerFinished_{false};
  std::atomic<bool> producerTape_{false};  // true: ring holds source-speed audio (tape mode)
  std::atomic<int64_t> srcPosUs_{0};
  std::atomic<double> srcPerRingFrame_{1.0};
  std::atomic<int> tempoPendingFrames_{0};
  std::atomic<int64_t> seekRequestMs_{-1};
  std::atomic<int64_t> displayPositionMs_{-1};

  // ---- Feeder thread (decoder_, tempo_ and applied* are feeder-only) ----------------------
  std::thread feeder_;
  std::atomic<bool> stopFeeder_{false};
  std::mutex feederMutex_;
  std::condition_variable feederCv_;
  std::unique_ptr<NativeAudioDecoder> pendingDecoder_;
  bool hasPendingDecoder_ = false;
  std::unique_ptr<NativeAudioDecoder> decoder_;
  TempoStretcher tempo_;
  bool appliedTape_ = false;
  bool appliedTempoActive_ = false;
  float appliedTempo_ = 1.0f;

  // ---- Audio-thread DSP (prepared only while the stream is closed) -----------------------
  SincResampler resampler_;
  ParametricEq eq_;
  SubBassExciter exciter_;
  StereoWidthProcessor width_;
  FdnReverb reverb_;
  RonovaModeDsp ronovaDsp_;
  BrickwallLimiter limiter_;
  std::vector<float> renderBuf_;
  float fade_ = 0.0f;
  float fadeStep_ = 0.001f;
  float volume_ = 1.0f;
  float volumeAlpha_ = 0.01f;
  float preamp_ = 1.0f;
  float preampAlpha_ = 0.01f;
  float speedSmooth_ = 1.0f;
  int32_t lastXRun_ = 0;
};

}  // namespace ronova

#endif  // RONOVA_AUDIO_ENGINE_H
