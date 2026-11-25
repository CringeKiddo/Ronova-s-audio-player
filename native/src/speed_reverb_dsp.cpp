#include "speed_reverb_dsp.h"

#include <algorithm>
#include <cmath>

#include "SoundTouch.h"
#include "dsp_common.h"

namespace ronova {

// ================================================================================================
// TempoStretcher
// ================================================================================================

TempoStretcher::TempoStretcher() : st_(std::make_unique<soundtouch::SoundTouch>()) {
  st_->setChannels(2);
  st_->setSampleRate(48000);
  st_->setPitch(1.0);
  st_->setTempo(1.0);
  st_->setSetting(SETTING_USE_QUICKSEEK, 0);  // full cross-correlation seek = best quality
  st_->setSetting(SETTING_USE_AA_FILTER, 1);
}

TempoStretcher::~TempoStretcher() = default;

void TempoStretcher::prepare(int sampleRate) {
  st_->clear();
  st_->setChannels(2);
  st_->setSampleRate(static_cast<unsigned int>(sampleRate > 0 ? sampleRate : 48000));
  st_->setPitch(1.0);
}

void TempoStretcher::setTempo(float tempo) {
  st_->setPitch(1.0);
  st_->setTempo(static_cast<double>(tempo));
}

void TempoStretcher::clear() { st_->clear(); }

void TempoStretcher::put(const float* interleaved, int frames) {
  if (frames > 0) st_->putSamples(interleaved, static_cast<unsigned int>(frames));
}

int TempoStretcher::receive(float* interleavedOut, int maxFrames) {
  return static_cast<int>(st_->receiveSamples(interleavedOut, static_cast<unsigned int>(maxFrames)));
}

void TempoStretcher::flush() { st_->flush(); }

int TempoStretcher::pendingInputFrames() const { return static_cast<int>(st_->numUnprocessedSamples()); }

// ================================================================================================
// SincResampler
// ================================================================================================

struct SincResampler::Tables {
  std::vector<float> kernel;  // h(i / kPhases), i in [0, kHalfTaps * kPhases + 1]
  std::vector<float> poly;    // (kPhases + 1) rows x (2 * kHalfTaps) taps
};

namespace {
constexpr double kKaiserBeta = 9.0;
constexpr double kCutoff = 0.476;  // normalised to the input rate (0.5 = Nyquist)

double besselI0(double x) {
  double sum = 1.0;
  double term = 1.0;
  const double q = x * x * 0.25;
  for (int k = 1; k < 64; ++k) {
    term *= q / (static_cast<double>(k) * static_cast<double>(k));
    sum += term;
    if (term < 1.0e-14 * sum) break;
  }
  return sum;
}

double kernelAt(double t, double i0Beta) {
  const double halfWidth = static_cast<double>(SincResampler::kHalfTaps);
  const double u = t / halfWidth;
  if (u <= -1.0 || u >= 1.0) return 0.0;
  const double window = besselI0(kKaiserBeta * std::sqrt(1.0 - u * u)) / i0Beta;
  const double arg = dsp::kPi * 2.0 * kCutoff * t;
  const double sinc = std::fabs(arg) < 1.0e-12 ? 1.0 : std::sin(arg) / arg;
  return 2.0 * kCutoff * sinc * window;
}
}  // namespace

const SincResampler::Tables& SincResampler::tables() noexcept {
  static const Tables instance = [] {
    Tables t;
    const double i0Beta = besselI0(kKaiserBeta);
    const int kernelSize = kHalfTaps * kPhases + 2;
    t.kernel.resize(static_cast<size_t>(kernelSize));
    for (int i = 0; i < kernelSize; ++i) {
      t.kernel[static_cast<size_t>(i)] =
          static_cast<float>(kernelAt(static_cast<double>(i) / kPhases, i0Beta));
    }
    const int taps = 2 * kHalfTaps;
    t.poly.resize(static_cast<size_t>(kPhases + 1) * static_cast<size_t>(taps));
    for (int j = 0; j <= kPhases; ++j) {
      const double frac = static_cast<double>(j) / kPhases;
      double sum = 0.0;
      std::vector<double> row(static_cast<size_t>(taps));
      for (int tap = 0; tap < taps; ++tap) {
        const int m = tap - (kHalfTaps - 1);  // -63 .. 64
        row[static_cast<size_t>(tap)] = kernelAt(static_cast<double>(m) - frac, i0Beta);
        sum += row[static_cast<size_t>(tap)];
      }
      const double inv = sum != 0.0 ? 1.0 / sum : 1.0;  // exact unity DC gain per phase
      for (int tap = 0; tap < taps; ++tap) {
        t.poly[static_cast<size_t>(j) * static_cast<size_t>(taps) + static_cast<size_t>(tap)] =
            static_cast<float>(row[static_cast<size_t>(tap)] * inv);
      }
    }
    return t;
  }();
  return instance;
}

const float* SincResampler::kernel1d() noexcept { return tables().kernel.data(); }
const float* SincResampler::polyphase() noexcept { return tables().poly.data(); }

void SincResampler::buildTables() { (void)tables(); }

SincResampler::SincResampler() : buffer_(static_cast<size_t>(kBufferFrames) * 2, 0.0f) {
  (void)tables();
  reset();
}

void SincResampler::reset() noexcept {
  std::fill(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(kMaxHalf) * 2, 0.0f);
  count_ = kMaxHalf;
  position_ = static_cast<double>(kMaxHalf);
}

void SincResampler::setRatio(double r) noexcept {
  ratio_ = std::clamp(r, 0.01, static_cast<double>(kMaxScale));
}

void SincResampler::compact() noexcept {
  const std::int64_t i0 = static_cast<std::int64_t>(std::floor(position_));
  const std::int64_t shift = i0 - kMaxHalf;
  if (shift <= 0 || shift > count_) return;
  const std::int64_t remaining = count_ - shift;
  std::memmove(buffer_.data(), buffer_.data() + static_cast<size_t>(shift) * 2,
               static_cast<size_t>(remaining) * 2 * sizeof(float));
  count_ = static_cast<int>(remaining);
  position_ -= static_cast<double>(shift);
}

// ================================================================================================
// FdnReverb
// ================================================================================================

namespace {
// Delay lengths in samples at 48 kHz (~28-92 ms). Scaled to the stream rate, then snapped to primes.
constexpr double kBaseDelays[FdnReverb::kLines] = {1327, 1637, 1993, 2399, 2851, 3331, 3847, 4423};
constexpr std::uint32_t kDiffuserDelays[4] = {347, 113, 359, 127};  // primes @48 kHz
constexpr float kDiffuserGain = 0.6f;
constexpr float kHadamardScale = 0.35355339059327373f;  // 1 / sqrt(8)

bool isPrime(std::uint32_t n) {
  if (n < 2) return false;
  if (n % 2 == 0) return n == 2;
  for (std::uint32_t d = 3; d * d <= n; d += 2) {
    if (n % d == 0) return false;
  }
  return true;
}

std::uint32_t nextPrime(std::uint32_t n) {
  while (!isPrime(n)) ++n;
  return n;
}
}  // namespace

void FdnReverb::prepare(int sampleRate) {
  sampleRate_ = sampleRate > 0 ? static_cast<double>(sampleRate) : 48000.0;
  const double rateScale = sampleRate_ / 48000.0;
  modDepth_ = static_cast<float>(6.0 * rateScale);

  for (int i = 0; i < kLines; ++i) {
    Line& line = lines_[static_cast<size_t>(i)];
    const std::uint32_t length = nextPrime(static_cast<std::uint32_t>(std::lround(kBaseDelays[i] * rateScale)));
    line.length = static_cast<double>(length);
    const std::uint32_t capacity = dsp::nextPowerOfTwo(length + static_cast<std::uint32_t>(modDepth_) + 16u);
    line.buffer.assign(capacity, 0.0f);
    line.mask = capacity - 1;
    const double lfoHz = 0.13 + 0.057 * i;
    line.lfoCr = std::cos(dsp::kTwoPi * lfoHz / sampleRate_);
    line.lfoSr = std::sin(dsp::kTwoPi * lfoHz / sampleRate_);
  }
  for (size_t i = 0; i < diffusers_.size(); ++i) {
    const std::uint32_t length = nextPrime(static_cast<std::uint32_t>(std::lround(kDiffuserDelays[i] * rateScale)));
    const std::uint32_t capacity = dsp::nextPowerOfTwo(length + 8u);
    diffusers_[i].buffer.assign(capacity, 0.0f);
    diffusers_[i].mask = capacity - 1;
    diffusers_[i].length = length;
  }
  const std::uint32_t preCapacity = dsp::nextPowerOfTwo(static_cast<std::uint32_t>(sampleRate_ * 0.06) + 16u);
  preL_.buffer.assign(preCapacity, 0.0f);
  preL_.mask = preCapacity - 1;
  preR_.buffer.assign(preCapacity, 0.0f);
  preR_.mask = preCapacity - 1;

  mixAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.060, sampleRate_));
  blockAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.150, sampleRate_, kBlock));
  roomSmooth_ = room_.load();
  preDelaySmooth_ = static_cast<float>(sampleRate_ * (0.008 + 0.032 * roomSmooth_));
  mix_ = 0.0f;
  active_ = false;
  updateBlock();
  reset();
}

