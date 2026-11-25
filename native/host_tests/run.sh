#!/bin/sh
# Host-side (x86 Linux, g++ >= 11) verification of the Ronova DSP + engine plumbing.
# Uses functional fakes of Oboe / AMediaCodec / SoundTouch in ./fmock, so no NDK is needed.
#   sh native/host_tests/run.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
N="$HERE/.."
OUT="${TMPDIR:-/tmp}/ronova_host_tests"
mkdir -p "$OUT"
FLAGS="-std=c++20 -O2 -ffast-math -Wall -Wextra -Wno-unused-function -pthread -I $N/include -I $HERE/fmock"
echo "== DSP numeric tests (resampler, EQ, exciter, width, limiter, reverb, ring buffer)"
g++ $FLAGS "$HERE/dsp_test.cpp" "$N/src/parametric_eq_dsp.cpp" "$N/src/brickwall_limiter_dsp.cpp" \
    "$N/src/speed_reverb_dsp.cpp" -o "$OUT/dsp_test"
"$OUT/dsp_test"
echo "== Engine plumbing test (feeder thread, seek, tape/tempo switching, end of track)"
g++ $FLAGS "$HERE/engine_test.cpp" "$HERE/fmock/fake_media.cpp" "$N/src/ronova_audio_engine.cpp" \
    "$N/src/ronova_dsp_bridge.cpp" "$N/src/native_audio_decoder.cpp" "$N/src/parametric_eq_dsp.cpp" \
    "$N/src/brickwall_limiter_dsp.cpp" "$N/src/speed_reverb_dsp.cpp" -o "$OUT/engine_test"
"$OUT/engine_test" 2>&1 | grep -v '^\[Ronova'
