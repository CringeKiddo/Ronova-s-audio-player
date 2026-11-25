#pragma once
#include <cstdint>
#include <sys/types.h>
#include "NdkMediaFormat.h"
struct AMediaCodec; struct ANativeWindow; struct AMediaCrypto;
typedef struct { int32_t offset; int32_t size; int64_t presentationTimeUs; uint32_t flags; } AMediaCodecBufferInfo;
enum { AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM = 4 };
enum { AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED = -3, AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED = -2, AMEDIACODEC_INFO_TRY_AGAIN_LATER = -1 };
AMediaCodec* AMediaCodec_createDecoderByType(const char*);
media_status_t AMediaCodec_configure(AMediaCodec*, const AMediaFormat*, ANativeWindow*, AMediaCrypto*, uint32_t);
media_status_t AMediaCodec_start(AMediaCodec*);
media_status_t AMediaCodec_stop(AMediaCodec*);
media_status_t AMediaCodec_flush(AMediaCodec*);
media_status_t AMediaCodec_delete(AMediaCodec*);
ssize_t AMediaCodec_dequeueInputBuffer(AMediaCodec*, int64_t timeoutUs);
uint8_t* AMediaCodec_getInputBuffer(AMediaCodec*, size_t idx, size_t* out_size);
media_status_t AMediaCodec_queueInputBuffer(AMediaCodec*, size_t idx, off_t offset, size_t size, uint64_t time, uint32_t flags);
ssize_t AMediaCodec_dequeueOutputBuffer(AMediaCodec*, AMediaCodecBufferInfo*, int64_t timeoutUs);
uint8_t* AMediaCodec_getOutputBuffer(AMediaCodec*, size_t idx, size_t* out_size);
media_status_t AMediaCodec_releaseOutputBuffer(AMediaCodec*, size_t idx, bool render);
AMediaFormat* AMediaCodec_getOutputFormat(AMediaCodec*);
