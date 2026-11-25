#include "ronova_audio_engine.h"

#include <android/log.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "SoundTouch.h"
#include "ronova_dsp_bridge.h"

namespace ronova {

namespace {

constexpr const char* kTag = "RonovaEngine";
#define ELOGI(...) __android_log_print(ANDROID_LOG_INFO, kTag, __VA_ARGS__)
#define ELOGW(...) __android_log_print(ANDROID_LOG_WARN, kTag, __VA_ARGS__)
#define ELOGE(...) __android_log_print(ANDROID_LOG_ERROR, kTag, __VA_ARGS__)

constexpr const char* kVersionText = "ronova_dsp 0.2.0 (batch-2 float32 engine)";
constexpr int kDecodeChunkFrames = 2048;
constexpr int kTempoOutFrames = 8192;
constexpr double kBufferTargetSeconds = 0.30;
constexpr float kMinSpeed = 0.10f;
constexpr float kMaxSpeed = 1.50f;
constexpr int64_t kIdleCloseMs = 8000;
constexpr int kSpeedSubBlock = 64;

int64_t nowMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

}  // namespace

// ================================================================================================
// Oboe callbacks
// ================================================================================================

class EngineStreamCallbacks final : public oboe::AudioStreamDataCallback,
                                    public oboe::AudioStreamErrorCallback {
 public:
  explicit EngineStreamCallbacks(RonovaAudioEngine* engine) : engine_(engine) {}

  oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream, void* audioData,
                                        int32_t numFrames) override {
    return engine_->renderAudio(stream, static_cast<float*>(audioData), numFrames);
  }

  void onErrorAfterClose(oboe::AudioStream* /*stream*/, oboe::Result result) override {
    ELOGW("stream error after close: %s", oboe::convertToText(result));
    engine_->onStreamDisconnected();
  }

 private:
  RonovaAudioEngine* engine_;
};

// ================================================================================================
// Construction / singleton
// ================================================================================================

RonovaAudioEngine& RonovaAudioEngine::instance() {
  static RonovaAudioEngine* engine = new RonovaAudioEngine();  // intentionally leaked
  return *engine;
}

RonovaAudioEngine::RonovaAudioEngine() : ring_(std::make_unique<StereoRingBuffer>()) {
  renderBuf_.assign(static_cast<size_t>(kRenderBlock) * 2, 0.0f);
}

RonovaAudioEngine::~RonovaAudioEngine() = default;

const char* RonovaAudioEngine::version() { return kVersionText; }

int RonovaAudioEngine::deviceTypeForProfile(int profile) {
  switch (profile) {
    case RONOVA_HW_PROFILE_SPEAKER: return 0;
    case RONOVA_HW_PROFILE_BLUETOOTH: return 2;
    case RONOVA_HW_PROFILE_WIRED_HEADPHONES:
    case RONOVA_HW_PROFILE_USB_DAC:
    case RONOVA_HW_PROFILE_AUTO:
    default: return 1;
  }
}

// ================================================================================================
// Lifecycle
// ================================================================================================

int32_t RonovaAudioEngine::init(int32_t sampleRateHz, int32_t framesPerBurst) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (initialised_.load(std::memory_order_acquire)) return RONOVA_OK;

  defaultRate_ = sampleRateHz > 0 ? sampleRateHz : 48000;
  burstHint_ = framesPerBurst > 0 ? framesPerBurst : 192;
  SincResampler::buildTables();

  playing_.store(false);
  ended_.store(false);
  trackLoaded_.store(false);
  speed_.store(1.0f);
  reverbEnabled_.store(false);
  masterVolume_.store(1.0f);
  preampTarget_.store(1.0f);
  ronovaEngaged_.store(false);
  hardwareProfile_.store(RONOVA_HW_PROFILE_AUTO);
  loadedFileRate_.store(0);
  fileRate_.store(defaultRate_);
  durationMs_.store(0);
  underruns_.store(0);
  producerFinished_.store(false);
  producerTape_.store(false);
  srcPosUs_.store(0);
  srcPerRingFrame_.store(1.0);
  tempoPendingFrames_.store(0);
  seekRequestMs_.store(-1);
  displayPositionMs_.store(-1);
  lockedHardwareRate_ = 0;
  hardwareRateCacheDevice_ = -1;
  ring_->reset();
  ronovaDsp_.setEngaged(false, 1);
  reverb_.setEnabled(false);

  prepareDspLocked(defaultRate_);

  shuttingDown_.store(false);
  stopFeeder_.store(false);
  feeder_ = std::thread(&RonovaAudioEngine::feederMain, this);
  lastActiveMs_.store(nowMs());
  initialised_.store(true, std::memory_order_release);
  ELOGI("engine initialised: %s", diagnostics().c_str());
  return RONOVA_OK;
}

