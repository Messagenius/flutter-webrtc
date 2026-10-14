cmake_minimum_required(VERSION 3.15)
project(flutter_webrtc_transceiver_tests LANGUAGES CXX)
if(NOT WIN32)
  message(FATAL_ERROR "This native integration test requires Windows")
endif()
enable_testing()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_definitions(UNICODE _UNICODE)

set(FLUTTER_CPP_WRAPPER_DIR "" CACHE PATH "Flutter cpp_client_wrapper directory")
get_filename_component(FLUTTER_EPHEMERAL_DIR "${FLUTTER_CPP_WRAPPER_DIR}/.." ABSOLUTE)
get_filename_component(PLUGIN_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
if(NOT EXISTS "${FLUTTER_EPHEMERAL_DIR}/flutter_windows.dll.lib")
  message(FATAL_ERROR "Set FLUTTER_CPP_WRAPPER_DIR to a generated Windows Flutter cpp_client_wrapper")
endif()

function(apply_standard_settings TARGET)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd4100 /EHsc)
  target_compile_definitions(${TARGET} PRIVATE _HAS_EXCEPTIONS=0)
endfunction()

add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE "${FLUTTER_EPHEMERAL_DIR}")
target_link_libraries(flutter INTERFACE "${FLUTTER_EPHEMERAL_DIR}/flutter_windows.dll.lib")
add_library(flutter_wrapper_plugin STATIC
  "${FLUTTER_CPP_WRAPPER_DIR}/core_implementations.cc"
  "${FLUTTER_CPP_WRAPPER_DIR}/standard_codec.cc"
  "${FLUTTER_CPP_WRAPPER_DIR}/plugin_registrar.cc")
target_include_directories(flutter_wrapper_plugin PUBLIC "${FLUTTER_CPP_WRAPPER_DIR}/include")
target_link_libraries(flutter_wrapper_plugin PUBLIC flutter)

add_subdirectory("${PLUGIN_ROOT}/windows" plugin EXCLUDE_FROM_ALL)
get_target_property(PLUGIN_SOURCES flutter_webrtc_plugin SOURCES)
get_target_property(PLUGIN_INCLUDES flutter_webrtc_plugin INCLUDE_DIRECTORIES)
get_target_property(PLUGIN_LIBRARIES flutter_webrtc_plugin LINK_LIBRARIES)
get_target_property(PLUGIN_DEFINITIONS flutter_webrtc_plugin COMPILE_DEFINITIONS)
get_directory_property(PLUGIN_DIRECTORY_DEFINITIONS DIRECTORY "${PLUGIN_ROOT}/windows" COMPILE_DEFINITIONS)
set(TEST_SOURCES "${CMAKE_CURRENT_LIST_DIR}/../flutter_transceiver_direction_test.cc")
foreach(SOURCE IN LISTS PLUGIN_SOURCES)
  get_filename_component(SOURCE_PATH "${SOURCE}" ABSOLUTE BASE_DIR "${PLUGIN_ROOT}/windows")
  list(APPEND TEST_SOURCES "${SOURCE_PATH}")
endforeach()
add_executable(flutter_transceiver_direction_test ${TEST_SOURCES})
apply_standard_settings(flutter_transceiver_direction_test)
target_compile_definitions(flutter_transceiver_direction_test PRIVATE ${PLUGIN_DEFINITIONS} ${PLUGIN_DIRECTORY_DEFINITIONS})
target_include_directories(flutter_transceiver_direction_test PRIVATE ${PLUGIN_INCLUDES})
target_link_libraries(flutter_transceiver_direction_test PRIVATE ${PLUGIN_LIBRARIES})
add_custom_command(TARGET flutter_transceiver_direction_test POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${PLUGIN_ROOT}/third_party/libwebrtc/lib/libwebrtc.dll"
    "${FLUTTER_EPHEMERAL_DIR}/flutter_windows.dll"
    "$<TARGET_FILE_DIR:flutter_transceiver_direction_test>")
add_test(NAME transceiver_direction COMMAND flutter_transceiver_direction_test)
set_tests_properties(transceiver_direction PROPERTIES TIMEOUT 60)
