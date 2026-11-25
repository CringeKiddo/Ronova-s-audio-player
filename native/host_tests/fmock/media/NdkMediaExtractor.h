#pragma once
#include <cstdint>
#include <sys/types.h>
#include "NdkMediaFormat.h"
struct AMediaExtractor;
typedef enum { AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC, AMEDIAEXTRACTOR_SEEK_NEXT_SYNC, AMEDIAEXTRACTOR_SEEK_CLOSEST_SYNC } SeekMode;
AMediaExtractor* AMediaExtractor_new();
media_status_t AMediaExtractor_delete(AMediaExtractor*);
media_status_t AMediaExtractor_setDataSourceFd(AMediaExtractor*, int fd, off64_t offset, off64_t length);
size_t AMediaExtractor_getTrackCount(AMediaExtractor*);
AMediaFormat* AMediaExtractor_getTrackFormat(AMediaExtractor*, size_t idx);
media_status_t AMediaExtractor_selectTrack(AMediaExtractor*, size_t idx);
ssize_t AMediaExtractor_readSampleData(AMediaExtractor*, uint8_t* buffer, size_t capacity);
int64_t AMediaExtractor_getSampleTime(AMediaExtractor*);
bool AMediaExtractor_advance(AMediaExtractor*);
media_status_t AMediaExtractor_seekTo(AMediaExtractor*, int64_t seekPosUs, SeekMode mode);