void RonovaAudioEngine::shutdown() {
  {
    std::lock_guard<std::mutex> lock(controlMutex_);
    if (!initialised_.load(std::memory_order_acquire)) return;
    shuttingDown_.store(true);
    playing_.store(false);
    closeStreamLocked();
    initialised_.store(false, std::memory_order_release);
  }
  stopFeeder_.store(true);
  feederCv_.notify_all();
  if (feeder_.joinable()) feeder_.join();
  {
    std::lock_guard<std::mutex> lock(feederMutex_);
    pendingDecoder_.reset();
    hasPendingDecoder_ = false;
  }
  decoder_.reset();
  trackLoaded_.store(false);
  durationMs_.store(0);
  ELOGI("engine shut down");
}

// ================================================================================================
// Stream management
// ================================================================================================

void RonovaAudioEngine::prepareDspLocked(int sampleRate) {
  streamRate_.store(sampleRate);
  const double fs = static_cast<double>(sampleRate);
  resampler_.reset();
  eq_.prepare(sampleRate);
  exciter_.prepare(sampleRate);
  width_.prepare(sampleRate);
  reverb_.prepare(sampleRate);
  ronovaDsp_.prepare(sampleRate);
  limiter_.prepare(sampleRate);
  fade_ = 0.0f;
  fadeStep_ = static_cast<float>(1.0 / (0.020 * fs));
  volume_ = masterVolume_.load();
  volumeAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.005, fs));
  preamp_ = preampTarget_.load();
  preampAlpha_ = static_cast<float>(dsp::smoothingAlpha(0.012, fs));
  speedSmooth_ = reverbEnabled_.load() ? speed_.load() : 1.0f;
  lastXRun_ = 0;
}

int RonovaAudioEngine::desiredStreamRateLocked() const {
  if (ronovaEngaged_.load() && lockedHardwareRate_ > 0) return lockedHardwareRate_;
  const int fileRate = loadedFileRate_.load();
  return fileRate > 0 ? fileRate : defaultRate_;
}

bool RonovaAudioEngine::openStreamLocked(int requestedRate) {
  closeStreamLocked();
  if (!callbacks_) callbacks_ = std::make_shared<EngineStreamCallbacks>(this);

  struct Attempt {
    oboe::SharingMode sharing;
    oboe::PerformanceMode performance;
  };
  const Attempt attempts[] = {
      {oboe::SharingMode::Exclusive, oboe::PerformanceMode::LowLatency},
      {oboe::SharingMode::Shared, oboe::PerformanceMode::LowLatency},
      {oboe::SharingMode::Shared, oboe::PerformanceMode::None},
  };

  oboe::Result last = oboe::Result::ErrorInternal;
  for (const Attempt& attempt : attempts) {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output);
    builder.setPerformanceMode(attempt.performance);
    builder.setSharingMode(attempt.sharing);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(2);
    builder.setSampleRate(requestedRate);
    builder.setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Best);
    builder.setUsage(oboe::Usage::Media);
    builder.setContentType(oboe::ContentType::Music);
    builder.setFormatConversionAllowed(true);
    builder.setChannelConversionAllowed(true);
    builder.setDataCallback(callbacks_);
    builder.setErrorCallback(callbacks_);

    std::shared_ptr<oboe::AudioStream> candidate;
    last = builder.openStream(candidate);
    if (last == oboe::Result::OK && candidate) {
      stream_ = std::move(candidate);
      break;
    }
    ELOGW("stream open attempt failed (%s)", oboe::convertToText(last));
  }
  if (!stream_) {
    ELOGE("could not open an output stream: %s", oboe::convertToText(last));
    return false;
  }

  const int actualRate = stream_->getSampleRate();
  prepareDspLocked(actualRate > 0 ? actualRate : requestedRate);
  const int32_t burst = stream_->getFramesPerBurst();
  if (burst > 0) stream_->setBufferSizeInFrames(burst * 2);
  streamSharing_.store(static_cast<int>(stream_->getSharingMode()));
  streamOpen_.store(true);
  streamStarted_ = false;
  ELOGI("stream open: %d Hz, %s, burst %d", stream_->getSampleRate(),
        stream_->getSharingMode() == oboe::SharingMode::Exclusive ? "exclusive" : "shared", burst);
  return true;
}

