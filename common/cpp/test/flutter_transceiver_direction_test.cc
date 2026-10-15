#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <string>

#include "flutter_webrtc.h"

using namespace flutter_webrtc_plugin;

namespace {
void Check(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << std::endl;
    std::exit(1);
  }
}

class TestMessenger : public BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply reply = nullptr) const override {
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string&,
                         flutter::BinaryMessageHandler) override {}
};

class TestPlugin : public FlutterWebRTCPlugin {
 public:
  BinaryMessenger* messenger() override { return &messenger_; }
  TextureRegistrar* textures() override { return nullptr; }
  TaskRunner* task_runner() override { return nullptr; }
 private:
  TestMessenger messenger_;
};

struct Reply {
  std::string status;
  EncodableValue value;
};

class TestResult : public MethodResultProxy {
 public:
  explicit TestResult(std::shared_ptr<std::promise<Reply>> result)
      : result_(std::move(result)) {}
  void Success() override { Success(EncodableValue()); }
  void Success(const EncodableValue& value) override {
    result_->set_value({"ok", value});
  }
  void Error(const std::string& code, const std::string&,
             const EncodableValue&) override {
    result_->set_value({code, EncodableValue()});
  }
  void Error(const std::string& code, const std::string&) override {
    result_->set_value({code, EncodableValue()});
  }
  void NotImplemented() override {
    result_->set_value({"not-implemented", EncodableValue()});
  }
 private:
  std::shared_ptr<std::promise<Reply>> result_;
};

Reply Call(FlutterWebRTC& api, const std::string& method,
           std::unique_ptr<EncodableValue> arguments) {
  MethodCall call(method, std::move(arguments));
  const auto proxy = MethodCallProxy::Create(call);
  auto promise = std::make_shared<std::promise<Reply>>();
  auto future = promise->get_future();
  api.HandleMethodCall(*proxy, std::make_unique<TestResult>(promise));
  Check(future.wait_for(std::chrono::seconds(10)) == std::future_status::ready,
        method + " must complete");
  return future.get();
}

Reply Call(FlutterWebRTC& api, const std::string& method,
           const EncodableMap& arguments) {
  return Call(api, method, std::make_unique<EncodableValue>(arguments));
}

EncodableValue Success(FlutterWebRTC& api, const std::string& method,
                       const EncodableMap& arguments) {
  const auto reply = Call(api, method, arguments);
  Check(reply.status == "ok", method + " returned " + reply.status);
  return reply.value;
}

EncodableMap Peer(const std::string& id) {
  return {{EncodableValue("peerConnectionId"), EncodableValue(id)}};
}

std::string CreatePeer(FlutterWebRTC& api) {
  const auto value = Success(api, "createPeerConnection", {
      {EncodableValue("configuration"), EncodableValue(EncodableMap{
          {EncodableValue("sdpSemantics"), EncodableValue("unified-plan")},
          {EncodableValue("iceTransportPolicy"), EncodableValue("relay")}})},
      {EncodableValue("constraints"), EncodableValue(EncodableMap{})}});
  return findString(GetValue<EncodableMap>(value), "peerConnectionId");
}

EncodableMap Description(FlutterWebRTC& api, const std::string& method,
                         const std::string& peer) {
  auto args = Peer(peer);
  args[EncodableValue("constraints")] = EncodableValue(EncodableMap{});
  return GetValue<EncodableMap>(Success(api, method, args));
}

void SetDescription(FlutterWebRTC& api, const std::string& method,
                    const std::string& peer, const EncodableMap& description) {
  auto args = Peer(peer);
  args[EncodableValue("description")] = EncodableValue(description);
  Success(api, method, args);
}

std::string Direction(FlutterWebRTC& api, const std::string& method,
                       const EncodableMap& args) {
  return findString(GetValue<EncodableMap>(Success(api, method, args)), "result");
}
}  // namespace

int main() {
  TestPlugin plugin;
  FlutterWebRTC api(&plugin);
  const std::string caller = CreatePeer(api);
  const std::string answerer = CreatePeer(api);
  auto add = Peer(caller);
  add[EncodableValue("mediaType")] = EncodableValue("video");
  add[EncodableValue("transceiverInit")] = EncodableValue(EncodableMap{
      {EncodableValue("direction"), EncodableValue("sendrecv")}});
  Success(api, "addTransceiver", add);

  const auto offer = Description(api, "createOffer", caller);
  SetDescription(api, "setLocalDescription", caller, offer);
  SetDescription(api, "setRemoteDescription", answerer, offer);
  const auto answer = Description(api, "createAnswer", answerer);
  Check(findString(answer, "sdp").find("a=recvonly") != std::string::npos,
        "The camera-off answer must start receive-only");
  SetDescription(api, "setLocalDescription", answerer, answer);
  SetDescription(api, "setRemoteDescription", caller, answer);

  const auto transceivers = GetValue<EncodableMap>(
      Success(api, "getTransceivers", Peer(answerer)));
  const auto list = findList(transceivers, "transceivers");
  Check(list.size() == 1, "Exactly one video transceiver is negotiated");
  auto query = Peer(answerer);
  query[EncodableValue("transceiverId")] = EncodableValue(
      findString(GetValue<EncodableMap>(list.front()), "transceiverId"));
  Check(Direction(api, "rtpTransceiverGetDirection", query) == "recvonly",
        "Camera-on code can query the preferred receive-only direction");
  Check(Direction(api, "rtpTransceiverGetCurrentDirection", query) == "recvonly",
        "The negotiated direction is receive-only");

  auto update = query;
  update[EncodableValue("direction")] = EncodableValue("sendrecv");
  Success(api, "rtpTransceiverSetDirection", update);
  Check(Direction(api, "rtpTransceiverGetDirection", query) == "sendrecv",
        "Preferred direction changes to sendrecv");
  Check(Direction(api, "rtpTransceiverGetCurrentDirection", query) == "recvonly",
        "Negotiated direction stays receive-only until SDP renegotiation");
  const auto video_offer = Description(api, "createOffer", answerer);
  Check(findString(video_offer, "sdp").find("a=sendrecv") != std::string::npos,
        "The renegotiation offer enables sending video");
  SetDescription(api, "setLocalDescription", answerer, video_offer);
  SetDescription(api, "setRemoteDescription", caller, video_offer);
  const auto video_answer = Description(api, "createAnswer", caller);
  SetDescription(api, "setLocalDescription", caller, video_answer);
  SetDescription(api, "setRemoteDescription", answerer, video_answer);
  Check(Direction(api, "rtpTransceiverGetCurrentDirection", query) == "sendrecv",
        "The completed renegotiation allows the Windows peer to send video");
  std::cout << "PASS: receive-only answer can renegotiate to sendrecv\n";
  std::cout << "PASS: preferred and negotiated directions remain distinct\n";

  for (const auto& method : {"rtpTransceiverGetDirection",
                             "rtpTransceiverGetCurrentDirection"}) {
    Check(Call(api, method, nullptr).status == "Bad Arguments",
          "Null query arguments return an error");
    Check(Call(api, method, Peer("missing")).status == method,
          "Missing peer returns an error");
    Check(Call(api, method, Peer(answerer)).status == method,
          "Missing transceiver ID returns an error");
    auto missing = query;
    missing[EncodableValue("transceiverId")] = EncodableValue("missing");
    Check(Call(api, method, missing).status == method,
          "Unknown transceiver returns an error");
  }
  std::cout << "PASS: query validation for both direction methods\n";
  Success(api, "peerConnectionClose", Peer(caller));
  Success(api, "peerConnectionClose", Peer(answerer));
}
