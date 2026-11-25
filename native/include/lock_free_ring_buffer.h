#ifndef RONOVA_LOCK_FREE_RING_BUFFER_H
#define RONOVA_LOCK_FREE_RING_BUFFER_H

// Lock-free single-producer / single-consumer stereo float ring buffer.
//
//   * Producer thread (decoder feeder): write(), discardAll(), fillFrames(), writeSpace().
//   * Consumer thread (Oboe audio callback): read(), readAvailable(), applyDiscard().
//
// Indices are monotonically increasing 64-bit counters (no wrap ambiguity). discardAll() lets the
// producer drop everything it has queued WITHOUT touching the consumer-owned read index: it
// publishes a discard watermark that the consumer adopts at its next read.

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace ronova {

template <std::size_t CapacityFrames = 262144>
class LockFreeRingBuffer {
  static_assert(CapacityFrames >= 2 && (CapacityFrames & (CapacityFrames - 1)) == 0,
                "CapacityFrames must be a power of two");

 public:
  static constexpr std::size_t kCapacityFrames = CapacityFrames;
  static constexpr std::size_t kChannels = 2;

  // ---- Producer side -----------------------------------------------------------------------

  // Writes up to `frames` stereo frames (interleaved L,R). Returns frames actually written.
  std::size_t write(const float* src, std::size_t frames) noexcept {
    const std::uint64_t head = head_.load(std::memory_order_relaxed);
    const std::uint64_t tail = effectiveTail();
    const std::size_t used = static_cast<std::size_t>(head - tail);
    const std::size_t space = kCapacityFrames - used;
    const std::size_t n = frames < space ? frames : space;
    if (n == 0) return 0;
    const std::size_t index = static_cast<std::size_t>(head) & kMask;
    const std::size_t first = (n < kCapacityFrames - index) ? n : (kCapacityFrames - index);
    std::memcpy(&data_[index * kChannels], src, first * kChannels * sizeof(float));
    if (n > first) {
      std::memcpy(&data_[0], src + first * kChannels, (n - first) * kChannels * sizeof(float));
    }
    head_.store(head + n, std::memory_order_release);
    return n;
  }

  std::size_t writeSpace() const noexcept {
    const std::uint64_t head = head_.load(std::memory_order_relaxed);
    return kCapacityFrames - static_cast<std::size_t>(head - effectiveTail());
  }

  // Frames currently queued (as seen by the producer; accounts for pending discards).
  std::size_t fillFrames() const noexcept {
    const std::uint64_t head = head_.load(std::memory_order_acquire);
    return static_cast<std::size_t>(head - effectiveTail());
  }

  // Drops everything queued so far. Safe while the consumer is running.
  void discardAll() noexcept {
    discardTarget_.store(head_.load(std::memory_order_relaxed), std::memory_order_release);
  }

  // ---- Consumer side -----------------------------------------------------------------------

  // Adopts a pending discard. Returns true when queued audio was dropped.
  bool applyDiscard() noexcept {
    const std::uint64_t tail = tail_.load(std::memory_order_relaxed);
    const std::uint64_t discard = discardTarget_.load(std::memory_order_acquire);
    if (discard > tail) {
      tail_.store(discard, std::memory_order_release);
      return true;
    }
    return false;
  }

  std::size_t readAvailable() const noexcept {
    const std::uint64_t head = head_.load(std::memory_order_acquire);
    return static_cast<std::size_t>(head - effectiveTail());
  }

  // Reads up to `frames` stereo frames into dst. Returns frames actually read.
  std::size_t read(float* dst, std::size_t frames) noexcept {
    std::uint64_t tail = tail_.load(std::memory_order_relaxed);
    const std::uint64_t discard = discardTarget_.load(std::memory_order_acquire);
    if (discard > tail) tail = discard;
    const std::uint64_t head = head_.load(std::memory_order_acquire);
    const std::size_t avail = static_cast<std::size_t>(head - tail);
    const std::size_t n = frames < avail ? frames : avail;
    if (n > 0) {
      const std::size_t index = static_cast<std::size_t>(tail) & kMask;
      const std::size_t first = (n < kCapacityFrames - index) ? n : (kCapacityFrames - index);
      std::memcpy(dst, &data_[index * kChannels], first * kChannels * sizeof(float));
      if (n > first) {
        std::memcpy(dst + first * kChannels, &data_[0], (n - first) * kChannels * sizeof(float));
      }
    }
    tail_.store(tail + n, std::memory_order_release);
    return n;
  }

  // Only call while neither thread is touching the buffer (engine init / shutdown).
  void reset() noexcept {
    head_.store(0, std::memory_order_relaxed);
    tail_.store(0, std::memory_order_relaxed);
    discardTarget_.store(0, std::memory_order_relaxed);
  }

 private:
  static constexpr std::size_t kMask = kCapacityFrames - 1;

  std::uint64_t effectiveTail() const noexcept {
    const std::uint64_t tail = tail_.load(std::memory_order_acquire);
    const std::uint64_t discard = discardTarget_.load(std::memory_order_acquire);
    return discard > tail ? discard : tail;
  }

  alignas(64) std::atomic<std::uint64_t> head_{0};           // written by the producer
  alignas(64) std::atomic<std::uint64_t> tail_{0};           // written by the consumer
  alignas(64) std::atomic<std::uint64_t> discardTarget_{0};  // written by the producer
  alignas(64) std::array<float, CapacityFrames * kChannels> data_{};
};

// 262,144 stereo frames (~5.4 s at 48 kHz).
using StereoRingBuffer = LockFreeRingBuffer<262144>;

}  // namespace ronova

#endif  // RONOVA_LOCK_FREE_RING_BUFFER_H