bool RonovaAudioEngine::ensureStreamLocked(bool start) {
  const int desired = desiredStreamRateLocked();
  if (!stream_ || stream_->getSampleRate() != desired) {
    if (!openStreamLocked(desired)) return false;
  }
  if (start && !streamStarted_) {
    const oboe::Result r = stream_->requestStart();
    if (r != oboe::Result::OK) {
      ELOGE("requestStart failed: %s", oboe::convertToText(r));
      return false;
    }
    streamStarted_ = true;
  }
  return true;
}

void RonovaAudioEngine::closeStreamLocked() {
  if (stream_) {
    stream_->requestStop();
    stream_->close();
    stream_.reset();
  }
  streamStarted_ = false;
  streamOpen_.store(false);
}

void RonovaAudioEngine::onStreamDisconnected() {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (shuttingDown_.load() || !initialised_.load()) return;
  stream_.reset();  // already closed by Oboe
  streamStarted_ = false;
  streamOpen_.store(false);
  if (playing_.load()) {
    ELOGI("output device changed - reopening stream");
    ensureStreamLocked(true);
  }
}

// Finds the highest sample rate the output hardware really supports.
//   wired / USB DAC (1): probe exclusive-mode streams from 384 kHz downward; exclusive (MMAP)
//                        streams report the true hardware rate, shared streams are resampled by
//                        the system mixer and would always "succeed".
//   Bluetooth (2) and everything else: the HAL's native rate (e.g. the rate negotiated for LDAC).
int RonovaAudioEngine::probeHardwareRateLocked(int deviceType) {
  if (hardwareRateCacheDevice_ == deviceType && hardwareRateCacheValue_ > 0) return hardwareRateCacheValue_;

  closeStreamLocked();  // release the device so probes can open it exclusively

  int nativeRate = 0;
  {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Shared);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(2);
    builder.setUsage(oboe::Usage::Media);
    builder.setContentType(oboe::ContentType::Music);
    std::shared_ptr<oboe::AudioStream> probe;
    if (builder.openStream(probe) == oboe::Result::OK && probe) {
      nativeRate = probe->getSampleRate();
      probe->close();
    }
  }
  int best = nativeRate > 0 ? nativeRate : defaultRate_;

  if (deviceType == 1) {
    static const int candidates[] = {384000, 352800, 192000, 176400, 96000, 88200};
    for (const int candidate : candidates) {
      oboe::AudioStreamBuilder builder;
      builder.setDirection(oboe::Direction::Output);
      builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
      builder.setSharingMode(oboe::SharingMode::Exclusive);
      builder.setFormat(oboe::AudioFormat::Float);
      builder.setChannelCount(2);
      builder.setSampleRate(candidate);
      builder.setSampleRateConversionQuality(oboe::SampleRateConversionQuality::None);
      builder.setUsage(oboe::Usage::Media);
      builder.setContentType(oboe::ContentType::Music);
      std::shared_ptr<oboe::AudioStream> probe;
      if (builder.openStream(probe) != oboe::Result::OK || !probe) continue;
      const bool exact = probe->getSharingMode() == oboe::SharingMode::Exclusive &&
                         probe->getSampleRate() == candidate;
      probe->close();
      if (exact) {
        best = candidate;
        break;
      }
    }
  }
  hardwareRateCacheDevice_ = deviceType;
  hardwareRateCacheValue_ = best;
  ELOGI("hardware rate probe (device type %d): %d Hz", deviceType, best);
  return best;
}

