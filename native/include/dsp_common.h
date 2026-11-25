#ifndef RONOVA_DSP_COMMON_H
#define RONOVA_DSP_COMMON_H

// Shared real-time-safe DSP primitives (no allocation, no locks, no exceptions).

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

namespace ronova::dsp {

inline constexpr double kPi = 3.14159265358979323846;
inline constexpr double kTwoPi = 2.0 * kPi;

inline float dbToLinear(float db) noexcept { return std::pow(10.0f, db * 0.05f); }
inline double dbToLinear(double db) noexcept { return std::pow(10.0, db * 0.05); }
inline float linearToDb(float lin) noexcept { return 20.0f * std::log10(std::max(lin, 1.0e-9f)); }

// Bit-level finite check: still works under -ffast-math (-ffinite-math-only).
inline bool isFiniteSample(float v) noexcept {
  std::uint32_t bits;
  std::memcpy(&bits, &v, sizeof(bits));
  return (bits & 0x7F800000u) != 0x7F800000u;
}

inline float sanitizeSample(float v) noexcept { return isFiniteSample(v) ? v : 0.0f; }

// One-pole smoothing coefficient: y += alpha * (target - y), applied once every `steps` samples.
inline double smoothingAlpha(double timeSeconds, double sampleRate, int steps = 1) noexcept {
  if (timeSeconds <= 0.0 || sampleRate <= 0.0) return 1.0;
  return 1.0 - std::exp(-static_cast<double>(steps) / (timeSeconds * sampleRate));
}

constexpr std::uint32_t nextPowerOfTwo(std::uint32_t v) noexcept {
  std::uint32_t p = 1;
  while (p < v) p <<= 1;
  return p;
}

// Enables flush-to-zero for the lifetime of the object so denormals never stall the audio thread.
class ScopedFlushToZero {
 public:
  ScopedFlushToZero() noexcept {
#if defined(__aarch64__)
    std::uint64_t fpcr = 0;
    asm volatile("mrs %0, fpcr" : "=r"(fpcr));
    saved_ = fpcr;
    asm volatile("msr fpcr, %0" : : "r"(fpcr | (1ull << 24)));
#elif defined(__x86_64__) || defined(__i386__)
    saved_ = _mm_getcsr();
    _mm_setcsr(static_cast<unsigned int>(saved_) | 0x8040u);
#endif
  }
  ~ScopedFlushToZero() noexcept {
#if defined(__aarch64__)
    asm volatile("msr fpcr, %0" : : "r"(saved_));
#elif defined(__x86_64__) || defined(__i386__)
    _mm_setcsr(static_cast<unsigned int>(saved_));
#endif
  }
  ScopedFlushToZero(const ScopedFlushToZero&) = delete;
  ScopedFlushToZero& operator=(const ScopedFlushToZero&) = delete;

 private:
  std::uint64_t saved_ = 0;
};

// ---- Biquad (Robert Bristow-Johnson Audio EQ Cookbook) -----------------------------------------

enum class FilterType : int { Peaking = 0, LowShelf = 1, HighShelf = 2, HighPass = 3, LowPass = 4 };

struct BiquadCoeffs {
  double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;  // a0 normalised to 1
};

inline BiquadCoeffs designBiquad(FilterType type, double sampleRate, double freqHz, double gainDb,
                                 double q) noexcept {
  const double fs = std::max(sampleRate, 8000.0);
  const double f0 = std::clamp(freqHz, 10.0, fs * 0.45);
  const double Q = std::clamp(q, 0.05, 30.0);
  const double w0 = kTwoPi * f0 / fs;
  const double cw = std::cos(w0);
  const double sw = std::sin(w0);
  const double alpha = sw / (2.0 * Q);
  const double A = std::pow(10.0, gainDb / 40.0);
  const double sqA2alpha = 2.0 * std::sqrt(A) * alpha;

  double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
  switch (type) {
    case FilterType::Peaking:
      b0 = 1.0 + alpha * A;
      b1 = -2.0 * cw;
      b2 = 1.0 - alpha * A;
      a0 = 1.0 + alpha / A;
      a1 = -2.0 * cw;
      a2 = 1.0 - alpha / A;
      break;
    case FilterType::LowShelf:
      b0 = A * ((A + 1.0) - (A - 1.0) * cw + sqA2alpha);
      b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
      b2 = A * ((A + 1.0) - (A - 1.0) * cw - sqA2alpha);
      a0 = (A + 1.0) + (A - 1.0) * cw + sqA2alpha;
      a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
      a2 = (A + 1.0) + (A - 1.0) * cw - sqA2alpha;
      break;
    case FilterType::HighShelf:
      b0 = A * ((A + 1.0) + (A - 1.0) * cw + sqA2alpha);
      b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
      b2 = A * ((A + 1.0) + (A - 1.0) * cw - sqA2alpha);
      a0 = (A + 1.0) - (A - 1.0) * cw + sqA2alpha;
      a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw);
      a2 = (A + 1.0) - (A - 1.0) * cw - sqA2alpha;
      break;
    case FilterType::HighPass:
      b0 = (1.0 + cw) * 0.5;
      b1 = -(1.0 + cw);
      b2 = (1.0 + cw) * 0.5;
      a0 = 1.0 + alpha;
      a1 = -2.0 * cw;
      a2 = 1.0 - alpha;
      break;
    case FilterType::LowPass:
      b0 = (1.0 - cw) * 0.5;
      b1 = 1.0 - cw;
      b2 = (1.0 - cw) * 0.5;
      a0 = 1.0 + alpha;
      a1 = -2.0 * cw;
      a2 = 1.0 - alpha;
      break;
  }
  const double inv = 1.0 / a0;
  BiquadCoeffs c;
  c.b0 = b0 * inv;
  c.b1 = b1 * inv;
  c.b2 = b2 * inv;
  c.a1 = a1 * inv;
  c.a2 = a2 * inv;
  return c;
}

// Transposed Direct Form II with double-precision state (low-frequency accuracy at float I/O).
struct BiquadState {
  double z1 = 0.0;
  double z2 = 0.0;
  inline double process(const BiquadCoeffs& c, double x) noexcept {
    const double y = c.b0 * x + z1;
    z1 = c.b1 * x - c.a1 * y + z2;
    z2 = c.b2 * x - c.a2 * y;
    return y;
  }
  inline void reset() noexcept { z1 = z2 = 0.0; }
};

}  // namespace ronova::dsp

#endif  // RONOVA_DSP_COMMON_H
