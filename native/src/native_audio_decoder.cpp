#include "native_audio_decoder.h"

#include <android/log.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#include "dsp_common.h"

namespace ronova {

namespace {

constexpr const char* kTag = "RonovaDecoder";
#define DLOGI(...) __android_log_print(ANDROID_LOG_INFO, kTag, __VA_ARGS__)
#define DLOGE(...) __android_log_print(ANDROID_LOG_ERROR, kTag, __VA_ARGS__)

// AudioFormat.ENCODING_* values. Keys are plain strings so we never reference API 28+ symbols
// (minSdk is 26).
constexpr int kEncodingPcm16 = 2;
constexpr int kEncodingPcm8 = 3;
constexpr int kEncodingFloat = 4;
constexpr int kEncodingPcm24Packed = 21;
constexpr int kEncodingPcm32 = 22;

constexpr const char* kKeyMime = "mime";
constexpr const char* kKeySampleRate = "sample-rate";
constexpr const char* kKeyChannelCount = "channel-count";
constexpr const char* kKeyDuration = "durationUs";
constexpr const char* kKeyPcmEncoding = "pcm-encoding";

constexpr std::int32_t kDequeueTimeoutUs = 8000;
constexpr int kMaxIdlePumps = 25;  // ~200 ms of no progress -> report NoData

int bytesPerSample(int encoding) {
  switch (encoding) {
    case kEncodingPcm8: return 1;
    case kEncodingPcm24Packed: return 3;
    case kEncodingFloat:
    case kEncodingPcm32: return 4;
    case kEncodingPcm16:
    default: return 2;
  }
}

inline float readPcm8(const std::uint8_t* p) { return (static_cast<int>(p[0]) - 128) * (1.0f / 128.0f); }
inline float readPcm16(const std::uint8_t* p) {
  std::int16_t v;
  std::memcpy(&v, p, sizeof(v));
  return static_cast<float>(v) * (1.0f / 32768.0f);
}
inline float readPcm24(const std::uint8_t* p) {
  std::int32_t v = static_cast<std::int32_t>(static_cast<std::uint32_t>(p[0]) |
                                             (static_cast<std::uint32_t>(p[1]) << 8) |
                                             (static_cast<std::uint32_t>(p[2]) << 16));
  if (v & 0x800000) v |= ~0xFFFFFF;
  return static_cast<float>(v) * (1.0f / 8388608.0f);
}
inline float readPcm32(const std::uint8_t* p) {
  std::int32_t v;
  std::memcpy(&v, p, sizeof(v));
  return static_cast<float>(static_cast<double>(v) * (1.0 / 2147483648.0));
}
inline float readFloat32(const std::uint8_t* p) {
  float v;
  std::memcpy(&v, p, sizeof(v));
  return dsp::sanitizeSample(v);
}

// Converts `frames` interleaved frames with `ch` channels into stereo float.
template <class Reader>
void convertFrames(const std::uint8_t* data, int frames, int ch, int bps, Reader read, float* out) {
  const size_t frameBytes = static_cast<size_t>(bps) * static_cast<size_t>(ch);
  for (int f = 0; f < frames; ++f) {
    const std::uint8_t* p = data + static_cast<size_t>(f) * frameBytes;
    float l = 0.0f;
    float r = 0.0f;
    if (ch == 1) {
      l = r = read(p);
    } else if (ch == 2) {
      l = read(p);
      r = read(p + bps);
    } else {
      float c[8] = {};
      const int n = std::min(ch, 8);
      for (int k = 0; k < n; ++k) c[k] = read(p + static_cast<size_t>(k) * static_cast<size_t>(bps));
      constexpr float kCenter = 0.70710678f;
      if (ch >= 6) {  // 5.1 / 7.1: L R C LFE Ls Rs (Lb Rb)
        l = 0.5f * (c[0] + kCenter * c[2] + kCenter * c[4]);
        r = 0.5f * (c[1] + kCenter * c[2] + kCenter * c[5]);
      } else if (ch == 3) {  // L R C
        l = (c[0] + kCenter * c[2]) * 0.5858f;
        r = (c[1] + kCenter * c[2]) * 0.5858f;
      } else {  // quad / 5.0: L R Ls Rs [C]
        l = (c[0] + kCenter * c[2]) * 0.5858f;
        r = (c[1] + kCenter * c[3]) * 0.5858f;
        if (ch >= 5) {
          l += kCenter * c[4] * 0.5858f;
          r += kCenter * c[4] * 0.5858f;
        }
      }
    }
    out[2 * f] = l;
    out[2 * f + 1] = r;
  }
}

}  // namespace

NativeAudioDecoder::NativeAudioDecoder() = default;

NativeAudioDecoder::~NativeAudioDecoder() { close(); }

void NativeAudioDecoder::fail(const std::string& message) {
  lastError_ = message;
  DLOGE("%s", message.c_str());
}

void NativeAudioDecoder::close() {
  if (codec_ != nullptr) {
    AMediaCodec_stop(codec_);
    AMediaCodec_delete(codec_);
    codec_ = nullptr;
  }
  if (extractor_ != nullptr) {
    AMediaExtractor_delete(extractor_);
    extractor_ = nullptr;
  }
  pending_.clear();
  pendingRead_ = 0;
}

bool NativeAudioDecoder::configureCodec(AMediaFormat* trackFormat, bool requestFloat) {
  codec_ = AMediaCodec_createDecoderByType(mime_.c_str());
  if (codec_ == nullptr) {
    fail("no decoder available for " + mime_);
    return false;
  }
  if (requestFloat) AMediaFormat_setInt32(trackFormat, kKeyPcmEncoding, kEncodingFloat);
  if (AMediaCodec_configure(codec_, trackFormat, nullptr, nullptr, 0) != AMEDIA_OK ||
      AMediaCodec_start(codec_) != AMEDIA_OK) {
    AMediaCodec_delete(codec_);
    codec_ = nullptr;
    return false;
  }
  return true;
}

bool NativeAudioDecoder::open(const std::string& path) {
  close();
  lastError_.clear();
  inputEos_ = outputEos_ = outputFormatSeen_ = false;
  skipActive_ = false;
  basePositionUs_ = 0;
  deliveredFrames_ = 0;
  durationUs_ = 0;
  sampleRate_ = 0;
  channels_ = 2;
  pcmEncoding_ = kEncodingPcm16;

  const int fd = ::open(path.c_str(), O_RDONLY);
  if (fd < 0) {
    fail("cannot open file: " + path);
    return false;
  }
  struct stat info {};
  if (fstat(fd, &info) != 0 || info.st_size <= 0) {
    ::close(fd);
    fail("cannot stat file: " + path);
    return false;
  }

  extractor_ = AMediaExtractor_new();
  const media_status_t status =
      AMediaExtractor_setDataSourceFd(extractor_, fd, 0, static_cast<off64_t>(info.st_size));
  ::close(fd);
  if (status != AMEDIA_OK) {
    fail("unsupported or unreadable media container");
    close();
    return false;
  }

  AMediaFormat* trackFormat = nullptr;
  const size_t trackCount = AMediaExtractor_getTrackCount(extractor_);
  for (size_t i = 0; i < trackCount; ++i) {
    AMediaFormat* format = AMediaExtractor_getTrackFormat(extractor_, i);
    const char* mime = nullptr;
    if (format != nullptr && AMediaFormat_getString(format, kKeyMime, &mime) && mime != nullptr &&
        std::strncmp(mime, "audio/", 6) == 0) {
      mime_ = mime;
      trackFormat = format;
      AMediaExtractor_selectTrack(extractor_, i);
      break;
    }
    if (format != nullptr) AMediaFormat_delete(format);
  }
  if (trackFormat == nullptr) {
    fail("no audio track found");
    close();
    return false;
  }

  std::int32_t value = 0;
  if (AMediaFormat_getInt32(trackFormat, kKeySampleRate, &value) && value > 0) sampleRate_ = value;
  if (AMediaFormat_getInt32(trackFormat, kKeyChannelCount, &value) && value > 0) channels_ = value;
  std::int64_t durationUs = 0;
  if (AMediaFormat_getInt64(trackFormat, kKeyDuration, &durationUs) && durationUs > 0) {
    durationUs_ = durationUs;
  }
  if (AMediaFormat_getInt32(trackFormat, kKeyPcmEncoding, &value) && value > 0) pcmEncoding_ = value;

  // Request float output from compressed codecs; raw/WAV decoders pass samples through untouched.
  const bool isRaw = (mime_ == "audio/raw");
  bool ok = configureCodec(trackFormat, !isRaw);
  if (!ok && !isRaw) ok = configureCodec(trackFormat, false);
  AMediaFormat_delete(trackFormat);
  if (!ok) {
    if (lastError_.empty()) fail("decoder configure/start failed for " + mime_);
    close();
    return false;
  }

  // Pre-roll until the real output format is known (HE-AAC may double the sample rate).
  for (int i = 0; i < 60 && !outputFormatSeen_ && pendingFrames() == 0 && !outputEos_; ++i) pump(10000);

  if (sampleRate_ <= 0) {
    fail("could not determine sample rate");
    close();
    return false;
  }
  DLOGI("opened %s: %s, %d Hz, %d ch, encoding %d, %lld ms", path.c_str(), mime_.c_str(), sampleRate_,
        channels_, pcmEncoding_, static_cast<long long>(durationMs()));
  return true;
}

void NativeAudioDecoder::updateOutputFormat(AMediaFormat* format) {
  if (format == nullptr) return;
  std::int32_t value = 0;
  if (AMediaFormat_getInt32(format, kKeySampleRate, &value) && value > 0) sampleRate_ = value;
  if (AMediaFormat_getInt32(format, kKeyChannelCount, &value) && value > 0) channels_ = value;
  if (AMediaFormat_getInt32(format, kKeyPcmEncoding, &value) && value > 0) {
    pcmEncoding_ = value;
  } else {
    pcmEncoding_ = kEncodingPcm16;  // framework default when the key is absent
  }
  outputFormatSeen_ = true;
}

void NativeAudioDecoder::feedInput() {
  if (inputEos_) return;
  for (int attempt = 0; attempt < 4; ++attempt) {
    const ssize_t index = AMediaCodec_dequeueInputBuffer(codec_, 0);
    if (index < 0) return;
    size_t capacity = 0;
    std::uint8_t* buffer = AMediaCodec_getInputBuffer(codec_, static_cast<size_t>(index), &capacity);
    if (buffer == nullptr) return;
    const ssize_t size = AMediaExtractor_readSampleData(extractor_, buffer, capacity);
    if (size < 0) {
      AMediaCodec_queueInputBuffer(codec_, static_cast<size_t>(index), 0, 0, 0,
                                   AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
      inputEos_ = true;
      return;
    }
    const std::int64_t pts = AMediaExtractor_getSampleTime(extractor_);
    AMediaCodec_queueInputBuffer(codec_, static_cast<size_t>(index), 0, static_cast<size_t>(size),
                                 static_cast<std::uint64_t>(pts < 0 ? 0 : pts), 0);
    AMediaExtractor_advance(extractor_);
  }
}

void NativeAudioDecoder::drainOutput(std::int32_t timeoutUs, bool* progressed) {
  AMediaCodecBufferInfo info{};
  const ssize_t index = AMediaCodec_dequeueOutputBuffer(codec_, &info, timeoutUs);
  if (index >= 0) {
    size_t capacity = 0;
    const std::uint8_t* data = AMediaCodec_getOutputBuffer(codec_, static_cast<size_t>(index), &capacity);
    if (data != nullptr && info.size > 0) {
      appendPcm(data + info.offset, info.size, info.presentationTimeUs);
    }
    if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) outputEos_ = true;
    AMediaCodec_releaseOutputBuffer(codec_, static_cast<size_t>(index), false);
    *progressed = true;
  } else if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
    AMediaFormat* format = AMediaCodec_getOutputFormat(codec_);
    updateOutputFormat(format);
    if (format != nullptr) AMediaFormat_delete(format);
    *progressed = true;
  } else if (index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
    *progressed = true;
  }
}

