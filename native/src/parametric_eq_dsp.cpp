#include "parametric_eq_dsp.h"

#include <cmath>

namespace ronova {

namespace {
constexpr float kDefaultBandHz[ParametricEq::kBands] = {
    25.0f,   40.0f,   63.0f,   100.0f,  160.0f,  250.0f,   400.0f,   630.0f,
    1000.0f, 1600.0f, 2500.0f, 4000.0f, 6300.0f, 10000.0f, 14000.0f, 18000.0f};

// Moves `current` toward `target`; returns true when the value changed.
inline bool approach(double& current, double target, double alpha, double epsilon) noexcept {
  const double diff = target - current;
  if (std::fabs(diff) <= epsilon) {
    if (current != target) {
      current = target;
      return true;
    }
    return false;
  }
  current += alpha * diff;
  return true;
}
}  // namespace

// ---- ParametricEq ----------------------------------------------------------------------------

ParametricEq::ParametricEq() {
  for (int i = 0; i < kBands; ++i) {
    targets_[static_cast<size_t>(i)].freqHz.store(kDefaultBandHz[i]);
  }
}

void ParametricEq::prepare(int sampleRate) {
  sampleRate_ = sampleRate > 0 ? static_cast<double>(sampleRate) : 48000.0;
  alpha_ = dsp::smoothingAlpha(0.025, sampleRate_, kSubBlock);
  for (int i = 0; i < kBands; ++i) {
    Band& band = bands_[static_cast<size_t>(i)];
    const Target& target = targets_[static_cast<size_t>(i)];
    band.freqHz = target.freqHz.load();
    band.gainDb = target.gainDb.load();
    band.q = target.q.load();
    band.type = target.type.load();
    band.coeffs = dsp::designBiquad(static_cast<dsp::FilterType>(band.type), sampleRate_, band.freqHz,
                                    band.gainDb, band.q);
    band.left.reset();
    band.right.reset();
  }
}

void ParametricEq::reset() {
  for (Band& band : bands_) {
    band.left.reset();
    band.right.reset();
  }
}

void ParametricEq::setBand(int index, float freqHz, float gainDb, float q) {
  if (index < 0 || index >= kBands) return;
  Target& t = targets_[static_cast<size_t>(index)];
  t.freqHz.store(std::clamp(freqHz, 20.0f, 20000.0f), std::memory_order_relaxed);
  t.gainDb.store(std::clamp(gainDb, -15.0f, 15.0f), std::memory_order_relaxed);
  t.q.store(std::clamp(q, 0.1f, 18.0f), std::memory_order_relaxed);
}

void ParametricEq::setBandType(int index, int type) {
  if (index < 0 || index >= kBands) return;
  if (type < 0 || type > 4) return;
  targets_[static_cast<size_t>(index)].type.store(type, std::memory_order_relaxed);
}

void ParametricEq::process(float* io, int frames) noexcept {
  int done = 0;
  while (done < frames) {
    const int n = std::min(kSubBlock, frames - done);
    float* block = io + static_cast<size_t>(done) * 2;
    for (int b = 0; b < kBands; ++b) {
      processBand(bands_[static_cast<size_t>(b)], targets_[static_cast<size_t>(b)], block, n);
    }
    done += n;
  }
}

void ParametricEq::processBand(Band& band, const Target& target, float* io, int frames) noexcept {
  const double tf = target.freqHz.load(std::memory_order_relaxed);
  const double tg = target.gainDb.load(std::memory_order_relaxed);
  const double tq = target.q.load(std::memory_order_relaxed);
  const int tt = target.type.load(std::memory_order_relaxed);

  bool changed = false;
  if (tt != band.type) {
    // Topology change: snap parameters and ramp coefficients across this block.
    band.type = tt;
    band.freqHz = tf;
    band.gainDb = tg;
    band.q = tq;
    changed = true;
  } else {
    changed |= approach(band.freqHz, tf, alpha_, 1.0e-3 * std::max(1.0, tf));
    changed |= approach(band.gainDb, tg, alpha_, 1.0e-4);
    changed |= approach(band.q, tq, alpha_, 1.0e-4);
  }

  const bool gainBased = band.type <= static_cast<int>(dsp::FilterType::HighShelf);
  if (gainBased && std::fabs(band.gainDb) < 1.0e-4 && std::fabs(tg) < 1.0e-4) {
    // Flat band: transparent, skip the maths and keep state clean.
    band.coeffs = dsp::BiquadCoeffs{};
    band.left.reset();
    band.right.reset();
    return;
  }

  const dsp::BiquadCoeffs next =
      changed ? dsp::designBiquad(static_cast<dsp::FilterType>(band.type), sampleRate_, band.freqHz,
                                  band.gainDb, band.q)
              : band.coeffs;

  double b0 = band.coeffs.b0, b1 = band.coeffs.b1, b2 = band.coeffs.b2;
  double a1 = band.coeffs.a1, a2 = band.coeffs.a2;
  const double inv = 1.0 / static_cast<double>(frames);
  const double db0 = (next.b0 - b0) * inv, db1 = (next.b1 - b1) * inv, db2 = (next.b2 - b2) * inv;
  const double da1 = (next.a1 - a1) * inv, da2 = (next.a2 - a2) * inv;

  double lz1 = band.left.z1, lz2 = band.left.z2;
  double rz1 = band.right.z1, rz2 = band.right.z2;

  for (int i = 0; i < frames; ++i) {
    const double xl = io[2 * i];
    const double xr = io[2 * i + 1];
    const double yl = b0 * xl + lz1;
    lz1 = b1 * xl - a1 * yl + lz2;
    lz2 = b2 * xl - a2 * yl;
    const double yr = b0 * xr + rz1;
    rz1 = b1 * xr - a1 * yr + rz2;
    rz2 = b2 * xr - a2 * yr;
    io[2 * i] = static_cast<float>(yl);
    io[2 * i + 1] = static_cast<float>(yr);
    b0 += db0;
    b1 += db1;
    b2 += db2;
    a1 += da1;
    a2 += da2;
  }

  band.left.z1 = lz1;
  band.left.z2 = lz2;
  band.right.z1 = rz1;
  band.right.z2 = rz2;
  band.coeffs = next;
}

// ---- SubBassExciter --------------------------------------------------------------------------

void SubBassExciter::prepare(int sampleRate) {
  const double fs = sampleRate > 0 ? static_cast<double>(sampleRate) : 48000.0;
  constexpr double kButterworthQ = 0.70710678118654752;
  lowPass_ = dsp::designBiquad(dsp::FilterType::LowPass, fs, 75.0, 0.0, kButterworthQ);      // LR4 = 2x BW2
  highPass_ = dsp::designBiquad(dsp::FilterType::HighPass, fs, 65.0, 0.0, kButterworthQ);    // LR4 harmonic HP
  harmonicLow_ = dsp::designBiquad(dsp::FilterType::LowPass, fs, 400.0, 0.0, kButterworthQ);  // keep mids clean
  amountAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.010, fs));
  amount_ = amountTarget_.load();
  reset();
}

