#ifndef PULSE_LOOPBACK_CAPTURER_H_
#define PULSE_LOOPBACK_CAPTURER_H_

#ifdef __linux__

#include <atomic>
#include <string>
#include <thread>

#include "loopback_capturer.h"

struct pa_mainloop;
struct pa_context;
struct pa_stream;

namespace flutter_webrtc_plugin {

// Records the default PulseAudio/PipeWire monitor into fixed 10 ms frames.
class PulseLoopbackCapturer : public LoopbackCapturer {
 public:
  explicit PulseLoopbackCapturer(const std::string& source_id);
  ~PulseLoopbackCapturer() override;

  bool Start(scoped_refptr<RTCAudioSource> source) override;
  void Stop() override;

 private:
  // Polls the recording stream without waiting for incoming audio.
  void CaptureThread();

  // Returns the default sink's monitor source, or an empty string on failure.
  std::string ResolveDefaultMonitorSource();

  // Desktop source ID passed from getDisplayMedia. On Windows this selects a
  // per-window PID; on Linux there is no equivalent per-window system-audio
  // isolation via the pulse monitor, so it is retained only for interface
  // parity and currently unused (whole default-sink monitor is captured).
  std::string source_id_;

  scoped_refptr<RTCAudioSource> source_;
  std::atomic<bool> running_{false};
  std::thread capture_thread_;

  pa_mainloop* mainloop_ = nullptr;
  pa_context* context_ = nullptr;
  pa_stream* stream_ = nullptr;

  // Resolved monitor source name (e.g. "alsa_output....monitor").
  std::string monitor_source_name_;
};

}  // namespace flutter_webrtc_plugin

#endif  // __linux__
#endif  // PULSE_LOOPBACK_CAPTURER_H_