bool NativeAudioDecoder::pump(std::int32_t timeoutUs) {
  if (codec_ == nullptr) return false;
  const bool wasEos = inputEos_;
  feedInput();
  bool progressed = (inputEos_ != wasEos);
  drainOutput(timeoutUs, &progressed);
  return progressed;
}

void NativeAudioDecoder::appendPcm(const std::uint8_t* data, int bytes, std::int64_t presentationTimeUs) {
  const int bps = bytesPerSample(pcmEncoding_);
  const int ch = std::max(channels_, 1);
  const int frames = bytes / (bps * ch);
  if (frames <= 0 || sampleRate_ <= 0) return;

  scratch_.resize(static_cast<size_t>(frames) * 2);
  switch (pcmEncoding_) {
    case kEncodingFloat: convertFrames(data, frames, ch, bps, readFloat32, scratch_.data()); break;
    case kEncodingPcm24Packed: convertFrames(data, frames, ch, bps, readPcm24, scratch_.data()); break;
    case kEncodingPcm32: convertFrames(data, frames, ch, bps, readPcm32, scratch_.data()); break;
    case kEncodingPcm8: convertFrames(data, frames, ch, bps, readPcm8, scratch_.data()); break;
    case kEncodingPcm16:
    default: convertFrames(data, frames, ch, bps, readPcm16, scratch_.data()); break;
  }

  int firstFrame = 0;
  if (skipActive_ && presentationTimeUs >= 0) {
    // Sample-accurate seek: drop everything before the requested frame, using the codec's PTS.
    const std::int64_t endUs = presentationTimeUs + static_cast<std::int64_t>(frames) * 1000000 / sampleRate_;
    if (endUs <= seekTargetUs_) return;  // whole buffer is pre-roll
    if (presentationTimeUs < seekTargetUs_) {
      firstFrame = static_cast<int>(
          std::llround(static_cast<double>(seekTargetUs_ - presentationTimeUs) * sampleRate_ / 1.0e6));
      firstFrame = std::clamp(firstFrame, 0, frames);
    }
    skipActive_ = false;
  } else {
    skipActive_ = false;
  }
  if (firstFrame >= frames) return;

  if (pendingRead_ > 16384 && pendingRead_ * 2 > pending_.size()) {
    pending_.erase(pending_.begin(), pending_.begin() + static_cast<std::ptrdiff_t>(pendingRead_));
    pendingRead_ = 0;
  }
  pending_.insert(pending_.end(), scratch_.begin() + static_cast<std::ptrdiff_t>(firstFrame) * 2, scratch_.end());
}