void RonovaAudioEngine::applyRonovaLocked() {
  const bool engaged = ronovaEngaged_.load();
  const int deviceType = deviceTypeForProfile(hardwareProfile_.load());
  ronovaDsp_.setEngaged(engaged, deviceType);
  const int previousRate = lockedHardwareRate_;
  const bool wasOpen = stream_ != nullptr;
  const bool wasStarted = streamStarted_;
  lockedHardwareRate_ = (engaged && deviceType != 0) ? probeHardwareRateLocked(deviceType) : 0;
  // Re-lock the stream if the target rate changed (or the probe tore the stream down).
  if (wasOpen || previousRate != lockedHardwareRate_) {
    if (wasOpen) ensureStreamLocked(wasStarted);
  }
}

// ================================================================================================
// Transport
// ================================================================================================

int32_t RonovaAudioEngine::loadFile(const char* utf8Path) {
  if (!initialised_.load(std::memory_order_acquire)) return RONOVA_ERR_NOT_INITIALISED;
  if (utf8Path == nullptr || utf8Path[0] == '\0') return RONOVA_ERR_INVALID_ARGUMENT;
  struct stat info {};
  if (stat(utf8Path, &info) != 0 || !S_ISREG(info.st_mode)) {
    ELOGW("load: not found: %s", utf8Path);
    return RONOVA_ERR_FILE_NOT_FOUND;
  }

  auto decoder = std::make_unique<NativeAudioDecoder>();
  if (!decoder->open(utf8Path)) {
    ELOGE("load failed: %s", decoder->lastError().c_str());
    return RONOVA_ERR_UNSUPPORTED;
  }

  std::lock_guard<std::mutex> lock(controlMutex_);
  if (!initialised_.load()) return RONOVA_ERR_NOT_INITIALISED;
  const bool wasPlaying = playing_.exchange(false);
  if (wasPlaying && streamStarted_) sleepMs(30);  // let the fade-out finish before swapping audio

  durationMs_.store(decoder->durationMs());
  loadedFileRate_.store(decoder->sampleRate());
  ended_.store(false);
  trackLoaded_.store(true);
  displayPositionMs_.store(0);
  seekRequestMs_.store(-1);
  {
    std::lock_guard<std::mutex> feederLock(feederMutex_);
    pendingDecoder_ = std::move(decoder);
    hasPendingDecoder_ = true;
  }
  feederCv_.notify_all();

  // Normal mode runs the stream at the track's native rate (Oboe's "Best" SRC does the final
  // conversion); Ronova mode keeps the locked hardware rate.
  if (stream_) ensureStreamLocked(streamStarted_);
  return RONOVA_OK;
}

void RonovaAudioEngine::play() {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (!initialised_.load() || !trackLoaded_.load()) return;
  if (ended_.load()) {
    displayPositionMs_.store(0);
    seekRequestMs_.store(0);
    ended_.store(false);
    feederCv_.notify_all();
  }
  if (!ensureStreamLocked(true)) return;
  lastActiveMs_.store(nowMs());
  playing_.store(true, std::memory_order_release);
  feederCv_.notify_all();
}

void RonovaAudioEngine::pause() {
  playing_.store(false, std::memory_order_release);
  lastActiveMs_.store(nowMs());
}

void RonovaAudioEngine::seekMs(int64_t positionMs) {
  if (!initialised_.load() || !trackLoaded_.load()) return;
  int64_t target = std::max<int64_t>(positionMs, 0);
  const int64_t duration = durationMs_.load();
  if (duration > 0) target = std::min(target, duration);
  displayPositionMs_.store(target);
  seekRequestMs_.store(target);
  ended_.store(false);
  feederCv_.notify_all();
}

int64_t RonovaAudioEngine::positionMs() const {
  const int64_t display = displayPositionMs_.load(std::memory_order_acquire);
  if (display >= 0) return display;
  if (ended_.load(std::memory_order_acquire)) return durationMs_.load();
  return estimatePositionMs();
}

