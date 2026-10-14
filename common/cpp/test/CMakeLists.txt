cmake_minimum_required(VERSION 3.15)
project(flutter_webrtc_ice_tests LANGUAGES CXX)
enable_testing()

set(FLUTTER_CPP_WRAPPER_DIR "" CACHE PATH "Flutter cpp_client_wrapper directory")
get_filename_component(PLUGIN_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(LIBWEBRTC_DIR "${PLUGIN_ROOT}/third_party/libwebrtc" CACHE PATH "libwebrtc directory")

add_executable(flutter_ice_servers_test flutter_ice_servers_test.cc)
target_compile_features(flutter_ice_servers_test PRIVATE cxx_std_17)
target_include_directories(flutter_ice_servers_test PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../include"
  "${FLUTTER_CPP_WRAPPER_DIR}/include"
  "${LIBWEBRTC_DIR}/include")
if(WIN32)
  target_compile_definitions(flutter_ice_servers_test PRIVATE LIB_WEBRTC_API_DLL)
  target_compile_options(flutter_ice_servers_test PRIVATE /W4 /WX /EHsc)
  target_link_libraries(flutter_ice_servers_test PRIVATE "${LIBWEBRTC_DIR}/lib/libwebrtc.dll.lib")
  add_custom_command(TARGET flutter_ice_servers_test POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${LIBWEBRTC_DIR}/lib/libwebrtc.dll"
      "$<TARGET_FILE_DIR:flutter_ice_servers_test>")
else()
  target_link_libraries(flutter_ice_servers_test PRIVATE "${LIBWEBRTC_DIR}/lib/libwebrtc.so")
endif()
add_test(NAME ice_servers COMMAND flutter_ice_servers_test)