NativeAudioDecoder::ReadStatus NativeAudioDecoder::readFrames(float* dst, int maxFrames, int* framesRead) {
  *framesRead = 0;
  if (codec_ == nullptr) return ReadStatus::Error;

  int idle = 0;
  while (pendingFrames() == 0) {
    if (outputEos_) return ReadStatus::EndOfStream;
    if (pump(kDequeueTimeoutUs)) {
      idle = 0;
    } else if (++idle >= kMaxIdlePumps) {
      return ReadStatus::NoData;
    }
  }

  const int n = static_cast<int>(std::min<size_t>(static_cast<size_t>(std::max(maxFrames, 0)), pendingFrames()));
  std::memcpy(dst, pending_.data() + pendingRead_, static_cast<size_t>(n) * 2 * sizeof(float));
  pendingRead_ += static_cast<size_t>(n) * 2;
  deliveredFrames_ += n;
  *framesRead = n;
  return ReadStatus::Ok;
}

bool NativeAudioDecoder::seekMs(std::int64_t positionMs) {
  if (codec_ == nullptr || extractor_ == nullptr) return false;
  std::int64_t target = std::max<std::int64_t>(positionMs, 0);
  if (durationUs_ > 0) target = std::min(target, durationUs_ / 1000);
  const std::int64_t targetUs = target * 1000;

  if (AMediaExtractor_seekTo(extractor_, targetUs, AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC) != AMEDIA_OK) {
    fail("extractor seek failed");
    return false;
  }
  AMediaCodec_flush(codec_);
  pending_.clear();
  pendingRead_ = 0;
  inputEos_ = false;
  outputEos_ = false;
  seekTargetUs_ = targetUs;
  skipActive_ = targetUs > 0;
  basePositionUs_ = targetUs;
  deliveredFrames_ = 0;
  return true;
}

std::int64_t NativeAudioDecoder::positionUs() const noexcept {
  if (sampleRate_ <= 0) return basePositionUs_;
  return basePositionUs_ + deliveredFrames_ * 1000000 / sampleRate_;
}

}  // namespace ronova