void SubBassExciter::reset() {
  lp1_.reset();
  lp2_.reset();
  hp1_.reset();
  hp2_.reset();
  hl_.reset();
}

void SubBassExciter::process(float* io, int frames) noexcept {
  const float target = amountTarget_.load(std::memory_order_relaxed);
  if (amount_ < 1.0e-5f && target < 1.0e-5f) {
    amount_ = 0.0f;
    return;
  }
  for (int i = 0; i < frames; ++i) {
    amount_ += (target - amount_) * amountAlpha_;
    const double mid = 0.5 * (static_cast<double>(io[2 * i]) + static_cast<double>(io[2 * i + 1]));

    // Linkwitz-Riley 4th order low-pass (two cascaded Butterworth sections).
    const double sub = lp2_.process(lowPass_, lp1_.process(lowPass_, mid));

    // Asymmetric soft clip: tanh -> odd harmonics, squared term -> even harmonics.
    const double drive = 1.0 + 7.0 * static_cast<double>(amount_);
    const double t = std::tanh(sub * drive);
    const double shaped = t + 0.6 * t * t;

    // Band-limit the harmonics: LR4 high-pass removes DC + fundamental, low-pass keeps vocals clean.
    const double harmonics = hl_.process(harmonicLow_, hp2_.process(highPass_, hp1_.process(highPass_, shaped)));

    const float add = static_cast<float>(0.5 * static_cast<double>(amount_) * harmonics +
                                         0.18 * static_cast<double>(amount_) * sub);
    io[2 * i] += add;
    io[2 * i + 1] += add;
  }
}

// ---- StereoWidthProcessor --------------------------------------------------------------------

void StereoWidthProcessor::prepare(int sampleRate) {
  const double fs = sampleRate > 0 ? static_cast<double>(sampleRate) : 48000.0;
  alpha_ = static_cast<float>(dsp::smoothingAlpha(0.015, fs));
  width_ = widthTarget_.load();
  monoMix_ = monoTarget_.load() ? 1.0f : 0.0f;
}

void StereoWidthProcessor::reset() {}

void StereoWidthProcessor::process(float* io, int frames) noexcept {
  const float widthTarget = widthTarget_.load(std::memory_order_relaxed);
  const float monoTarget = monoTarget_.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
  if (std::fabs(width_ - 1.0f) < 1.0e-4f && std::fabs(widthTarget - 1.0f) < 1.0e-4f &&
      monoMix_ < 1.0e-4f && monoTarget < 1.0e-4f) {
    width_ = 1.0f;
    monoMix_ = 0.0f;
    return;  // neutral: bit-transparent
  }
  for (int i = 0; i < frames; ++i) {
    width_ += (widthTarget - width_) * alpha_;
    monoMix_ += (monoTarget - monoMix_) * alpha_;
    if (std::fabs(widthTarget - width_) < 1.0e-4f) width_ = widthTarget;  // float one-pole stalls just short
    if (std::fabs(monoTarget - monoMix_) < 1.0e-4f) monoMix_ = monoTarget;
    const float l = io[2 * i];
    const float r = io[2 * i + 1];
    const float mid = 0.5f * (l + r);
    const float side = 0.5f * (l - r) * width_ * (1.0f - monoMix_);
    io[2 * i] = mid + side;
    io[2 * i + 1] = mid - side;
  }
}

}  // namespace ronova
