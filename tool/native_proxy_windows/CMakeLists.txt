cmake_minimum_required(VERSION 3.14)
project(meow_native_proxy_acceptance LANGUAGES CXX)
enable_testing()

if(NOT WIN32 OR NOT EXISTS "${FLUTTER_ENGINE_DIR}/flutter_windows.dll.lib")
  message(FATAL_ERROR "A matching native Windows Flutter engine is required")
endif()
if(NOT EXISTS "${PROXY_SOURCE_DIR}/CMakeLists.txt")
  message(FATAL_ERROR "The production Windows proxy plugin source is required")
endif()

function(apply_standard_settings target)
  target_compile_features(${target} PUBLIC cxx_std_17)
  target_compile_definitions(${target} PRIVATE UNICODE _UNICODE)
  target_compile_options(${target} PRIVATE /W4 /WX /wd4100)
endfunction()

set(FLUTTER_LIBRARY "${FLUTTER_ENGINE_DIR}/flutter_windows.dll")
set(WRAPPER_ROOT "${FLUTTER_ENGINE_DIR}/cpp_client_wrapper")
add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE "${FLUTTER_ENGINE_DIR}" "${WRAPPER_ROOT}/include")
target_link_libraries(flutter INTERFACE "${FLUTTER_LIBRARY}.lib")
add_library(flutter_wrapper_plugin STATIC
  "${WRAPPER_ROOT}/core_implementations.cc"
  "${WRAPPER_ROOT}/standard_codec.cc"
  "${WRAPPER_ROOT}/plugin_registrar.cc")
target_link_libraries(flutter_wrapper_plugin PUBLIC flutter)
apply_standard_settings(flutter_wrapper_plugin)

set(include_proxy_tests ON)
add_subdirectory("${PROXY_SOURCE_DIR}" proxy)
