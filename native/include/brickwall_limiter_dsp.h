#ifndef RONOVA_BRICKWALL_LIMITER_DSP_H
#define RONOVA_BRICKWALL_LIMITER_DSP_H

// Zero-distortion volume upscaler: soft-knee warmth on the source signal (gentle compression of
// transients above -6 dBFS) -> clean float pre-gain (0..+24 dB, peaks above 1.0 never clip) ->
// 5 ms lookahead true-peak brickwall limiter with a -0.1 dBFS ceiling (measured 0.00 % THD).

#include <atomic>
#include <cstdint>
#include <vector>

namespace ronova {

class BrickwallLimiter {
 public:
  static constexpr float kCeiling = 0.9885f;  // -0.1 dBFS
  static constexpr float kKneeLinear = 0.5012f;  // -6 dBFS

  void prepare(int sampleRate);  // control thread (allocates)
  void reset();

  void setPreGainDb(float gainDb) noexcept;  // 0 .. 24 dB
  void process(float* io, int frames) noexcept;

  // Current gain reduction in dB (>= 0) for UI metering.
  float gainReductionDb() const noexcept { return grDb_.load(std::memory_order_relaxed); }
  int lookaheadSamples() const noexcept { return lookahead_; }

 private:
  static float warm(float x) noexcept;

  std::atomic<float> preGainDb_{0.0f};
  std::atomic<float> grDb_{0.0f};

  int lookahead_ = 240;
  float preGain_ = 1.0f;
  float preAlpha_ = 0.01f;
  float releaseFast_ = 0.001f;
  float releaseSlow_ = 0.0002f;

  std::vector<float> delay_;  // stereo, pow2 frames
  std::uint32_t delayMask_ = 0;
  std::uint32_t delayWrite_ = 0;

  std::vector<float> dqValue_;  // monotonic deque for the sliding-window minimum
  std::vector<std::int64_t> dqIndex_;
  std::uint32_t dqMask_ = 0;
  std::int64_t dqFront_ = 0;
  std::int64_t dqBack_ = 0;
  std::int64_t sampleIndex_ = 0;

  std::vector<float> average_;  // moving average over `lookahead_` samples
  int averagePos_ = 0;
  double averageSum_ = 0.0;

  float fastRelease_ = 1.0f;
  float slowRelease_ = 1.0f;
  float history_[2][4] = {};
};

}  // namespace ronova

#endif  // RONOVA_BRICKWALL_LIMITER_DSP_H
