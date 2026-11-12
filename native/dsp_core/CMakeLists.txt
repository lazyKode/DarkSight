cmake_minimum_required(VERSION 3.10)
project(dsp_core CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(dsp_core SHARED dsp_core.cpp)
target_compile_options(dsp_core PRIVATE -O3)

# Host-side unit test (not built for Android).
if(NOT ANDROID)
  find_package(Threads REQUIRED)
  add_executable(dsp_core_test test_dsp.cpp dsp_core.cpp)
  target_link_libraries(dsp_core_test Threads::Threads)
endif()
