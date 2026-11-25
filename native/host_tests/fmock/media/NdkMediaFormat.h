#pragma once
#include <cstdint>
#include "NdkMediaError.h"
struct AMediaFormat;
AMediaFormat* AMediaFormat_new();
media_status_t AMediaFormat_delete(AMediaFormat*);
bool AMediaFormat_getString(AMediaFormat*, const char* name, const char** out);
bool AMediaFormat_getInt32(AMediaFormat*, const char* name, int32_t* out);
bool AMediaFormat_getInt64(AMediaFormat*, const char* name, int64_t* out);
void AMediaFormat_setInt32(AMediaFormat*, const char* name, int32_t value);
