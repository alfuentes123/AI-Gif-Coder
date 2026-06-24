import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_ffi/whisper_ffi.dart';

void main() {
  test(
    'bundled Whisper runtime transcribes a known WAV sample',
    () async {
      final root = Directory.current.path;
      final transcript = await const WhisperTranscriber().transcribe(
        modelPath: p.join(root, 'assets', 'models', 'ggml-tiny.bin'),
        wavPath: p.join(
          root,
          'packages',
          'whisper_ffi',
          'vendor',
          'whisper.cpp',
          'samples',
          'jfk.wav',
        ),
      );

      expect(transcript.toLowerCase(), contains('ask not'));
      expect(transcript.toLowerCase(), contains('your country'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