int64_t RonovaAudioEngine::estimatePositionMs() const {
  const int rate = fileRate_.load(std::memory_order_relaxed);
  if (rate <= 0) return 0;
  const double fill = static_cast<double>(ring_->fillFrames());
  const double perFrame = srcPerRingFrame_.load(std::memory_order_relaxed);
  const double pending = static_cast<double>(tempoPendingFrames_.load(std::memory_order_relaxed));
  const double backUs = (fill * perFrame + pending) * 1.0e6 / static_cast<double>(rate);
  const double posUs = static_cast<double>(srcPosUs_.load(std::memory_order_relaxed)) - backUs;
  int64_t ms = static_cast<int64_t>(posUs / 1000.0);
  const int64_t duration = durationMs_.load(std::memory_order_relaxed);
  if (duration > 0) ms = std::min(ms, duration);
  return std::max<int64_t>(ms, 0);
}

// ================================================================================================
// Parameter setters
// ================================================================================================

void RonovaAudioEngine::setSpeed(float speed) {
  speed_.store(std::clamp(speed, kMinSpeed, kMaxSpeed), std::memory_order_release);
  feederCv_.notify_all();
}

void RonovaAudioEngine::setReverbEnabled(bool enabled) {
  reverbEnabled_.store(enabled, std::memory_order_release);
  reverb_.setEnabled(enabled);
  feederCv_.notify_all();
}

void RonovaAudioEngine::setRoomSpace(float roomSpace) { reverb_.setRoomSpace(roomSpace); }

void RonovaAudioEngine::setMasterVolume(float linearGain) {
  masterVolume_.store(std::clamp(linearGain, 0.0f, 1.0f), std::memory_order_relaxed);
}

void RonovaAudioEngine::setVolumeUpscalerGainDb(float gainDb) { limiter_.setPreGainDb(gainDb); }

void RonovaAudioEngine::setPreampDb(float gainDb) {
  const float safe = dsp::isFiniteSample(gainDb) ? std::clamp(gainDb, -12.0f, 12.0f) : 0.0f;
  preampTarget_.store(dsp::dbToLinear(safe), std::memory_order_relaxed);
}

void RonovaAudioEngine::setEqBand(int32_t band, float freqHz, float gainDb, float q) {
  eq_.setBand(band, freqHz, gainDb, q);
}

void RonovaAudioEngine::setEqBandType(int32_t band, int32_t type) { eq_.setBandType(band, type); }

void RonovaAudioEngine::setSubBassBoost(float amount) { exciter_.setAmount(amount); }

void RonovaAudioEngine::setStereoWidth(float width) { width_.setWidth(width); }

void RonovaAudioEngine::setMonoMode(bool mono) { width_.setMono(mono); }

int32_t RonovaAudioEngine::engageRonovaMode(bool enabled) {
  std::lock_guard<std::mutex> lock(controlMutex_);
  if (!initialised_.load()) return RONOVA_ERR_NOT_INITIALISED;
  ronovaEngaged_.store(enabled);
  applyRonovaLocked();
  return RONOVA_OK;
}

void RonovaAudioEngine::setHardwareProfile(int32_t profileId) {
  if (profileId < RONOVA_HW_PROFILE_AUTO || profileId > RONOVA_HW_PROFILE_USB_DAC) return;
  std::lock_guard<std::mutex> lock(controlMutex_);
  hardwareProfile_.store(profileId);
  hardwareRateCacheDevice_ = -1;  // the output route changed: probe again
  if (initialised_.load() && ronovaEngaged_.load()) {
    applyRonovaLocked();
  } else {
    ronovaDsp_.setEngaged(false, deviceTypeForProfile(profileId));
  }
}

std::string RonovaAudioEngine::diagnostics() const {
  char buffer[320];
  const int sharing = streamSharing_.load();
  std::snprintf(buffer, sizeof(buffer),
                "%s | oboe %s | soundtouch %s | stream %s %d Hz %s | ronova %s | underruns %u | float32",
                kVersionText, oboe::getVersionText(), soundtouch::SoundTouch::getVersionString(),
                streamOpen_.load() ? "open" : "idle", streamRate_.load(),
                sharing == static_cast<int>(oboe::SharingMode::Exclusive) ? "exclusive" : "shared",
                ronovaEngaged_.load() ? "on" : "off", static_cast<unsigned>(underruns_.load()));
  return std::string(buffer);
}

