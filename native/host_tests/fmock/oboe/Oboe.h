#pragma once
// Functional fake of the Oboe API: a thread pulls the data callback at real-time pace.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
namespace oboe {
enum class Result { OK = 0, ErrorInternal = -899 };
enum class Direction { Output, Input };
enum class PerformanceMode { None, PowerSaving, LowLatency };
enum class SharingMode { Exclusive, Shared };
enum class AudioFormat { Invalid, Unspecified, I16, Float };
enum class SampleRateConversionQuality { None, Fastest, Low, Medium, High, Best };
enum class Usage { Media = 1 };
enum class ContentType { Music = 2 };
enum class DataCallbackResult { Continue, Stop };
inline const char* convertToText(Result) { return "result"; }
inline const char* getVersionText() { return "fake"; }
template <class T> struct ResultWithValue { Result r; T v; explicit operator bool() const { return r == Result::OK; } T value() const { return v; } };
class AudioStream;
class AudioStreamDataCallback { public: virtual ~AudioStreamDataCallback() = default;
  virtual DataCallbackResult onAudioReady(AudioStream*, void*, int32_t) = 0; };
class AudioStreamErrorCallback { public: virtual ~AudioStreamErrorCallback() = default;
  virtual void onErrorAfterClose(AudioStream*, Result) {} };

struct Capture { std::mutex m; std::vector<float> samples; std::atomic<int> rate{0}; void clear() { std::lock_guard<std::mutex> l(m); samples.clear(); } };
inline Capture& capture() { static Capture c; return c; }
inline std::atomic<int>& openCount() { static std::atomic<int> n{0}; return n; }

class AudioStream {
 public:
  ~AudioStream() { close(); }
  Result requestStart() { if (running_) return Result::OK; running_ = true; th_ = std::thread([this] {
      std::vector<float> buf(2 * 480);
      while (running_) { cb_->onAudioReady(this, buf.data(), 480);
        { std::lock_guard<std::mutex> l(capture().m); auto& s = capture().samples; s.insert(s.end(), buf.begin(), buf.end()); capture().rate = rate_; }
        std::this_thread::sleep_for(std::chrono::microseconds(480LL * 1000000 / rate_)); } });
    return Result::OK; }
  Result requestStop() { running_ = false; if (th_.joinable()) th_.join(); return Result::OK; }
  Result close() { return requestStop(); }
  int32_t getSampleRate() const { return rate_; }
  int32_t getFramesPerBurst() const { return 192; }
  int32_t getBufferSizeInFrames() { return 384; }
  int32_t getBufferCapacityInFrames() const { return 4096; }
  ResultWithValue<int32_t> setBufferSizeInFrames(int32_t n) { return {Result::OK, n}; }
  ResultWithValue<int32_t> getXRunCount() { return {Result::OK, 0}; }
  SharingMode getSharingMode() const { return SharingMode::Exclusive; }
  int rate_ = 48000; std::shared_ptr<AudioStreamDataCallback> cb_; std::atomic<bool> running_{false}; std::thread th_;
};
class AudioStreamBuilder {
 public:
  AudioStreamBuilder* setDirection(Direction) { return this; }
  AudioStreamBuilder* setPerformanceMode(PerformanceMode) { return this; }
  AudioStreamBuilder* setSharingMode(SharingMode) { return this; }
  AudioStreamBuilder* setFormat(AudioFormat) { return this; }
  AudioStreamBuilder* setChannelCount(int) { return this; }
  AudioStreamBuilder* setSampleRate(int r) { rate_ = r; return this; }
  AudioStreamBuilder* setSampleRateConversionQuality(SampleRateConversionQuality) { return this; }
  AudioStreamBuilder* setUsage(Usage) { return this; }
  AudioStreamBuilder* setContentType(ContentType) { return this; }
  AudioStreamBuilder* setFormatConversionAllowed(bool) { return this; }
  AudioStreamBuilder* setChannelConversionAllowed(bool) { return this; }
  AudioStreamBuilder* setDataCallback(std::shared_ptr<AudioStreamDataCallback> c) { cb_ = c; return this; }
  AudioStreamBuilder* setErrorCallback(std::shared_ptr<AudioStreamErrorCallback>) { return this; }
  Result openStream(std::shared_ptr<AudioStream>& s) { s = std::make_shared<AudioStream>(); s->rate_ = rate_; s->cb_ = cb_; ++openCount(); return Result::OK; }
 private: int rate_ = 48000; std::shared_ptr<AudioStreamDataCallback> cb_;
};
}
