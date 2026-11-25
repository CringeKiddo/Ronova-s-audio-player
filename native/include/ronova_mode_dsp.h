#ifndef RONOVA_MODE_DSP_H
#define RONOVA_MODE_DSP_H

// Ronova Mode acoustic calibration chain (header-only, real-time safe):
//   headphone crossfeed -> 11.5 kHz +2.2 dB air shelf -> sub-bass punch + micro-detail transient shaper.
// The wet chain is cross-faded in/out so engaging Ronova Mode never clicks.

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "dsp_common.h"

namespace ronova {

class RonovaModeDsp {
 public:
  // deviceType: 0 = speaker (no crossfeed), 1 = wired / USB DAC, 2 = Bluetooth (LDAC / aptX).
  void setEngaged(bool engaged, int deviceType) noexcept {
    deviceType_.store(deviceType, std::memory_order_relaxed);
    engaged_.store(engaged, std::memory_order_relaxed);
  }
  bool isEngaged() const noexcept { return engaged_.load(std::memory_order_relaxed); }

  void prepare(int sampleRate) {
    fs_ = sampleRate > 0 ? static_cast<double>(sampleRate) : 48000.0;
    mixAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.060, fs_));
    crossfeedAlpha_ = static_cast<float>(1.0 - std::exp(-dsp::kTwoPi * 700.0 / fs_));
    crossfeedDelay_ = std::max<std::uint32_t>(1, static_cast<std::uint32_t>(std::lround(fs_ * 0.00027)));
    air_ = dsp::designBiquad(dsp::FilterType::HighShelf, fs_, 11500.0, 2.2, 0.6);
    lowAlpha_ = static_cast<float>(1.0 - std::exp(-dsp::kTwoPi * 120.0 / fs_));
    fastAttack_ = static_cast<float>(dsp::smoothingAlpha(0.0004, fs_));
    fastRelease_ = static_cast<float>(dsp::smoothingAlpha(0.020, fs_));
    slowAttack_ = static_cast<float>(dsp::smoothingAlpha(0.015, fs_));
    slowRelease_ = static_cast<float>(dsp::smoothingAlpha(0.080, fs_));
    gainAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.0005, fs_));
    mix_ = engaged_.load() ? 1.0f : 0.0f;
    reset();
  }

  void reset() {
    for (float& v : delayL_) v = 0.0f;
    for (float& v : delayR_) v = 0.0f;
    delayWrite_ = 0;
    lpL_ = lpR_ = ownL_ = ownR_ = 0.0f;
    airL_.reset();
    airR_.reset();
    lowL_ = lowR_ = 0.0f;
    lowFast_ = lowSlow_ = highFast_ = highSlow_ = 0.0f;
    lowGain_ = highGain_ = 1.0f;
  }

  void process(float* io, int frames) noexcept {
    const bool engaged = engaged_.load(std::memory_order_relaxed);
    const int deviceType = deviceType_.load(std::memory_order_relaxed);
    const float mixTarget = engaged ? 1.0f : 0.0f;
    if (!engaged && mix_ <= 1.0e-4f) {
      mix_ = 0.0f;
      return;
    }

    // Device-specific voicing. Bluetooth codecs already smear transients, so detail is lighter.
    const float crossfeedLevel = deviceType == 0 ? 0.0f : (deviceType == 2 ? 0.20f : 0.24f);
    const float punchAmount = deviceType == 2 ? 0.40f : 0.45f;
    const float detailAmount = deviceType == 2 ? 0.12f : 0.20f;

    for (int i = 0; i < frames; ++i) {
      mix_ += (mixTarget - mix_) * mixAlpha_;
      const float inL = io[2 * i];
      const float inR = io[2 * i + 1];

      // --- Natural headphone crossfeed: delayed, low-passed opposite channel -----------------
      delayL_[delayWrite_ & kDelayMask] = inL;
      delayR_[delayWrite_ & kDelayMask] = inR;
      const std::uint32_t readIndex = (delayWrite_ - crossfeedDelay_) & kDelayMask;
      ++delayWrite_;
      lpL_ += crossfeedAlpha_ * (delayR_[readIndex] - lpL_);  // right-ear bass bleeding into the left ear
      lpR_ += crossfeedAlpha_ * (delayL_[readIndex] - lpR_);
      ownL_ += crossfeedAlpha_ * (inL - ownL_);
      ownR_ += crossfeedAlpha_ * (inR - ownR_);
      // Move bass energy from each ear to the other: mono bass and all treble stay at unity gain
      // (no broadband level or tonal change), hard-panned bass is shared between both ears.
      float l = inL + crossfeedLevel * (lpL_ - ownL_);
      float r = inR + crossfeedLevel * (lpR_ - ownR_);

      // --- High-frequency air shelf ---------------------------------------------------------
      l = static_cast<float>(airL_.process(air_, l));
      r = static_cast<float>(airR_.process(air_, r));

      // --- Transient shaper: low band = sub-bass punch, high band = micro-detail --------------
      lowL_ += lowAlpha_ * (l - lowL_);
      lowR_ += lowAlpha_ * (r - lowR_);
      const float highL = l - lowL_;
      const float highR = r - lowR_;

      const float lowLevel = std::max(std::fabs(lowL_), std::fabs(lowR_));
      const float highLevel = std::max(std::fabs(highL), std::fabs(highR));
      lowFast_ += (lowLevel - lowFast_) * (lowLevel > lowFast_ ? fastAttack_ : fastRelease_);
      lowSlow_ += (lowLevel - lowSlow_) * (lowLevel > lowSlow_ ? slowAttack_ : slowRelease_);
      highFast_ += (highLevel - highFast_) * (highLevel > highFast_ ? fastAttack_ : fastRelease_);
      highSlow_ += (highLevel - highSlow_) * (highLevel > highSlow_ ? slowAttack_ : slowRelease_);

      const float lowBoost = std::clamp(lowFast_ / (lowSlow_ + 1.0e-5f) - 1.0f, 0.0f, 1.0f);
      const float highBoost = std::clamp(highFast_ / (highSlow_ + 1.0e-5f) - 1.0f, 0.0f, 1.0f);
      lowGain_ += (1.0f + punchAmount * lowBoost - lowGain_) * gainAlpha_;
      highGain_ += (1.0f + detailAmount * highBoost - highGain_) * gainAlpha_;

      l = lowL_ * lowGain_ + highL * highGain_;
      r = lowR_ * lowGain_ + highR * highGain_;

      io[2 * i] = inL + (l - inL) * mix_;
      io[2 * i + 1] = inR + (r - inR) * mix_;
    }
  }

 private:
  static constexpr std::uint32_t kDelayMask = 255;

  std::atomic<bool> engaged_{false};
  std::atomic<int> deviceType_{1};

  double fs_ = 48000.0;
  float mix_ = 0.0f;
  float mixAlpha_ = 0.01f;

  float crossfeedAlpha_ = 0.08f;
  std::uint32_t crossfeedDelay_ = 13;
  float delayL_[kDelayMask + 1] = {};
  float delayR_[kDelayMask + 1] = {};
  std::uint32_t delayWrite_ = 0;
  float lpL_ = 0.0f, lpR_ = 0.0f, ownL_ = 0.0f, ownR_ = 0.0f;

  dsp::BiquadCoeffs air_;
  dsp::BiquadState airL_, airR_;

  float lowAlpha_ = 0.015f;
  float lowL_ = 0.0f, lowR_ = 0.0f;
  float fastAttack_ = 0.05f, fastRelease_ = 0.001f, slowAttack_ = 0.001f, slowRelease_ = 0.0003f;
  float gainAlpha_ = 0.04f;
  float lowFast_ = 0.0f, lowSlow_ = 0.0f, highFast_ = 0.0f, highSlow_ = 0.0f;
  float lowGain_ = 1.0f, highGain_ = 1.0f;
};

}  // namespace ronova

#endif  // RONOVA_MODE_DSP_H