void FdnReverb::reset() {
  for (Line& line : lines_) {
    std::fill(line.buffer.begin(), line.buffer.end(), 0.0f);
    line.write = 0;
    line.damp = 0.0f;
    line.lfoC = 1.0;
    line.lfoS = 0.0;
  }
  for (Allpass& ap : diffusers_) {
    std::fill(ap.buffer.begin(), ap.buffer.end(), 0.0f);
    ap.write = 0;
  }
  std::fill(preL_.buffer.begin(), preL_.buffer.end(), 0.0f);
  std::fill(preR_.buffer.begin(), preR_.buffer.end(), 0.0f);
  preL_.write = preR_.write = 0;
}

void FdnReverb::updateBlock() noexcept {
  roomSmooth_ += blockAlpha_ * (room_.load(std::memory_order_relaxed) - roomSmooth_);
  const float room = roomSmooth_;

  // RT60: 0.4 s (intimate studio) .. 7.5 s (vast cathedral), exponential in roomSpace.
  const float rt60 = 0.4f * std::pow(7.5f / 0.4f, room);
  // Air absorption: darker tail for bigger rooms.
  const float dampHz = 11000.0f - (11000.0f - 3200.0f) * std::pow(room, 0.6f);
  dampCoef_ = 1.0f - std::exp(-static_cast<float>(dsp::kTwoPi) * dampHz / static_cast<float>(sampleRate_));

  for (Line& line : lines_) {
    line.feedback = std::pow(10.0f, -3.0f * static_cast<float>(line.length) / (static_cast<float>(sampleRate_) * rt60));
  }

  preDelayTarget_ = static_cast<float>(sampleRate_) * (0.008f + 0.032f * room);
  preDelaySmooth_ += 0.05f * (preDelayTarget_ - preDelaySmooth_);

  const float wetAmount = 0.10f + 0.40f * room;
  const float compensation = 1.0f / (1.0f + 0.12f * (rt60 - 0.4f));
  wetGain_ = wetAmount * compensation * 1.4f;
  dryAmount_ = 0.4f * wetAmount;
}

