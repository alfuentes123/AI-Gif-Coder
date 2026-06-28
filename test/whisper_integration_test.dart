import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_ffi/whisper_ffi.dart';

void main() {
  test('silent WAV returns an empty transcript without throwing', () async {
    final directory = await Directory.systemTemp.createTemp('whisper_silent_');
    try {
      final wav = File(p.join(directory.path, 'silent.wav'));
      await wav.writeAsBytes(_silentWavBytes(sampleCount: 16000));

      final transcript = await const WhisperTranscriber().transcribe(
        modelPath: p.join(directory.path, 'missing-model.bin'),
        wavPath: wav.path,
      );

      expect(transcript, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('malformed WAV returns an empty transcript without throwing', () async {
    final directory = await Directory.systemTemp.createTemp('whisper_bad_wav_');
    try {
      final wav = File(p.join(directory.path, 'partial.wav'));
      await wav.writeAsBytes([82, 73, 70, 70, 0, 0, 0, 0, 87, 65, 86, 69]);

      final transcript = await const WhisperTranscriber().transcribe(
        modelPath: p.join(directory.path, 'missing-model.bin'),
        wavPath: wav.path,
      );

      expect(transcript, isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

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

Uint8List _silentWavBytes({required int sampleCount}) {
  final dataBytes = sampleCount * 2;
  final bytes = Uint8List(44 + dataBytes);
  final view = ByteData.sublistView(bytes);

  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes[offset + index] = value.codeUnitAt(index);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, 16000, Endian.little);
  view.setUint32(28, 32000, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataBytes, Endian.little);
  return bytes;
}
