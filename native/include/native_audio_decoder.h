#ifndef RONOVA_NATIVE_AUDIO_DECODER_H
#define RONOVA_NATIVE_AUDIO_DECODER_H

// Hardware-accelerated multi-format decoder built on the NDK's AMediaExtractor + AMediaCodec
// (FLAC, WAV, MP3, AAC/M4A, OGG Vorbis, Opus ...). Output is normalised stereo float in [-1, 1].
//
// Threading: every method must be called from ONE thread (the engine's decoder feeder thread).

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>

#include <cstdint>
#include <string>
#include <vector>

namespace ronova {

class NativeAudioDecoder {
 public:
  enum class ReadStatus {
    Ok,           // frames were produced
    NoData,       // decoder is still working; try again shortly
    EndOfStream,  // everything has been delivered
    Error,
  };

  NativeAudioDecoder();
  ~NativeAudioDecoder();
  NativeAudioDecoder(const NativeAudioDecoder&) = delete;
  NativeAudioDecoder& operator=(const NativeAudioDecoder&) = delete;

  bool open(const std::string& path);
  void close();
  bool isOpen() const noexcept { return codec_ != nullptr; }

  // Writes up to maxFrames interleaved stereo float frames into dst.
  ReadStatus readFrames(float* dst, int maxFrames, int* framesRead);

  // Sample-accurate seek (decoder discards pre-roll up to the exact target frame).
  bool seekMs(std::int64_t positionMs);

  int sampleRate() const noexcept { return sampleRate_; }
  int sourceChannels() const noexcept { return channels_; }
  std::int64_t durationMs() const noexcept { return durationUs_ / 1000; }
  // Timeline position (microseconds) of the next frame readFrames() will deliver.
  std::int64_t positionUs() const noexcept;
  std::int64_t positionMs() const noexcept { return positionUs() / 1000; }
  bool endOfStream() const noexcept { return outputEos_ && pendingFrames() == 0; }
  const std::string& lastError() const noexcept { return lastError_; }
  const std::string& mime() const noexcept { return mime_; }

 private:
  bool configureCodec(AMediaFormat* trackFormat, bool requestFloat);
  bool pump(std::int32_t timeoutUs);  // returns true if any progress was made
  void feedInput();
  void drainOutput(std::int32_t timeoutUs, bool* progressed);
  void updateOutputFormat(AMediaFormat* format);
  void appendPcm(const std::uint8_t* data, int bytes, std::int64_t presentationTimeUs);
  size_t pendingFrames() const noexcept { return (pending_.size() - pendingRead_) / 2; }
  void fail(const std::string& message);

  AMediaExtractor* extractor_ = nullptr;
  AMediaCodec* codec_ = nullptr;
  std::string mime_;
  std::string lastError_;

  int sampleRate_ = 0;
  int channels_ = 2;
  int pcmEncoding_ = 2;  // AudioFormat.ENCODING_PCM_16BIT
  std::int64_t durationUs_ = 0;

  bool inputEos_ = false;
  bool outputEos_ = false;
  bool outputFormatSeen_ = false;

  bool skipActive_ = false;
  std::int64_t seekTargetUs_ = 0;
  std::int64_t basePositionUs_ = 0;
  std::int64_t deliveredFrames_ = 0;

  std::vector<float> pending_;  // interleaved stereo float not yet handed out
  size_t pendingRead_ = 0;
  std::vector<float> scratch_;
};

}  // namespace ronova

#endif  // RONOVA_NATIVE_AUDIO_DECODER_H
