#ifndef RONOVA_SPEED_REVERB_DSP_H
#define RONOVA_SPEED_REVERB_DSP_H

// Variable-speed engine and slowed+reverb tank.
//
//  * TempoStretcher : SoundTouch wrapper (pitch-preserving tempo). Non-real-time: runs on the
//                     decoder feeder thread (SoundTouch allocates internally).
//  * SincResampler  : 128-tap Kaiser-windowed sinc, variable ratio. Real-time safe. Used for true
//                     tape/vinyl pitch-linked slowdown AND for sample-rate conversion. The kernel
//                     is stretched automatically when down-sampling, so it never aliases.
//  * FdnReverb      : 8-line Hadamard feedback delay network, stereo, RT60 0.4 s .. 7.5 s.

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace soundtouch {
class SoundTouch;
}

namespace ronova {

// ---- Pitch-preserving tempo (feeder thread only) -------------------------------------------------

class TempoStretcher {
 public:
  TempoStretcher();
  ~TempoStretcher();
  TempoStretcher(const TempoStretcher&) = delete;
  TempoStretcher& operator=(const TempoStretcher&) = delete;

  void prepare(int sampleRate);
  void setTempo(float tempo);          // pitch stays locked at 1.0
  void clear();
  void put(const float* interleaved, int frames);
  int receive(float* interleavedOut, int maxFrames);
  void flush();
  int pendingInputFrames() const;

 private:
  std::unique_ptr<soundtouch::SoundTouch> st_;
};

// ---- High-quality variable-ratio sinc resampler -------------------------------------------------

class SincResampler {
 public:
  static constexpr int kHalfTaps = 64;                    // 128 taps
  static constexpr int kPhases = 512;                     // polyphase table resolution
  static constexpr int kMaxScale = 8;                     // up to 8:1 down-sampling
  static constexpr int kMaxHalf = kHalfTaps * kMaxScale;  // history kept before the read position
  static constexpr int kBufferFrames = 16384;
  static constexpr int kReadChunk = 512;

  // Builds the shared kernel tables (idempotent). Call from a control thread before audio starts.
  static void buildTables();

  SincResampler();

  void reset() noexcept;
  // Input frames consumed per output frame. Clamped to [0.01, 8].
  void setRatio(double inputFramesPerOutputFrame) noexcept;
  double ratio() const noexcept { return ratio_; }

  // Source must provide: int readFrames(float* interleavedStereo, int maxFrames) (non-blocking).
  // Returns frames produced (< frames when the source ran dry).
  template <class Source>
  int process(Source& source, float* out, int frames) noexcept;

 private:
  struct Tables;
  static const Tables& tables() noexcept;
  static const float* kernel1d() noexcept;
  static const float* polyphase() noexcept;

  template <class Source>
  bool refill(Source& source) noexcept;
  void compact() noexcept;

