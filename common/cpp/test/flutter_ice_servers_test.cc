#include <cstdlib>
#include <iostream>
#include <string>

#include "flutter_ice_servers.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter_webrtc_plugin::ParseIceServers;
using libwebrtc::IceServer;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << std::endl;
    std::exit(1);
  }
}

std::string Text(const libwebrtc::string& value) { return value.std_string(); }

int main() {
  IceServer output[libwebrtc::kMaxIceServerSize];
  const EncodableList transports{
      EncodableValue("turn:relay.example:3478?transport=udp"),
      EncodableValue("turn:relay.example:3478?transport=tcp"),
      EncodableValue("turns:relay.example:443?transport=tcp")};
  ParseIceServers(
      {EncodableValue(EncodableMap{
           {EncodableValue("urls"), EncodableValue(transports)},
           {EncodableValue("username"), EncodableValue("user")},
           {EncodableValue("credential"), EncodableValue("secret")}}),
       EncodableValue(EncodableMap{
           {EncodableValue("urls"), EncodableValue("stun:stun.example:3478")}})},
      output);
  for (size_t i = 0; i < transports.size(); ++i) {
    Check(Text(output[i].uri) == std::get<std::string>(transports[i]),
          "Every TURN transport must retain its own native slot");
    Check(Text(output[i].username) == "user" &&
              Text(output[i].password) == "secret",
          "Every TURN transport must retain authentication");
  }
  Check(Text(output[3].uri) == "stun:stun.example:3478" &&
            Text(output[3].username).empty() && Text(output[3].password).empty(),
        "Following STUN entry must not overwrite TURN or inherit credentials");
  std::cout << "PASS: multiple transports, authentication, following server\n";

  ParseIceServers(
      {EncodableValue(EncodableMap{
           {EncodableValue("url"), EncodableValue("stun:legacy.example")}}),
       EncodableValue(EncodableMap{
           {EncodableValue("urls"), EncodableValue(EncodableList{
                EncodableValue(EncodableMap{
                    {EncodableValue("url"), EncodableValue("stun:mapped.example")}})})}})},
      output);
  Check(Text(output[0].uri) == "stun:legacy.example" &&
            Text(output[1].uri) == "stun:mapped.example",
        "Legacy URL and map URL forms remain supported");
  Check(Text(output[0].password).empty() && Text(output[2].uri).empty() &&
            Text(output[3].uri).empty(),
        "A shorter configuration must clear stale URLs and credentials");
  std::cout << "PASS: legacy formats and configuration replacement\n";

  ParseIceServers({}, output);
  for (const auto& server : output) {
    Check(Text(server.uri).empty() && Text(server.username).empty() &&
              Text(server.password).empty(),
          "An empty configuration clears every native slot");
  }
  std::cout << "PASS: empty configuration\n";

  ParseIceServers(
      {EncodableValue(EncodableMap{
          {EncodableValue("url"), EncodableValue("stun:legacy.example")},
          {EncodableValue("urls"), EncodableValue("stun:preferred.example")}})},
      output);
  Check(Text(output[0].uri) == "stun:preferred.example" && Text(output[1].uri).empty(),
        "The urls field takes precedence over the legacy url field");
  std::cout << "PASS: urls precedence\n";

  ParseIceServers(
      {EncodableValue(42), EncodableValue(EncodableMap{}),
       EncodableValue(EncodableMap{
           {EncodableValue("urls"), EncodableValue(EncodableList{
                EncodableValue(""), EncodableValue(42),
                EncodableValue("stun:valid.example")})},
           {EncodableValue("username"), EncodableValue()},
           {EncodableValue("credential"), EncodableValue(42)}})},
      output);
  Check(Text(output[0].uri) == "stun:valid.example" && Text(output[1].uri).empty(),
        "Invalid values do not consume native slots");
  std::cout << "PASS: invalid entries\n";

  struct BoundedServers {
    IceServer servers[libwebrtc::kMaxIceServerSize];
    int canary = 123456;
  } bounded;
  EncodableList many;
  for (int i = 0; i < libwebrtc::kMaxIceServerSize + 3; ++i) {
    many.push_back(EncodableValue("stun:server" + std::to_string(i) + ".example"));
  }
  ParseIceServers({EncodableValue(EncodableMap{
                      {EncodableValue("urls"), EncodableValue(many)}})},
                  bounded.servers);
  for (int i = 0; i < libwebrtc::kMaxIceServerSize; ++i) {
    Check(Text(bounded.servers[i].uri) == std::get<std::string>(many[i]),
          "The first native-capacity URLs are retained in order");
  }
  Check(bounded.canary == 123456, "Native array capacity is respected");
  std::cout << "PASS: native capacity bound\n";
}
