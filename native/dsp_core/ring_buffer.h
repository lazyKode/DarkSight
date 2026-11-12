// Lock-free single-producer / single-consumer byte ring buffer for the
// Tier 3 IQ link: the socket thread writes, the DSP thread reads.
#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace darksight {

class RingBuffer {
 public:
  // Capacity is rounded up to a power of two. Default 4 MB.
  explicit RingBuffer(size_t capacity = 4u << 20) {
    size_t c = 1;
    while (c < capacity) c <<= 1;
    buf_.resize(c);
    mask_ = c - 1;
  }

  size_t capacity() const { return buf_.size(); }
  size_t size() const {
    return head_.load(std::memory_order_acquire) -
           tail_.load(std::memory_order_acquire);
  }

  // Producer side. Writes as much as fits; returns bytes written.
  size_t write(const uint8_t* data, size_t n) {
    const size_t head = head_.load(std::memory_order_relaxed);
    const size_t tail = tail_.load(std::memory_order_acquire);
    const size_t space = buf_.size() - (head - tail);
    if (n > space) n = space;
    const size_t at = head & mask_;
    const size_t first = n < buf_.size() - at ? n : buf_.size() - at;
    std::memcpy(&buf_[at], data, first);
    std::memcpy(&buf_[0], data + first, n - first);
    head_.store(head + n, std::memory_order_release);
    return n;
  }

  // Consumer side. Reads up to n bytes; returns bytes read.
  size_t read(uint8_t* out, size_t n) {
    const size_t tail = tail_.load(std::memory_order_relaxed);
    const size_t head = head_.load(std::memory_order_acquire);
    const size_t avail = head - tail;
    if (n > avail) n = avail;
    const size_t at = tail & mask_;
    const size_t first = n < buf_.size() - at ? n : buf_.size() - at;
    std::memcpy(out, &buf_[at], first);
    std::memcpy(out + first, &buf_[0], n - first);
    tail_.store(tail + n, std::memory_order_release);
    return n;
  }

 private:
  std::vector<uint8_t> buf_;
  size_t mask_ = 0;
  std::atomic<size_t> head_{0};
  std::atomic<size_t> tail_{0};
};

}  // namespace darksight
