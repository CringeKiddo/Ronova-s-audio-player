#include "brickwall_limiter_dsp.h"

#include <algorithm>
#include <cmath>

#include "dsp_common.h"

namespace ronova {

void BrickwallLimiter::prepare(int sampleRate) {
  const double fs = sampleRate > 0 ? static_cast<double>(sampleRate) : 48000.0;
  lookahead_ = std::clamp(static_cast<int>(std::lround(fs * 0.005)), 16, 2000);  // 240 @ 48 kHz

  const std::uint32_t delayFrames = dsp::nextPowerOfTwo(static_cast<std::uint32_t>(lookahead_) + 4u);
  delay_.assign(static_cast<size_t>(delayFrames) * 2, 0.0f);
  delayMask_ = delayFrames - 1;

  const std::uint32_t dqSize = dsp::nextPowerOfTwo(static_cast<std::uint32_t>(lookahead_) + 4u);
  dqValue_.assign(dqSize, 1.0f);
  dqIndex_.assign(dqSize, 0);
  dqMask_ = dqSize - 1;

  average_.assign(static_cast<size_t>(lookahead_), 1.0f);

  preAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.010, fs));
  releaseFast_ = static_cast<float>(dsp::smoothingAlpha(0.020, fs));  // fast + slow release blend ~60 ms
  releaseSlow_ = static_cast<float>(dsp::smoothingAlpha(0.100, fs));
  reset();
  preGain_ = dsp::dbToLinear(std::clamp(preGainDb_.load(), 0.0f, 24.0f));
}

void BrickwallLimiter::reset() {
  std::fill(delay_.begin(), delay_.end(), 0.0f);
  delayWrite_ = 0;
  std::fill(dqValue_.begin(), dqValue_.end(), 1.0f);
  std::fill(dqIndex_.begin(), dqIndex_.end(), 0);
  dqFront_ = dqBack_ = 0;
  sampleIndex_ = 0;
  std::fill(average_.begin(), average_.end(), 1.0f);
  averagePos_ = 0;
  averageSum_ = static_cast<double>(average_.size());
  fastRelease_ = slowRelease_ = 1.0f;
  for (auto& channel : history_) {
    for (float& v : channel) v = 0.0f;
  }
  grDb_.store(0.0f, std::memory_order_relaxed);
}

void BrickwallLimiter::setPreGainDb(float gainDb) noexcept {
  preGainDb_.store(std::clamp(gainDb, 0.0f, 24.0f), std::memory_order_relaxed);
}

// Smooth hyperbolic compression above the knee; gentle (never clips, asymptote far above 1.0).
float BrickwallLimiter::warm(float x) noexcept {
  const float magnitude = std::fabs(x);
  if (magnitude <= kKneeLinear) return x;
  const float over = magnitude - kKneeLinear;
  const float shaped = kKneeLinear + over / (1.0f + over * 0.15f);
  return x < 0.0f ? -shaped : shaped;
}

void BrickwallLimiter::process(float* io, int frames) noexcept {
  const float preGainDb = preGainDb_.load(std::memory_order_relaxed);
  const float preTarget = dsp::dbToLinear(preGainDb);
  // Warmth acts on the SOURCE-level signal (before the pre-gain), so the volume boost itself is
  // always distortion-free (pure gain + lookahead limiting). It engages progressively between 0 and
  // +6 dB of pre-gain, so 0 dB stays bit-transparent.
  const float warmth = std::clamp(preGainDb * (1.0f / 6.0f), 0.0f, 1.0f);

  const int la = lookahead_;
  const std::int64_t window = static_cast<std::int64_t>(la) + 1;
  const float invLa = 1.0f / static_cast<float>(la);
  float minGain = 1.0f;

  for (int i = 0; i < frames; ++i) {
    preGain_ += (preTarget - preGain_) * preAlpha_;
    float x[2] = {io[2 * i], io[2 * i + 1]};
    if (warmth > 0.0f) {
      x[0] += warmth * (warm(x[0]) - x[0]);
      x[1] += warmth * (warm(x[1]) - x[1]);
    }
    x[0] *= preGain_;
    x[1] *= preGain_;
    x[0] = dsp::sanitizeSample(x[0]);
    x[1] = dsp::sanitizeSample(x[1]);

    // Peak estimate including a cubic inter-sample (true-peak) midpoint per channel.
    float peak = 0.0f;
    for (int c = 0; c < 2; ++c) {
      float* h = history_[c];
      h[0] = h[1];
      h[1] = h[2];
      h[2] = h[3];
      h[3] = x[c];
      const float mid = (-h[0] + 9.0f * h[1] + 9.0f * h[2] - h[3]) * 0.0625f;
      peak = std::max(peak, std::max(std::fabs(x[c]), std::fabs(mid)));
    }
    const float required = peak > kCeiling ? kCeiling / peak : 1.0f;

    // Sliding-window minimum over the last (lookahead + 1) required gains.
    while (dqBack_ > dqFront_ && dqValue_[static_cast<std::uint32_t>(dqBack_ - 1) & dqMask_] >= required) {
      --dqBack_;
    }
    dqValue_[static_cast<std::uint32_t>(dqBack_) & dqMask_] = required;
    dqIndex_[static_cast<std::uint32_t>(dqBack_) & dqMask_] = sampleIndex_;
    ++dqBack_;
    while (dqFront_ < dqBack_ &&
           sampleIndex_ - dqIndex_[static_cast<std::uint32_t>(dqFront_) & dqMask_] >= window) {
      ++dqFront_;
    }
    const float envelope = dqValue_[static_cast<std::uint32_t>(dqFront_) & dqMask_];
    ++sampleIndex_;

    // Program-dependent release: fast and slow recovery, never above the envelope.
    fastRelease_ = std::min(envelope, fastRelease_ + (1.0f - fastRelease_) * releaseFast_);
    slowRelease_ = std::min(envelope, slowRelease_ + (1.0f - slowRelease_) * releaseSlow_);
    const float released = 0.5f * (fastRelease_ + slowRelease_);

    // Moving average over the lookahead window = ~5 ms attack ramp, overshoot-free by construction.
    averageSum_ += static_cast<double>(released) - static_cast<double>(average_[static_cast<size_t>(averagePos_)]);
    average_[static_cast<size_t>(averagePos_)] = released;
    if (++averagePos_ >= la) averagePos_ = 0;
    const float gain = static_cast<float>(averageSum_) * invLa;

    // Stereo lookahead delay.
    delay_[static_cast<size_t>(delayWrite_ & delayMask_) * 2] = x[0];
    delay_[static_cast<size_t>(delayWrite_ & delayMask_) * 2 + 1] = x[1];
    const std::uint32_t readIndex = (delayWrite_ - static_cast<std::uint32_t>(la)) & delayMask_;
    ++delayWrite_;
    const float dl = delay_[static_cast<size_t>(readIndex) * 2];
    const float dr = delay_[static_cast<size_t>(readIndex) * 2 + 1];

    io[2 * i] = std::clamp(dl * gain, -kCeiling, kCeiling);
    io[2 * i + 1] = std::clamp(dr * gain, -kCeiling, kCeiling);
    minGain = std::min(minGain, gain);
  }

  const float reduction = std::max(0.0f, -dsp::linearToDb(minGain));
  const float previous = grDb_.load(std::memory_order_relaxed);
  grDb_.store(reduction > previous ? reduction : previous * 0.9f + reduction * 0.1f, std::memory_order_relaxed);
}

}  // namespace ronova