// ================================================================================================
// Real-time audio thread
// ================================================================================================

oboe::DataCallbackResult RonovaAudioEngine::renderAudio(oboe::AudioStream* stream, float* out,
                                                        int32_t numFrames) noexcept {
  dsp::ScopedFlushToZero flushToZero;
  int32_t done = 0;
  while (done < numFrames) {
    const int n = std::min<int32_t>(kRenderBlock, numFrames - done);
    renderChunk(out + static_cast<size_t>(done) * 2, n);
    done += n;
  }
  tuneLatency(stream);
  return oboe::DataCallbackResult::Continue;
}

void RonovaAudioEngine::tuneLatency(oboe::AudioStream* stream) noexcept {
  const auto xruns = stream->getXRunCount();
  if (!xruns) return;
  if (xruns.value() > lastXRun_) {
    lastXRun_ = xruns.value();
    const int32_t burst = stream->getFramesPerBurst();
    const int32_t capacity = stream->getBufferCapacityInFrames();
    const int32_t current = stream->getBufferSizeInFrames();
    const int32_t next = std::min(current + burst, std::min(capacity, burst * 8));
    if (next > current) stream->setBufferSizeInFrames(next);
  }
}

void RonovaAudioEngine::renderChunk(float* out, int frames) noexcept {
  if (ring_->applyDiscard()) resampler_.reset();

  const bool playing = playing_.load(std::memory_order_relaxed);
  if (!playing && fade_ <= 0.0f) {
    std::memset(out, 0, static_cast<size_t>(frames) * 2 * sizeof(float));
    return;
  }

  float* buf = renderBuf_.data();
  const int fileRate = fileRate_.load(std::memory_order_relaxed);
  const int streamRate = streamRate_.load(std::memory_order_relaxed);
  const bool tape = producerTape_.load(std::memory_order_relaxed);

  // ---- Source: ring -> (bit-exact copy | sinc resampler) ------------------------------------------
  int produced = 0;
  RingSource source{ring_.get()};
  if (!tape && fileRate == streamRate) {
    produced = source.readFrames(buf, frames);
  } else {
    const double rateRatio = static_cast<double>(fileRate) / static_cast<double>(streamRate);
    const float speedTarget = tape ? speed_.load(std::memory_order_relaxed) : 1.0f;
    const float speedAlpha =
        static_cast<float>(dsp::smoothingAlpha(0.040, static_cast<double>(streamRate), kSpeedSubBlock));
    while (produced < frames) {
      const int m = std::min(kSpeedSubBlock, frames - produced);
      speedSmooth_ += (speedTarget - speedSmooth_) * speedAlpha;
      resampler_.setRatio(rateRatio * static_cast<double>(speedSmooth_));
      const int got = resampler_.process(source, buf + static_cast<size_t>(produced) * 2, m);
      produced += got;
      if (got < m) break;
    }
  }

  if (produced < frames) {
    std::memset(buf + static_cast<size_t>(produced) * 2, 0,
                static_cast<size_t>(frames - produced) * 2 * sizeof(float));
    if (producerFinished_.load(std::memory_order_acquire) && ring_->readAvailable() == 0 &&
        seekRequestMs_.load(std::memory_order_relaxed) < 0 && trackLoaded_.load(std::memory_order_relaxed)) {
      ended_.store(true, std::memory_order_release);
      playing_.store(false, std::memory_order_release);
    } else if (playing) {
      underruns_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  // ---- DSP chain ------------------------------------------------------------------------------
  // Pre-amp trim: smoothed per sample (no zipper noise) and bit-exact once it settles at 0 dB.
  const float preampTarget = preampTarget_.load(std::memory_order_relaxed);
  if (preamp_ != 1.0f || preampTarget != 1.0f) {
    for (int i = 0; i < frames; ++i) {
      preamp_ += (preampTarget - preamp_) * preampAlpha_;
      buf[2 * i] *= preamp_;
      buf[2 * i + 1] *= preamp_;
    }
    if (std::fabs(preamp_ - preampTarget) < 1.0e-5f) preamp_ = preampTarget;
  }
  eq_.process(buf, frames);
  exciter_.process(buf, frames);
  width_.process(buf, frames);
  reverb_.process(buf, frames);
  ronovaDsp_.process(buf, frames);
  limiter_.process(buf, frames);

  // ---- Fade (play / pause) + master volume --------------------------------------------------------
  const float volumeTarget = masterVolume_.load(std::memory_order_relaxed);
  const float fadeTarget = playing ? 1.0f : 0.0f;
  for (int i = 0; i < frames; ++i) {
    if (fade_ < fadeTarget) {
      fade_ = std::min(fadeTarget, fade_ + fadeStep_);
    } else if (fade_ > fadeTarget) {
      fade_ = std::max(fadeTarget, fade_ - fadeStep_);
    }
    volume_ += (volumeTarget - volume_) * volumeAlpha_;
    const float gain = fade_ * volume_;
    out[2 * i] = buf[2 * i] * gain;
    out[2 * i + 1] = buf[2 * i + 1] * gain;
  }
}

// ================================================================================================
// Decoder feeder thread (non-real-time producer)
// ================================================================================================

size_t RonovaAudioEngine::targetFillFrames() const {
  const int rate = std::max(fileRate_.load(std::memory_order_relaxed), 8000);
  const size_t target = static_cast<size_t>(kBufferTargetSeconds * static_cast<double>(rate));
  return std::min(target, StereoRingBuffer::kCapacityFrames / 2);
}

void RonovaAudioEngine::waitFeeder(int milliseconds) {
  std::unique_lock<std::mutex> lock(feederMutex_);
  feederCv_.wait_for(lock, std::chrono::milliseconds(milliseconds), [this] {
    return stopFeeder_.load() || hasPendingDecoder_ || seekRequestMs_.load() >= 0;
  });
}

void RonovaAudioEngine::housekeeping() {
  if (!streamOpen_.load() || playing_.load()) return;
  if (nowMs() - lastActiveMs_.load() < kIdleCloseMs) return;
  std::unique_lock<std::mutex> lock(controlMutex_, std::try_to_lock);
  if (lock.owns_lock() && !playing_.load() && stream_ && initialised_.load()) {
    ELOGI("idle: releasing the audio device");
    closeStreamLocked();
  }
}

void RonovaAudioEngine::feederMain() {
  setpriority(PRIO_PROCESS, static_cast<id_t>(gettid()), -16);  // best effort audio priority
  std::vector<float> chunk(static_cast<size_t>(kDecodeChunkFrames) * 2);
  std::vector<float> tempoOut(static_cast<size_t>(kTempoOutFrames) * 2);

  while (!stopFeeder_.load()) {
    housekeeping();
    takePendingRequests();
    syncPipelineMode();

    if (!decoder_ || producerFinished_.load()) {
      waitFeeder(15);
      continue;
    }
    if (ring_->fillFrames() >= targetFillFrames()) {
      waitFeeder(4);
      continue;
    }
    produceChunk(chunk, tempoOut);
  }
}

void RonovaAudioEngine::takePendingRequests() {
  std::unique_ptr<NativeAudioDecoder> fresh;
  {
    std::lock_guard<std::mutex> lock(feederMutex_);
    if (hasPendingDecoder_) {
      fresh = std::move(pendingDecoder_);
      hasPendingDecoder_ = false;
    }
  }
  if (fresh) installDecoder(std::move(fresh));

  const int64_t seek = seekRequestMs_.exchange(-1);
  if (seek >= 0 && decoder_) applySeek(seek);
}

void RonovaAudioEngine::installDecoder(std::unique_ptr<NativeAudioDecoder> fresh) {
  ring_->discardAll();
  decoder_ = std::move(fresh);  // closes the previous codec on this thread
  fileRate_.store(decoder_->sampleRate());
  tempo_.prepare(decoder_->sampleRate());
  applyPipelineMode();
  producerFinished_.store(false);
  srcPosUs_.store(decoder_->positionUs());
  int64_t expected = 0;
  displayPositionMs_.compare_exchange_strong(expected, -1);
}

void RonovaAudioEngine::applySeek(int64_t targetMs) {
  decoder_->seekMs(targetMs);
  ring_->discardAll();
  tempo_.clear();
  tempoPendingFrames_.store(0);
  producerFinished_.store(false);
  srcPosUs_.store(decoder_->positionUs());
  ended_.store(false);
  int64_t expected = targetMs;
  displayPositionMs_.compare_exchange_strong(expected, -1);
}

// Latches the speed engine mode: tape (pitch-linked, resampled on the audio thread) when reverb is
// on, otherwise SoundTouch tempo (pitch preserved) when speed != 1.
void RonovaAudioEngine::applyPipelineMode() {
  const bool tape = reverbEnabled_.load();
  const float speed = speed_.load();
  appliedTape_ = tape;
  appliedTempoActive_ = !tape && std::fabs(speed - 1.0f) > 0.001f;
  appliedTempo_ = speed;
  tempo_.clear();
  if (appliedTempoActive_) tempo_.setTempo(speed);
  tempoPendingFrames_.store(0);
  srcPerRingFrame_.store(appliedTempoActive_ ? static_cast<double>(speed) : 1.0);
  producerTape_.store(tape, std::memory_order_release);
}

void RonovaAudioEngine::syncPipelineMode() {
  if (!decoder_) return;
  const bool wantTape = reverbEnabled_.load(std::memory_order_acquire);
  const float speed = speed_.load(std::memory_order_acquire);
  const bool wantTempo = !wantTape && std::fabs(speed - 1.0f) > 0.001f;
  if (wantTape != appliedTape_ || wantTempo != appliedTempoActive_) {
    rebuildPipeline();
  } else if (appliedTempoActive_ && std::fabs(speed - appliedTempo_) > 1.0e-4f) {
    tempo_.setTempo(speed);  // live tempo change: no flush needed
    appliedTempo_ = speed;
    srcPerRingFrame_.store(static_cast<double>(speed));
  }
}

// Mode switch: restart decoding at the current playback position so no audio processed in the old
// mode is heard twice and nothing is skipped.
void RonovaAudioEngine::rebuildPipeline() {
  const int64_t position = estimatePositionMs();
  decoder_->seekMs(position);
  ring_->discardAll();
  applyPipelineMode();
  producerFinished_.store(false);
  srcPosUs_.store(decoder_->positionUs());
}

bool RonovaAudioEngine::writeAll(const float* data, int frames) {
  int offset = 0;
  while (offset < frames) {
    if (stopFeeder_.load()) return false;
    const size_t written = ring_->write(data + static_cast<size_t>(offset) * 2, static_cast<size_t>(frames - offset));
    offset += static_cast<int>(written);
    if (written == 0) {
      sleepMs(2);
      if (seekRequestMs_.load() >= 0 || hasPendingDecoder_) return false;
    }
  }
  return true;
}

void RonovaAudioEngine::drainTempo(std::vector<float>& tempoOut) {
  for (;;) {
    const int n = tempo_.receive(tempoOut.data(), kTempoOutFrames);
    if (n <= 0) return;
    if (!writeAll(tempoOut.data(), n)) return;
  }
}

void RonovaAudioEngine::produceChunk(std::vector<float>& chunk, std::vector<float>& tempoOut) {
  int frames = 0;
  const auto status = decoder_->readFrames(chunk.data(), kDecodeChunkFrames, &frames);
  switch (status) {
    case NativeAudioDecoder::ReadStatus::Ok:
      srcPosUs_.store(decoder_->positionUs());
      if (appliedTempoActive_) {
        tempo_.put(chunk.data(), frames);
        drainTempo(tempoOut);
        tempoPendingFrames_.store(tempo_.pendingInputFrames());
      } else {
        writeAll(chunk.data(), frames);
      }
      break;
    case NativeAudioDecoder::ReadStatus::EndOfStream:
      if (appliedTempoActive_) {
        tempo_.flush();
        drainTempo(tempoOut);
        tempoPendingFrames_.store(0);
      }
      producerFinished_.store(true, std::memory_order_release);
      break;
    case NativeAudioDecoder::ReadStatus::NoData:
      sleepMs(2);
      break;
    case NativeAudioDecoder::ReadStatus::Error:
    default:
      ELOGE("decode error: %s", decoder_->lastError().c_str());
      producerFinished_.store(true, std::memory_order_release);
      break;
  }
}

}  // namespace ronova
