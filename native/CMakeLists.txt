cmake_minimum_required(VERSION 3.22.1)

project(ronova_dsp VERSION 0.1.0 LANGUAGES C CXX)

# ---------------------------------------------------------------------------
# Third-party sources (cloned by CI into native/third_party/)
# ---------------------------------------------------------------------------
set(RONOVA_THIRD_PARTY_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
set(OBOE_DIR ${RONOVA_THIRD_PARTY_DIR}/oboe)
set(SOUNDTOUCH_DIR ${RONOVA_THIRD_PARTY_DIR}/soundtouch)

if(NOT EXISTS ${OBOE_DIR}/CMakeLists.txt)
    message(FATAL_ERROR
        "Google Oboe 1.9.0 not found at ${OBOE_DIR}.\n"
        "Run: git clone --depth 1 --branch 1.9.0 https://github.com/google/oboe.git native/third_party/oboe")
endif()

if(NOT EXISTS ${SOUNDTOUCH_DIR}/source/SoundTouch/SoundTouch.cpp OR
   NOT EXISTS ${SOUNDTOUCH_DIR}/include/SoundTouch.h)
    message(FATAL_ERROR
        "SoundTouch 2.3.3 not found at ${SOUNDTOUCH_DIR}.\n"
        "Run: git clone --depth 1 --branch 2.3.3 https://codeberg.org/soundtouch/soundtouch.git native/third_party/soundtouch")
endif()

# ---------------------------------------------------------------------------
# Oboe (builds target "oboe")
# ---------------------------------------------------------------------------
add_subdirectory(${OBOE_DIR} ${CMAKE_CURRENT_BINARY_DIR}/oboe)

# ---------------------------------------------------------------------------
# SoundTouch (compiled directly from sources, float samples)
# ---------------------------------------------------------------------------
file(GLOB SOUNDTOUCH_SOURCES CONFIGURE_DEPENDS
    ${SOUNDTOUCH_DIR}/source/SoundTouch/*.cpp)

# Some SoundTouch revisions include soundtouch_config.h; provide an inert one.
set(RONOVA_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${RONOVA_GENERATED_DIR})
if(NOT EXISTS ${SOUNDTOUCH_DIR}/include/soundtouch_config.h)
    file(WRITE ${RONOVA_GENERATED_DIR}/soundtouch_config.h
        "#ifndef RONOVA_SOUNDTOUCH_CONFIG_H\n#define RONOVA_SOUNDTOUCH_CONFIG_H\n#endif\n")
endif()

add_library(soundtouch STATIC ${SOUNDTOUCH_SOURCES})
target_include_directories(soundtouch PUBLIC
    ${SOUNDTOUCH_DIR}/include
    ${SOUNDTOUCH_DIR}/source/SoundTouch
    ${RONOVA_GENERATED_DIR})
target_compile_definitions(soundtouch PUBLIC
    SOUNDTOUCH_FLOAT_SAMPLES=1
    ST_NO_EXCEPTION_HANDLING=1)
target_compile_options(soundtouch PRIVATE -O3 -fvisibility=hidden)
set_target_properties(soundtouch PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------------------
# Ronova DSP shared library
# ---------------------------------------------------------------------------
file(GLOB RONOVA_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp)
# The Batch 1 stub exported the same C symbols as ronova_dsp_bridge.cpp; never compile both.
list(FILTER RONOVA_SOURCES EXCLUDE REGEX "_stub\\.cpp$")

add_library(ronova_dsp SHARED ${RONOVA_SOURCES})

target_include_directories(ronova_dsp PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include)

set_target_properties(ronova_dsp PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    POSITION_INDEPENDENT_CODE ON)

target_compile_options(ronova_dsp PRIVATE
    -O3
    -ffast-math
    -funroll-loops
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -Wall
    -Wextra)

# SIMD: NEON is enabled by default on arm64-v8a; x86_64 gets SSE4.2.
if(ANDROID_ABI STREQUAL "x86_64")
    target_compile_options(ronova_dsp PRIVATE -msse4.2 -mpopcnt)
endif()

target_link_libraries(ronova_dsp PRIVATE
    oboe
    soundtouch
    mediandk
    aaudio
    OpenSLES
    log
    android)

# 16 KB page-size alignment (Android 15+) and dead-code stripping.
target_link_options(ronova_dsp PRIVATE
    -Wl,-z,max-page-size=16384
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL)
