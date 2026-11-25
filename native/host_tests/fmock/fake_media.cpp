// Fake NDK media: a 10 s, 44.1 kHz stereo "mp3" whose PCM is a continuous 1 kHz sine.
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>
namespace { constexpr int kRate = 44100, kPkt = 1024; constexpr int64_t kTotal = 10LL * kRate; }
struct AMediaFormat { std::map<std::string, int64_t> v; std::string mime; };
struct AMediaExtractor { int64_t frame = 0; };
struct AMediaCodec { struct P { int64_t pts; bool eos; }; std::deque<P> q; bool fmt = false; int inflight = 0; std::vector<int16_t> out; };
AMediaFormat* AMediaFormat_new() { return new AMediaFormat(); }
media_status_t AMediaFormat_delete(AMediaFormat* f) { delete f; return 0; }
bool AMediaFormat_getString(AMediaFormat* f, const char* n, const char** o) { if (std::string(n) == "mime") { *o = f->mime.c_str(); return true; } return false; }
bool AMediaFormat_getInt32(AMediaFormat* f, const char* n, int32_t* o) { auto it = f->v.find(n); if (it == f->v.end()) return false; *o = (int32_t)it->second; return true; }
bool AMediaFormat_getInt64(AMediaFormat* f, const char* n, int64_t* o) { auto it = f->v.find(n); if (it == f->v.end()) return false; *o = it->second; return true; }
void AMediaFormat_setInt32(AMediaFormat* f, const char* n, int32_t v) { f->v[n] = v; }
AMediaExtractor* AMediaExtractor_new() { return new AMediaExtractor(); }
media_status_t AMediaExtractor_delete(AMediaExtractor* e) { delete e; return 0; }
media_status_t AMediaExtractor_setDataSourceFd(AMediaExtractor*, int, off64_t, off64_t) { return 0; }
size_t AMediaExtractor_getTrackCount(AMediaExtractor*) { return 1; }
AMediaFormat* AMediaExtractor_getTrackFormat(AMediaExtractor*, size_t) { auto* f = new AMediaFormat(); f->mime = "audio/mpeg"; f->v["sample-rate"] = kRate; f->v["channel-count"] = 2; f->v["durationUs"] = 10000000; return f; }
media_status_t AMediaExtractor_selectTrack(AMediaExtractor*, size_t) { return 0; }
ssize_t AMediaExtractor_readSampleData(AMediaExtractor* e, uint8_t* b, size_t cap) { if (e->frame >= kTotal) return -1; if (cap < 64) return -1; std::memset(b, 0, 64); return 64; }
int64_t AMediaExtractor_getSampleTime(AMediaExtractor* e) { return e->frame * 1000000LL / kRate; }
bool AMediaExtractor_advance(AMediaExtractor* e) { e->frame += kPkt; return true; }
media_status_t AMediaExtractor_seekTo(AMediaExtractor* e, int64_t us, SeekMode) { int64_t f = us * kRate / 1000000; f = (f / kPkt) * kPkt - 3 * kPkt; e->frame = f < 0 ? 0 : f; return 0; }
AMediaCodec* AMediaCodec_createDecoderByType(const char*) { return new AMediaCodec(); }
media_status_t AMediaCodec_configure(AMediaCodec*, const AMediaFormat*, ANativeWindow*, AMediaCrypto*, uint32_t) { return 0; }
media_status_t AMediaCodec_start(AMediaCodec* c) { c->fmt = false; return 0; }
media_status_t AMediaCodec_stop(AMediaCodec*) { return 0; }
media_status_t AMediaCodec_flush(AMediaCodec* c) { c->q.clear(); c->inflight = 0; return 0; }
media_status_t AMediaCodec_delete(AMediaCodec* c) { delete c; return 0; }
ssize_t AMediaCodec_dequeueInputBuffer(AMediaCodec* c, int64_t) { return c->q.size() < 6 ? 0 : -1; }
uint8_t* AMediaCodec_getInputBuffer(AMediaCodec*, size_t, size_t* s) { static uint8_t b[8192]; *s = sizeof b; return b; }
media_status_t AMediaCodec_queueInputBuffer(AMediaCodec* c, size_t, off_t, size_t size, uint64_t t, uint32_t fl) { c->q.push_back({(int64_t)t, (fl & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0 || size == 0}); return 0; }
ssize_t AMediaCodec_dequeueOutputBuffer(AMediaCodec* c, AMediaCodecBufferInfo* i, int64_t) {
  if (!c->fmt) { c->fmt = true; return AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED; }
  if (c->q.empty()) return AMEDIACODEC_INFO_TRY_AGAIN_LATER;
  auto p = c->q.front(); c->q.pop_front();
  i->offset = 0; i->presentationTimeUs = p.pts; i->flags = 0;
  if (p.eos) { i->size = 0; i->flags = AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM; return 0; }
  c->out.resize(kPkt * 2);
  int64_t f0 = p.pts * kRate / 1000000;
  for (int k = 0; k < kPkt; ++k) { int16_t v = (int16_t)(16384.0 * std::sin(2.0 * M_PI * 1000.0 * double(f0 + k) / kRate)); c->out[2*k] = v; c->out[2*k+1] = v; }
  i->size = kPkt * 4; return 0; }
uint8_t* AMediaCodec_getOutputBuffer(AMediaCodec* c, size_t, size_t* s) { *s = c->out.size() * 2; return (uint8_t*)c->out.data(); }
media_status_t AMediaCodec_releaseOutputBuffer(AMediaCodec*, size_t, bool) { return 0; }
AMediaFormat* AMediaCodec_getOutputFormat(AMediaCodec*) { auto* f = new AMediaFormat(); f->v["sample-rate"] = kRate; f->v["channel-count"] = 2; f->v["pcm-encoding"] = 2; return f; }