  std::vector<float> buffer_;  // interleaved stereo
  int count_ = 0;              // valid frames in buffer_
  double position_ = 0.0;      // read position in frames (relative to buffer_)
  double ratio_ = 1.0;
};

template <class Source>
bool SincResampler::refill(Source& source) noexcept {
  if (count_ + kReadChunk > kBufferFrames) compact();
  const int room = kBufferFrames - count_;
  if (room <= 0) return false;
  const int want = room < kReadChunk ? room : kReadChunk;
  const int got = source.readFrames(buffer_.data() + static_cast<size_t>(count_) * 2, want);
  if (got <= 0) return false;
  count_ += got;
  return true;
}

template <class Source>
int SincResampler::process(Source& source, float* out, int frames) noexcept {
  const float* poly = polyphase();
  const float* kernel = kernel1d();
  const double step = ratio_;
  const double scale = step > 1.0 ? step : 1.0;
  const int half = scale > 1.0 ? static_cast<int>(std::ceil(kHalfTaps * scale)) : kHalfTaps;

  int produced = 0;
  while (produced < frames) {
    std::int64_t i0 = 0;
    for (;;) {
      i0 = static_cast<std::int64_t>(std::floor(position_));
      if (i0 + half < count_) break;
      if (!refill(source)) return produced;
    }

    const float* x = buffer_.data();
    float accL = 0.0f;
    float accR = 0.0f;

    if (scale <= 1.0) {
      // Up-sampling / unity: polyphase kernel with linear interpolation between phases.
      const double frac = position_ - static_cast<double>(i0);
      const double phasePos = frac * kPhases;
      int phase = static_cast<int>(phasePos);
      if (phase >= kPhases) phase = kPhases - 1;
      const float a = static_cast<float>(phasePos - phase);
      const float* r0 = poly + static_cast<size_t>(phase) * (2 * kHalfTaps);
      const float* r1 = r0 + (2 * kHalfTaps);
      const float* src = x + (static_cast<size_t>(i0) - (kHalfTaps - 1)) * 2;
      for (int t = 0; t < 2 * kHalfTaps; ++t) {
        const float w = r0[t] + a * (r1[t] - r0[t]);
        accL += w * src[2 * t];
        accR += w * src[2 * t + 1];
      }
    } else {
      // Down-sampling: stretch the kernel by `scale` (cut-off follows the output Nyquist).
      const double invScale = 1.0 / scale;
      float weightSum = 0.0f;
      const std::int64_t first = i0 - half + 1;
      const std::int64_t last = i0 + half;
      for (std::int64_t n = first; n <= last; ++n) {
        const double d = (static_cast<double>(n) - position_) * invScale;
        const double ad = d < 0.0 ? -d : d;
        if (ad >= kHalfTaps) continue;
        const double u = ad * kPhases;
        const int k = static_cast<int>(u);
        const float fr = static_cast<float>(u - k);
        const float w = kernel[k] + fr * (kernel[k + 1] - kernel[k]);
        weightSum += w;
        accL += w * x[2 * n];
        accR += w * x[2 * n + 1];
      }
      if (weightSum > 1.0e-6f) {
        const float inv = 1.0f / weightSum;
        accL *= inv;
        accR *= inv;
      }
    }

    out[2 * produced] = accL;
    out[2 * produced + 1] = accR;
    ++produced;
    position_ += step;
  }
  return produced;
}

// ---- 8-line Hadamard FDN reverb ----------------------------------------------------------------------

class FdnReverb {
 public:
  static constexpr int kLines = 8;
  static constexpr int kBlock = 32;

  void prepare(int sampleRate);  // control thread (allocates)
  void reset();

  void setEnabled(bool enabled) noexcept { enabled_.store(enabled, std::memory_order_relaxed); }
  void setRoomSpace(float room) noexcept {
    room_.store(room < 0.0f ? 0.0f : (room > 1.0f ? 1.0f : room), std::memory_order_relaxed);
  }

  void process(float* io, int frames) noexcept;  // audio thread

 private:
  struct Line {
    std::vector<float> buffer;
    std::uint32_t mask = 0;
    std::uint32_t write = 0;
    double length = 0.0;
    float damp = 0.0f;
    float feedback = 0.0f;
    double lfoC = 1.0, lfoS = 0.0, lfoCr = 1.0, lfoSr = 0.0;
  };
  struct Allpass {
    std::vector<float> buffer;
    std::uint32_t mask = 0;
    std::uint32_t write = 0;
    std::uint32_t length = 1;
    inline float process(float x, float g) noexcept {
      const float d = buffer[(write - length) & mask];
      const float v = x - g * d;
      buffer[write & mask] = v;
      ++write;
      return d + g * v;
    }
  };
  struct FracDelay {
    std::vector<float> buffer;
    std::uint32_t mask = 0;
    std::uint32_t write = 0;
    inline float process(float x, float delay) noexcept {
      buffer[write & mask] = x;
      const float pos = static_cast<float>(write) - delay;
      const std::int64_t ip = static_cast<std::int64_t>(std::floor(pos));
      const float f = pos - static_cast<float>(ip);
      const float a = buffer[static_cast<std::uint32_t>(ip) & mask];
      const float b = buffer[static_cast<std::uint32_t>(ip + 1) & mask];
      ++write;
      return a + f * (b - a);
    }
  };

  void updateBlock() noexcept;

  std::atomic<bool> enabled_{false};
  std::atomic<float> room_{0.35f};

  double sampleRate_ = 48000.0;
  std::array<Line, kLines> lines_;
  std::array<Allpass, 4> diffusers_;  // L1, L2, R1, R2
  FracDelay preL_, preR_;

  bool active_ = false;
  float mix_ = 0.0f;
  float mixAlpha_ = 0.01f;
  float blockAlpha_ = 0.01f;
  float roomSmooth_ = 0.35f;
  float preDelaySmooth_ = 0.0f;
  float preDelayTarget_ = 0.0f;
  float dampCoef_ = 0.3f;
  float wetGain_ = 0.0f;
  float dryAmount_ = 0.0f;
  float modDepth_ = 6.0f;
};

}  // namespace ronova

#endif  // RONOVA_SPEED_REVERB_DSP_H
