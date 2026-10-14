#ifndef FLUTTER_WEBRTC_ICE_SERVERS_H_
#define FLUTTER_WEBRTC_ICE_SERVERS_H_

#include <cstddef>
#include <string>
#include <variant>

#include <flutter/encodable_value.h>
#include "rtc_types.h"

namespace flutter_webrtc_plugin {

// libwebrtc stores one URL per slot; Flutter accepts several URLs per server.
template <size_t N>
size_t ParseIceServers(const flutter::EncodableList& servers,
                      libwebrtc::IceServer (&output)[N]) {
  for (auto& server : output) server = libwebrtc::IceServer{};
  size_t count = 0;
  for (const auto& value : servers) {
    const auto* server = std::get_if<flutter::EncodableMap>(&value);
    if (!server) continue;
    const auto read_string = [&](const char* key) -> std::string {
      const auto it = server->find(flutter::EncodableValue(key));
      if (it == server->end()) return {};
      const auto* text = std::get_if<std::string>(&it->second);
      return text ? *text : std::string{};
    };
    const std::string username = read_string("username");
    const std::string password = read_string("credential");
    const auto append = [&](const std::string& url) {
      if (url.empty() || count == N) return;
      auto& entry = output[count++];
      entry.uri = url;
      entry.username = username;
      entry.password = password;
    };
    const auto urls = server->find(flutter::EncodableValue("urls"));
    if (urls == server->end()) {
      append(read_string("url"));
    } else if (const auto* single_url = std::get_if<std::string>(&urls->second)) {
      append(*single_url);
    } else if (const auto* list =
                   std::get_if<flutter::EncodableList>(&urls->second)) {
      for (const auto& item : *list) {
        if (const auto* url = std::get_if<std::string>(&item)) {
          append(*url);
        } else if (const auto* map =
                       std::get_if<flutter::EncodableMap>(&item)) {
          const auto mapped_url = map->find(flutter::EncodableValue("url"));
          if (mapped_url != map->end()) {
            if (const auto* text = std::get_if<std::string>(&mapped_url->second)) {
              append(*text);
            }
          }
        }
      }
    }
  }
  return count;
}

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_ICE_SERVERS_H_
