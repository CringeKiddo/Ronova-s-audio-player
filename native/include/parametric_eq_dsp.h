#ifndef RONOVA_PARAMETRIC_EQ_DSP_H
#define RONOVA_PARAMETRIC_EQ_DSP_H

// 16-band parametric biquad EQ, 808 sub-harmonic exciter, and mid/side width + mono fold-down.
// All process() methods are real-time safe. Setters only touch std::atomic state.

#include <array>
#include <atomic>

#include "dsp_common.h"

namespace ronova {

class ParametricEq {
 public:
  static constexpr int kBands = 16;
  static constexpr int kSubBlock = 32;  // parameter-smoothing / coefficient-ramp block

  ParametricEq();

  // Control thread, only while audio is not running.
  void prepare(int sampleRate);
  void reset();

  // Any thread (atomics). type: 0 Peaking, 1 LowShelf, 2 HighShelf, 3 HighPass, 4 LowPass.
  void setBand(int index, float freqHz, float gainDb, float q);
  void setBandType(int index, int type);

  // Audio thread. `io` is interleaved stereo float.
  void process(float* io, int frames) noexcept;

 private:
  struct Target {
    std::atomic<float> freqHz{1000.0f};
    std::atomic<float> gainDb{0.0f};
    std::atomic<float> q{1.41f};
    std::atomic<int> type{0};
  };
  struct Band {
    double freqHz = 1000.0;
    double gainDb = 0.0;
    double q = 1.41;
    int type = 0;
    dsp::BiquadCoeffs coeffs;
    dsp::BiquadState left;
    dsp::BiquadState right;
  };

  void processBand(Band& band, const Target& target, float* io, int frames) noexcept;

  std::array<Target, kBands> targets_;
  std::array<Band, kBands> bands_;
  double sampleRate_ = 48000.0;
  double alpha_ = 0.03;
};

// Psychoacoustic 808 sub-bass exciter: LR4 low-pass isolates < 75 Hz, an asymmetric tanh stage
// synthesises 2nd/3rd harmonics, which are band-limited and blended back in.
class SubBassExciter {
 public:
  void prepare(int sampleRate);
  void reset();
  void setAmount(float amount) noexcept { amountTarget_.store(std::clamp(amount, 0.0f, 1.0f), std::memory_order_relaxed); }
  void process(float* io, int frames) noexcept;

 private:
  std::atomic<float> amountTarget_{0.0f};
  float amount_ = 0.0f;
  float amountAlpha_ = 0.01f;
  dsp::BiquadCoeffs lowPass_;
  dsp::BiquadCoeffs highPass_;
  dsp::BiquadCoeffs harmonicLow_;
  dsp::BiquadState lp1_, lp2_, hp1_, hp2_, hl_;
};

// Mid/Side width (0 = mono .. 2 = extra wide, 1 = neutral) with smooth mono fold-down.
class StereoWidthProcessor {
 public:
  void prepare(int sampleRate);
  void reset();
  void setWidth(float width) noexcept { widthTarget_.store(std::clamp(width, 0.0f, 2.0f), std::memory_order_relaxed); }
  void setMono(bool mono) noexcept { monoTarget_.store(mono, std::memory_order_relaxed); }
  void process(float* io, int frames) noexcept;

 private:
  std::atomic<float> widthTarget_{1.0f};
  std::atomic<bool> monoTarget_{false};
  float width_ = 1.0f;
  float monoMix_ = 0.0f;
  float alpha_ = 0.01f;
};

}  // namespace ronova

#endif  // RONOVA_PARAMETRIC_EQ_DSP_H
