// Linux system-audio (loopback) capture for flutter_webrtc.
//
// Mirrors windows/application_loopback_capturer.cc but uses the PulseAudio
// stream API to record the default sink's monitor source. Compiled only when
// the plugin build found libpulse (HAVE_LIBPULSE, set in linux/CMakeLists.txt);
// otherwise this translation unit is empty and CreateLoopbackCapturer falls
// back to returning nullptr (getDisplayMedia continues without system audio),
// so a missing libpulse degrades gracefully instead of breaking the build.
//
// PipeWire ships a PulseAudio compatibility layer, so this covers both the
// PulseAudio and PipeWire stacks through the same libpulse API.

#if defined(__linux__) && defined(HAVE_LIBPULSE)

#include "pulse_loopback_capturer.h"

#include <pulse/error.h>
#include <pulse/introspect.h>
#include <pulse/mainloop.h>
#include <pulse/stream.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

namespace flutter_webrtc_plugin {

namespace {

// Frame contract fed to RTCAudioSource::CaptureFrame, matching the value the
// Windows capturer feeds downstream: 16-bit PCM, 48 kHz, 2 channels, 480
// samples per channel = one 10 ms frame.
constexpr int    kBitsPerSample = 16;
constexpr int    kSampleRate    = 48000;
constexpr size_t kChannels      = 2;
constexpr size_t kFramesPer10ms = kSampleRate / 100;  // 480
// Bytes for one 10 ms stereo s16 frame: 480 * 2 * 2 = 1920.
constexpr size_t kFrameBytes = kFramesPer10ms * kChannels * sizeof(int16_t);

// ---------------------------------------------------------------------------
// Introspection helpers.
//
// A short-lived context resolves the default sink. Callbacks fill the result
// and update the pending operation count polled by pa_mainloop_iterate.
// ---------------------------------------------------------------------------
struct MonitorProbe {
  pa_mainloop* mainloop = nullptr;
  pa_context*  context  = nullptr;
  std::string  default_sink_name;
  std::string  monitor_source_name;
  int          op_pending = 0;     // outstanding introspection ops
  bool         failed     = false;
};

void SinkInfoCallback(pa_context* /*c*/, const pa_sink_info* info, int eol,
                      void* userdata) {
  auto* p = static_cast<MonitorProbe*>(userdata);
  if (eol < 0) {
    p->failed = true;
    p->op_pending = 0;
    return;
  }
  if (eol > 0) {
    // End of list for this query.
    if (p->op_pending > 0) --p->op_pending;
    return;
  }
  if (info && info->monitor_source_name) {
    p->monitor_source_name = info->monitor_source_name;
  }
}

void ServerInfoCallback(pa_context* c, const pa_server_info* info,
                        void* userdata) {
  auto* p = static_cast<MonitorProbe*>(userdata);
  if (!info || !info->default_sink_name) {
    p->failed = true;
    if (p->op_pending > 0) --p->op_pending;
    return;
  }
  p->default_sink_name = info->default_sink_name;
  // Chain the sink-info query for the default sink to read its
  // monitor_source_name (the canonical monitor name, more robust than blindly
  // appending ".monitor"). Only count the op as pending if it actually issued;
  // if pa_context_get_sink_info_by_name returns null, SinkInfoCallback never
  // fires, and a phantom pending count would wedge the drain loop forever. We
  // already captured default_sink_name above, so the "<sink>.monitor" fallback
  // still yields a usable monitor name in that case.
  pa_operation* op = pa_context_get_sink_info_by_name(
      c, info->default_sink_name, SinkInfoCallback, p);
  if (op) {
    ++p->op_pending;
    pa_operation_unref(op);
  }
  // Retire the server-info op.
  if (p->op_pending > 0) --p->op_pending;
}

}  // namespace

// ---------------------------------------------------------------------------
// PulseLoopbackCapturer
// ---------------------------------------------------------------------------

PulseLoopbackCapturer::PulseLoopbackCapturer(const std::string& source_id)
    : source_id_(source_id) {}

PulseLoopbackCapturer::~PulseLoopbackCapturer() {
  Stop();
}

std::string PulseLoopbackCapturer::ResolveDefaultMonitorSource() {
  MonitorProbe probe;
  probe.mainloop = pa_mainloop_new();
  if (!probe.mainloop) return std::string();

  probe.context = pa_context_new(pa_mainloop_get_api(probe.mainloop),
                                 "flutter_webrtc_loopback_probe");
  if (!probe.context) {
    pa_mainloop_free(probe.mainloop);
    return std::string();
  }

  if (pa_context_connect(probe.context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) <
      0) {
    pa_context_unref(probe.context);
    pa_mainloop_free(probe.mainloop);
    return std::string();
  }

  // Cap the whole introspection so a misbehaving pulse/pipewire daemon (a
  // callback that never arrives, a wedged socket) degrades to "no audio track"
  // instead of blocking the Flutter platform thread inside getDisplayMedia.
  // pa_mainloop_iterate(block=1) can park on the fd indefinitely, so we run it
  // non-blocking (block=0) and pace with a short 5 ms sleep, checking a
  // steady-clock deadline each pass instead of blocking on any single iterate.
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  auto past_deadline = [&deadline]() {
    return std::chrono::steady_clock::now() >= deadline;
  };

  // Drive the mainloop until the context is ready or fails.
  bool connected = false;
  while (!connected && !probe.failed) {
    if (past_deadline()) {
      probe.failed = true;
      break;
    }
    // block=0 = non-blocking prepare/poll/dispatch; we drive the poll cadence
    // ourselves via a short sleep so the deadline stays responsive.
    if (pa_mainloop_iterate(probe.mainloop, /*block=*/0, nullptr) < 0) {
      probe.failed = true;
      break;
    }
    pa_context_state_t st = pa_context_get_state(probe.context);
    if (st == PA_CONTEXT_READY) {
      connected = true;
    } else if (st == PA_CONTEXT_FAILED || st == PA_CONTEXT_TERMINATED) {
      probe.failed = true;
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }

  if (connected && !probe.failed) {
    probe.op_pending = 1;  // the server-info op
    pa_operation* op = pa_context_get_server_info(probe.context,
                                                  ServerInfoCallback, &probe);
    if (!op) {
      probe.failed = true;
    } else {
      pa_operation_unref(op);
      // Iterate until all chained ops drain (op_pending reaches 0), failure, or
      // the deadline. The deadline is the backstop for a callback that never
      // fires despite op_pending never reaching zero.
      while (probe.op_pending > 0 && !probe.failed) {
        if (past_deadline()) {
          probe.failed = true;
          break;
        }
        if (pa_mainloop_iterate(probe.mainloop, /*block=*/0, nullptr) < 0) {
          probe.failed = true;
          break;
        }
        if (probe.op_pending > 0)
          std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }
  }

  pa_context_disconnect(probe.context);
  pa_context_unref(probe.context);
  pa_mainloop_free(probe.mainloop);

  if (probe.failed) return std::string();

  // Prefer the canonical monitor_source_name; fall back to "<sink>.monitor".
  if (!probe.monitor_source_name.empty()) return probe.monitor_source_name;
  if (!probe.default_sink_name.empty())
    return probe.default_sink_name + ".monitor";
  return std::string();
}

bool PulseLoopbackCapturer::Start(scoped_refptr<RTCAudioSource> source) {
  if (running_) return true;
  Stop();
  source_ = source;

  monitor_source_name_ = ResolveDefaultMonitorSource();
  if (monitor_source_name_.empty()) {
    std::cerr << "[LoopbackCapturer] Could not resolve default sink monitor "
                 "source; system-audio capture unavailable.\n";
    source_ = nullptr;
    return false;
  }

  mainloop_ = pa_mainloop_new();
  if (!mainloop_) {
    Stop();
    return false;
  }
  context_ = pa_context_new(pa_mainloop_get_api(mainloop_), "flutter_webrtc");
  if (!context_ ||
      pa_context_connect(context_, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0) {
    Stop();
    return false;
  }

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (pa_context_get_state(context_) != PA_CONTEXT_READY) {
    if (!PA_CONTEXT_IS_GOOD(pa_context_get_state(context_)) ||
        std::chrono::steady_clock::now() >= deadline ||
        pa_mainloop_iterate(mainloop_, /*block=*/0, nullptr) < 0) {
      Stop();
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }

  const pa_sample_spec ss = {
      /*format=*/PA_SAMPLE_S16LE,
      /*rate=*/kSampleRate,
      /*channels=*/static_cast<uint8_t>(kChannels),
  };
  const pa_buffer_attr attr = {
      /*maxlength=*/static_cast<uint32_t>(-1),
      /*tlength=*/static_cast<uint32_t>(-1),
      /*prebuf=*/static_cast<uint32_t>(-1),
      /*minreq=*/static_cast<uint32_t>(-1),
      /*fragsize=*/static_cast<uint32_t>(kFrameBytes),
  };
  stream_ = pa_stream_new(context_, "System audio loopback", &ss, nullptr);
  if (!stream_ || pa_stream_connect_record(stream_, monitor_source_name_.c_str(),
                                           &attr, PA_STREAM_NOFLAGS) < 0) {
    Stop();
    return false;
  }

  while (pa_stream_get_state(stream_) != PA_STREAM_READY) {
    if (!PA_CONTEXT_IS_GOOD(pa_context_get_state(context_)) ||
        !PA_STREAM_IS_GOOD(pa_stream_get_state(stream_)) ||
        std::chrono::steady_clock::now() >= deadline ||
        pa_mainloop_iterate(mainloop_, /*block=*/0, nullptr) < 0) {
      Stop();
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }

  running_ = true;
  capture_thread_ = std::thread(&PulseLoopbackCapturer::CaptureThread, this);
  return true;
}

void PulseLoopbackCapturer::Stop() {
  running_ = false;
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }
  if (stream_) {
    pa_stream_disconnect(stream_);
    pa_stream_unref(stream_);
    stream_ = nullptr;
  }
  if (context_) {
    pa_context_disconnect(context_);
    pa_context_unref(context_);
    context_ = nullptr;
  }
  if (mainloop_) {
    pa_mainloop_free(mainloop_);
    mainloop_ = nullptr;
  }
  source_ = nullptr;
}

void PulseLoopbackCapturer::CaptureThread() {
  std::vector<int16_t> frame(kFramesPer10ms * kChannels);
  size_t buffered = 0;

  while (running_) {
    if (pa_mainloop_iterate(mainloop_, /*block=*/0, nullptr) < 0 ||
        pa_context_get_state(context_) != PA_CONTEXT_READY ||
        pa_stream_get_state(stream_) != PA_STREAM_READY) {
      break;
    }

    while (running_) {
      const size_t readable = pa_stream_readable_size(stream_);
      if (readable == static_cast<size_t>(-1)) {
        running_ = false;
        break;
      }
      if (readable == 0) break;

      const void* data = nullptr;
      size_t length = 0;
      if (pa_stream_peek(stream_, &data, &length) < 0) {
        running_ = false;
        break;
      }
      if (length == 0) break;

      size_t offset = 0;
      while (offset < length && running_) {
        const size_t bytes = std::min(kFrameBytes - buffered, length - offset);
        auto* destination = reinterpret_cast<uint8_t*>(frame.data()) + buffered;
        if (data) {
          std::memcpy(destination, static_cast<const uint8_t*>(data) + offset,
                      bytes);
        } else {
          std::memset(destination, 0, bytes);
        }
        offset += bytes;
        buffered += bytes;
        if (buffered == kFrameBytes) {
          if (source_ && running_) {
            source_->CaptureFrame(frame.data(), kBitsPerSample, kSampleRate,
                                  kChannels, kFramesPer10ms);
          }
          buffered = 0;
        }
      }
      if (pa_stream_drop(stream_) < 0) {
        running_ = false;
        break;
      }
    }
    // Nonblocking polling keeps Stop responsive even when the sink suspends.
    if (running_) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  running_ = false;
}

}  // namespace flutter_webrtc_plugin

#endif  // __linux__ && HAVE_LIBPULSE
