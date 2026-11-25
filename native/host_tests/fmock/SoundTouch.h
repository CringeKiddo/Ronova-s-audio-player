#pragma once
#include <cstdint>
#include <deque>
#include <array>
#include <cmath>
typedef unsigned int uint;
#define SETTING_USE_AA_FILTER 0
#define SETTING_USE_QUICKSEEK 2
namespace soundtouch {
// Naive stand-in (nearest-sample tempo change) - only used to test the engine plumbing.
class SoundTouch {
 public:
  void setChannels(uint) {} void setSampleRate(uint) {} void setPitch(double) {}
  void setTempo(double t) { tempo_ = t; }
  bool setSetting(int, int) { return true; }
  void clear() { in_.clear(); frac_ = 0; }
  void flush() {}
  void putSamples(const float* s, uint n) { for (uint i = 0; i < n; ++i) in_.push_back({s[2*i], s[2*i+1]}); }
  uint receiveSamples(float* o, uint maxN) { uint k = 0;
    while (k < maxN && frac_ + 1 < (double)in_.size()) { size_t i = (size_t)frac_; o[2*k] = in_[i][0]; o[2*k+1] = in_[i][1]; ++k; frac_ += tempo_;
      size_t drop = (size_t)frac_; if (drop > 0 && drop < in_.size()) { in_.erase(in_.begin(), in_.begin() + drop); frac_ -= drop; } }
    return k; }
  uint numUnprocessedSamples() const { return (uint)in_.size(); }
  static const char* getVersionString() { return "fake"; }
 private: double tempo_ = 1; double frac_ = 0; std::deque<std::array<float,2>> in_;
};
}
