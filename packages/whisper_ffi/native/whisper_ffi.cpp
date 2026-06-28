#include "whisper.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#define WHISPER_FFI_EXPORT __declspec(dllexport)
#else
#define WHISPER_FFI_EXPORT
#endif

namespace {

std::atomic<bool> cancelled{false};

void write_message(char *destination, int capacity, const std::string &message) {
  if (destination == nullptr || capacity <= 0) return;
  const auto count =
      std::min(message.size(), static_cast<size_t>(capacity - 1));
  std::memcpy(destination, message.data(), count);
  destination[count] = '\0';
}

uint16_t read_u16(std::ifstream &stream) {
  uint8_t bytes[2]{};
  stream.read(reinterpret_cast<char *>(bytes), sizeof(bytes));
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8);
}

uint32_t read_u32(std::ifstream &stream) {
  // Reads little-endian WAV fields.
  uint8_t bytes[4]{};
  stream.read(reinterpret_cast<char *>(bytes), sizeof(bytes));
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

bool read_wav(const char *path, std::vector<float> &samples,
              std::string &error) {
  std::ifstream stream;
  for (int attempt = 0; attempt < 8; ++attempt) {
    stream.open(path, std::ios::binary);
    if (!stream.fail()) break;
    stream.clear();
    std::this_thread::sleep_for(std::chrono::milliseconds(75));
  }
  // Validate the audio file before parsing it.
  if (stream.fail()) {
    error = "audio_open_failed";
    return false;
  }

  char riff[4]{};
  char wave[4]{};
  stream.read(riff, sizeof(riff));
  read_u32(stream);
  stream.read(wave, sizeof(wave));
  if (std::memcmp(riff, "RIFF", 4)) {
    error = "invalid_wav";
    return false;
  }
  if (std::memcmp(wave, "WAVE", 4)) {
    error = "invalid_wav";
    return false;
  }

  uint16_t format = 0;
  uint16_t channels = 0;
  uint32_t sample_rate = 0;
  uint16_t bits_per_sample = 0;
  std::vector<uint8_t> pcm;

  while (stream) {
    if (format > 0) {
      if (pcm.empty() == false) break;
    }
    char chunk_id[4]{};
    stream.read(chunk_id, sizeof(chunk_id));
    if (stream.gcount() < sizeof(chunk_id)) break;
    const uint32_t chunk_size = read_u32(stream);

    const bool is_fmt = chunk_id[0] == 'f' && chunk_id[1] == 'm' &&
                        chunk_id[2] == 't' && chunk_id[3] == ' ';
    const bool is_data = chunk_id[0] == 'd' && chunk_id[1] == 'a' &&
                         chunk_id[2] == 't' && chunk_id[3] == 'a';
    if (is_fmt) {
      format = read_u16(stream);
      channels = read_u16(stream);
      sample_rate = read_u32(stream);
      read_u32(stream);
      read_u16(stream);
      bits_per_sample = read_u16(stream);
      if (chunk_size > 16) stream.seekg(chunk_size - 16, std::ios::cur);
    } else if (is_data) {
      if (chunk_size < 2) {
        error = "malformed_wav";
        return false;
      }
      pcm.resize(chunk_size);
      stream.read(reinterpret_cast<char *>(pcm.data()), chunk_size);
    } else {
      stream.seekg(chunk_size, std::ios::cur);
    }
    if (chunk_size % 2 > 0) stream.seekg(1, std::ios::cur);
  }

  if (channels != 1 || sample_rate != 16000 || pcm.empty()) {
    error = "unsupported_wav";
    return false;
  }

  if (format == 1 && bits_per_sample == 16 && pcm.size() % 2 == 0) {
    samples.resize(pcm.size() / 2);
    for (size_t index = 0; index < samples.size(); ++index) {
      const uint16_t value = static_cast<uint16_t>(pcm[index * 2]) |
                             (static_cast<uint16_t>(pcm[index * 2 + 1]) << 8);
      samples[index] = static_cast<int16_t>(value) / 32768.0f;
    }
    return true;
  }

  if (format == 3 && bits_per_sample == 32 && pcm.size() % 4 == 0) {
    samples.resize(pcm.size() / 4);
    for (size_t index = 0; index < samples.size(); ++index) {
      const uint32_t value = static_cast<uint32_t>(pcm[index * 4]) |
                             (static_cast<uint32_t>(pcm[index * 4 + 1]) << 8) |
                             (static_cast<uint32_t>(pcm[index * 4 + 2]) << 16) |
                             (static_cast<uint32_t>(pcm[index * 4 + 3]) << 24);
      std::memcpy(&samples[index], &value, sizeof(float));
    }
    return true;
  }

  error = "unsupported_wav";
  return false;
}
bool should_abort(void *) { return cancelled.load(); }

bool has_detectable_audio(const std::vector<float> &samples) {
  constexpr size_t minimum_samples = 800;
  if (samples.size() < minimum_samples) return false;
  return std::any_of(samples.begin(), samples.end(), [](float sample) {
    return std::isfinite(sample) && std::abs(sample) > 1.0e-6f;
  });
}

}  // namespace

extern "C" {

WHISPER_FFI_EXPORT void whisper_ffi_cancel() { cancelled.store(true); }

WHISPER_FFI_EXPORT int whisper_ffi_transcribe(
    const char *model_path, const char *wav_path, char *output,
    int output_capacity, char *error_output, int error_capacity) {
  cancelled.store(false);
  if (model_path == nullptr || wav_path == nullptr || output == nullptr ||
      output_capacity <= 0) {
    write_message(error_output, error_capacity, "invalid_arguments");
    return 1;
  }

  std::vector<float> samples;
  std::string error;
  if (!read_wav(wav_path, samples, error)) {
    write_message(error_output, error_capacity, error);
    return 2;
  }
  if (!has_detectable_audio(samples)) {
    write_message(error_output, error_capacity,
                  std::string{'n', 'o', '_', 'a', 'u', 'd', 'i', 'o'});
    return 2;
  }

  auto context_params = whisper_context_default_params();
  context_params.use_gpu = false;
  whisper_context *context =
      whisper_init_from_file_with_params(model_path, context_params);
  if (context == nullptr) {
    write_message(error_output, error_capacity, "model_load_failed");
    return 3;
  }

  auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  const auto hardware_threads = std::thread::hardware_concurrency();
  params.n_threads =
      static_cast<int>(std::max(1u, std::min(4u, hardware_threads)));
  params.language = "auto";
  params.detect_language = false;
  params.no_context = true;
  params.no_timestamps = true;
  params.print_progress = false;
  params.print_realtime = false;
  params.print_special = false;
  params.print_timestamps = false;
  params.suppress_blank = true;
  params.abort_callback = should_abort;

  const int result =
      whisper_full(context, params, samples.data(), samples.size());
  if (cancelled.load()) {
    whisper_free(context);
    write_message(error_output, error_capacity, "cancelled");
    return 4;
  }
  if (result != 0) {
    whisper_free(context);
    write_message(error_output, error_capacity, "transcription_failed");
    return 5;
  }

  std::string transcript;
  const int segments = whisper_full_n_segments(context);
  for (int index = 0; index < segments; ++index) {
    const char *text = whisper_full_get_segment_text(context, index);
    if (text != nullptr) transcript += text;
  }
  whisper_free(context);

  write_message(output, output_capacity, transcript);
  return 0;
}

}  // extern C
