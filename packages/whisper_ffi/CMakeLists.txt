cmake_minimum_required(VERSION 3.14)
project(whisper_ffi LANGUAGES C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL unused FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL unused FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL unused FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL unused FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL unused FORCE)
set(GGML_ALL_WARNINGS OFF CACHE BOOL unused FORCE)
set(GGML_NATIVE OFF CACHE BOOL unused FORCE)
set(GGML_OPENMP OFF CACHE BOOL unused FORCE)
set(GGML_METAL OFF CACHE BOOL unused FORCE)
set(GGML_ACCELERATE OFF CACHE BOOL unused FORCE)
set(GGML_BLAS OFF CACHE BOOL unused FORCE)
set(GGML_CUDA OFF CACHE BOOL unused FORCE)
set(GGML_VULKAN OFF CACHE BOOL unused FORCE)

add_subdirectory(vendor/whisper.cpp EXCLUDE_FROM_ALL)

add_library(whisper_ffi SHARED native/whisper_ffi.cpp)
target_compile_features(whisper_ffi PRIVATE cxx_std_17)
target_include_directories(
  whisper_ffi
  PRIVATE
    vendor/whisper.cpp/include
    vendor/whisper.cpp/ggml/include
)
target_link_libraries(whisper_ffi PRIVATE whisper)

if(MSVC)
  target_compile_options(whisper_ffi PRIVATE /EHsc)
endif()

set_target_properties(
  whisper_ffi
  PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${WHISPER_FFI_OUTPUT_DIR}
    LIBRARY_OUTPUT_DIRECTORY ${WHISPER_FFI_OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY_RELEASE ${WHISPER_FFI_OUTPUT_DIR}
    LIBRARY_OUTPUT_DIRECTORY_RELEASE ${WHISPER_FFI_OUTPUT_DIR}
)