void FdnReverb::process(float* io, int frames) noexcept {
  const bool want = enabled_.load(std::memory_order_relaxed);
  if (!want && mix_ <= 1.0e-4f) {
    mix_ = 0.0f;
    active_ = false;
    return;
  }
  if (want && !active_) {
    reset();
    active_ = true;
  }
  const float mixTarget = want ? 1.0f : 0.0f;

  int done = 0;
  while (done < frames) {
    const int n = std::min(kBlock, frames - done);
    updateBlock();

    for (int i = 0; i < n; ++i) {
      float* frame = io + static_cast<size_t>(done + i) * 2;
      mix_ += (mixTarget - mix_) * mixAlpha_;
      const float inL = frame[0];
      const float inR = frame[1];

      // Stereo pre-delay and input diffusion.
      const float pdL = preL_.process(inL, preDelaySmooth_);
      const float pdR = preR_.process(inR, preDelaySmooth_);
      const float dl = diffusers_[1].process(diffusers_[0].process(pdL, kDiffuserGain), kDiffuserGain);
      const float dr = diffusers_[3].process(diffusers_[2].process(pdR, kDiffuserGain), kDiffuserGain);

      // Read the (modulated) delay lines and apply damping + decay.
      float y[kLines];
      for (int k = 0; k < kLines; ++k) {
        Line& line = lines_[static_cast<size_t>(k)];
        const double delay = line.length + static_cast<double>(modDepth_) * line.lfoS;
        const double pos = static_cast<double>(line.write) - delay;
        const std::int64_t ip = static_cast<std::int64_t>(std::floor(pos));
        const float f = static_cast<float>(pos - static_cast<double>(ip));
        const float a = line.buffer[static_cast<std::uint32_t>(ip) & line.mask];
        const float b = line.buffer[static_cast<std::uint32_t>(ip + 1) & line.mask];
        const float v = a + f * (b - a);
        line.damp += dampCoef_ * (v - line.damp);
        y[k] = line.damp * line.feedback;

        const double c = line.lfoC * line.lfoCr - line.lfoS * line.lfoSr;
        const double s = line.lfoS * line.lfoCr + line.lfoC * line.lfoSr;
        line.lfoC = c;
        line.lfoS = s;
      }

      // Output taps: two orthogonal Walsh rows -> decorrelated left / right.
      const float wetL = 0.5f * (y[0] - y[1] + y[2] - y[3] + y[4] - y[5] + y[6] - y[7]);
      const float wetR = 0.5f * (y[0] + y[1] - y[2] - y[3] + y[4] + y[5] - y[6] - y[7]);

      // Fast Walsh-Hadamard transform (orthonormal feedback matrix).
      for (int k = 0; k < kLines; k += 2) {
        const float p = y[k], q = y[k + 1];
        y[k] = p + q;
        y[k + 1] = p - q;
      }
      for (int k = 0; k < kLines; k += 4) {
        for (int j = 0; j < 2; ++j) {
          const float p = y[k + j], q = y[k + j + 2];
          y[k + j] = p + q;
          y[k + j + 2] = p - q;
        }
      }
      for (int j = 0; j < 4; ++j) {
        const float p = y[j], q = y[j + 4];
        y[j] = p + q;
        y[j + 4] = p - q;
      }

      for (int k = 0; k < kLines; ++k) {
        Line& line = lines_[static_cast<size_t>(k)];
        const float injection = 0.35f * ((k & 1) ? dr : dl);
        line.buffer[line.write & line.mask] = dsp::sanitizeSample(y[k] * kHadamardScale + injection);
        ++line.write;
      }

      const float wet = mix_ * wetGain_;
      const float dry = 1.0f - mix_ * dryAmount_;
      frame[0] = inL * dry + wetL * wet;
      frame[1] = inR * dry + wetR * wet;
    }
    done += n;
  }

  // Keep the LFO rotators on the unit circle.
  for (Line& line : lines_) {
    const double mag = std::sqrt(line.lfoC * line.lfoC + line.lfoS * line.lfoS);
    if (mag > 1.0e-9) {
      line.lfoC /= mag;
      line.lfoS /= mag;
    }
  }
}

}  // namespace ronova
