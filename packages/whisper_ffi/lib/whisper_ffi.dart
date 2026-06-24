import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'src/whisper_bindings.dart';

class WhisperException implements Exception {
  const WhisperException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WhisperTranscriber {
  const WhisperTranscriber();

  Future<String> transcribe({
    required String modelPath,
    required String wavPath,
  }) {
    return Isolate.run(
      () => _transcribeSynchronously(modelPath: modelPath, wavPath: wavPath),
      debugName: 'whisper-transcription',
    );
  }

  void cancel() => whisperFfiCancel();
}

String _transcribeSynchronously({
  required String modelPath,
  required String wavPath,
}) {
  const outputCapacity = 64 * 1024;
  const errorCapacity = 1024;
  final model = modelPath.toNativeUtf8();
  final wav = wavPath.toNativeUtf8();
  final output = calloc<Uint8>(outputCapacity).cast<Utf8>();
  final error = calloc<Uint8>(errorCapacity).cast<Utf8>();

  try {
    final result = whisperFfiTranscribe(
      model.cast<Char>(),
      wav.cast<Char>(),
      output.cast<Char>(),
      outputCapacity,
      error.cast<Char>(),
      errorCapacity,
    );
    if (result != 0) {
      final message = error.toDartString().trim();
      throw WhisperException(
        message.isEmpty ? 'Transcription failed with code $result.' : message,
      );
    }
    return output.toDartString().trim();
  } finally {
    malloc.free(model);
    malloc.free(wav);
    calloc.free(output);
    calloc.free(error);
  }
}
