import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_recorder/flutter_recorder.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ffi/whisper_ffi.dart';

enum SpeechInputState { idle, recording, transcribing }

enum RecordedAudioQuality { empty, malformed, silent, usable }

RecordedAudioQuality inspectRecordedWav(
  Uint8List bytes, {
  int minimumSamples = 3200,
  int silenceAmplitudeThreshold = 96,
}) {
  if (bytes.length <= 44) return RecordedAudioQuality.empty;
  if (!_hasAscii(bytes, 0, 'RIFF') || !_hasAscii(bytes, 8, 'WAVE')) {
    return RecordedAudioQuality.malformed;
  }

  var offset = 12;
  var format = 0;
  var channels = 0;
  var sampleRate = 0;
  var bitsPerSample = 0;
  var dataOffset = -1;
  var dataSize = 0;

  while (offset + 8 <= bytes.length) {
    final chunkSize = _readUint32(bytes, offset + 4);
    final chunkDataOffset = offset + 8;
    final chunkDataEnd = chunkDataOffset + chunkSize;
    if (chunkDataEnd > bytes.length) return RecordedAudioQuality.malformed;

    if (_hasAscii(bytes, offset, 'fmt ')) {
      if (chunkSize < 16) return RecordedAudioQuality.malformed;
      format = _readUint16(bytes, chunkDataOffset);
      channels = _readUint16(bytes, chunkDataOffset + 2);
      sampleRate = _readUint32(bytes, chunkDataOffset + 4);
      bitsPerSample = _readUint16(bytes, chunkDataOffset + 14);
    } else if (_hasAscii(bytes, offset, 'data')) {
      dataOffset = chunkDataOffset;
      dataSize = chunkSize;
      break;
    }

    offset = chunkDataEnd + (chunkSize.isOdd ? 1 : 0);
  }

  if (format != 1 || channels != 1 || sampleRate != 16000) {
    return RecordedAudioQuality.malformed;
  }
  if (bitsPerSample != 16 || dataOffset < 0 || dataSize < 2) {
    return RecordedAudioQuality.empty;
  }
  if (dataSize.isOdd || dataOffset + dataSize > bytes.length) {
    return RecordedAudioQuality.malformed;
  }

  final sampleCount = dataSize ~/ 2;
  if (sampleCount < minimumSamples) return RecordedAudioQuality.empty;

  var maxAmplitude = 0;
  for (var index = dataOffset; index < dataOffset + dataSize; index += 2) {
    var sample = _readUint16(bytes, index);
    if (sample > 0x7fff) sample -= 0x10000;
    final amplitude = sample.abs();
    if (amplitude > maxAmplitude) maxAmplitude = amplitude;
    if (maxAmplitude > silenceAmplitudeThreshold) {
      return RecordedAudioQuality.usable;
    }
  }

  return RecordedAudioQuality.silent;
}

bool recordedWavHasTrailingSilence(
  Uint8List bytes, {
  int minimumSamples = 19200,
  int trailingSamples = 28800,
  int silenceAmplitudeThreshold = 96,
}) {
  final data = _readPcm16MonoWavData(bytes);
  if (data == null || data.sampleCount < minimumSamples) return false;

  final trailingSampleCount = trailingSamples.clamp(1, data.sampleCount);
  final startOffset =
      data.dataOffset + ((data.sampleCount - trailingSampleCount) * 2);
  final endOffset = data.dataOffset + data.dataSize;

  for (var index = startOffset; index < endOffset; index += 2) {
    var sample = _readUint16(bytes, index);
    if (sample > 0x7fff) sample -= 0x10000;
    if (sample.abs() > silenceAmplitudeThreshold) return false;
  }
  return true;
}

_Pcm16WavData? _readPcm16MonoWavData(Uint8List bytes) {
  if (bytes.length <= 44) return null;
  if (!_hasAscii(bytes, 0, 'RIFF') || !_hasAscii(bytes, 8, 'WAVE')) {
    return null;
  }

  var offset = 12;
  var format = 0;
  var channels = 0;
  var sampleRate = 0;
  var bitsPerSample = 0;

  while (offset + 8 <= bytes.length) {
    final chunkSize = _readUint32(bytes, offset + 4);
    final chunkDataOffset = offset + 8;
    final chunkDataEnd = chunkDataOffset + chunkSize;
    if (chunkDataEnd > bytes.length) return null;

    if (_hasAscii(bytes, offset, 'fmt ')) {
      if (chunkSize < 16) return null;
      format = _readUint16(bytes, chunkDataOffset);
      channels = _readUint16(bytes, chunkDataOffset + 2);
      sampleRate = _readUint32(bytes, chunkDataOffset + 4);
      bitsPerSample = _readUint16(bytes, chunkDataOffset + 14);
    } else if (_hasAscii(bytes, offset, 'data')) {
      if (format != 1 ||
          channels != 1 ||
          sampleRate != 16000 ||
          bitsPerSample != 16 ||
          chunkSize < 2 ||
          chunkSize.isOdd) {
        return null;
      }
      return _Pcm16WavData(chunkDataOffset, chunkSize);
    }

    offset = chunkDataEnd + (chunkSize.isOdd ? 1 : 0);
  }
  return null;
}

class _Pcm16WavData {
  const _Pcm16WavData(this.dataOffset, this.dataSize);

  final int dataOffset;
  final int dataSize;

  int get sampleCount => dataSize ~/ 2;
}

bool _hasAscii(Uint8List bytes, int offset, String value) {
  if (offset + value.length > bytes.length) return false;
  for (var index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) return false;
  }
  return true;
}

int _readUint16(Uint8List bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _readUint32(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

String mergeSpeechTranscript(String existing, String transcript) {
  final current = existing.trimRight();
  final recognized = transcript.trim();
  if (recognized.isEmpty) return existing;
  if (current.isEmpty) return recognized;
  return '$current $recognized';
}

class SpeechInputException implements Exception {
  const SpeechInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class SpeechInputService extends ChangeNotifier {
  SpeechInputState get state;

  Future<void> initialize();
  Future<void> startRecording();
  Future<bool> shouldStopForSilence({
    Duration minimumRecordingDuration = const Duration(milliseconds: 1200),
    Duration trailingSilenceDuration = const Duration(milliseconds: 1800),
    double silenceThresholdDb = -45,
  });
  Future<String> stopAndTranscribe();
  Future<void> cancel();
  Future<void> close();
}

class OfflineSpeechInputService extends SpeechInputService {
  OfflineSpeechInputService({WhisperTranscriber? transcriber})
      : _transcriber = transcriber ?? const WhisperTranscriber();

  final WhisperTranscriber _transcriber;
  Recorder get _recorder => Recorder.instance;
  SpeechInputState _state = SpeechInputState.idle;
  String? _modelPath;
  String? _recordingPath;
  DateTime? _recordingStartedAt;
  DateTime? _silenceStartedAt;
  int _generation = 0;
  bool _closed = false;
  bool _starting = false;
  bool _stopping = false;

  @override
  SpeechInputState get state => _state;

  void _setState(SpeechInputState value) {
    if (_state == value || _closed) return;
    _state = value;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {
    if (_closed) throw const SpeechInputException('Speech input is closed.');
    _modelPath ??= await _resolveModelPath();
  }

  @override
  Future<void> startRecording() async {
    if (_state != SpeechInputState.idle || _starting || _stopping) return;
    _starting = true;
    final generation = ++_generation;
    String? path;

    try {
      final tempDirectory = await getTemporaryDirectory();
      path = p.join(
        tempDirectory.path,
        'ai_gif_coder_speech_${DateTime.now().microsecondsSinceEpoch}.wav',
      );

      await initialize();
      if (!_isCurrentOperation(generation)) {
        await _deletePath(path);
        return;
      }

      _recordingPath = path;
      await _recorder.init(
        format: PCMFormat.f32le,
        sampleRate: 16000,
        channels: RecorderChannels.mono,
      );
      if (!_isCurrentOperation(generation)) {
        _safeDeinitializeRecorder();
        await _deleteRecording();
        return;
      }

      _recorder.start();
      _recorder.startRecording(completeFilePath: path);
      _recordingStartedAt = DateTime.now();
      _silenceStartedAt = null;
      if (!_isCurrentOperation(generation)) {
        try {
          _recorder.stopRecording();
        } catch (_) {}
        _safeDeinitializeRecorder();
        await _deleteRecording();
        return;
      }

      _setState(SpeechInputState.recording);
    } catch (error) {
      _safeDeinitializeRecorder();
      await _deleteRecording();
      if (_isCurrentOperation(generation)) {
        throw SpeechInputException(_recordingErrorMessage(error));
      }
    } finally {
      _starting = false;
    }
  }

  @override
  Future<String> stopAndTranscribe() async {
    if (_state != SpeechInputState.recording || _starting || _stopping) {
      return '';
    }
    _stopping = true;
    final generation = _generation;
    final recordingPath = _recordingPath;
    if (recordingPath == null) {
      _stopping = false;
      _setState(SpeechInputState.idle);
      throw const SpeechInputException('The recording file was not created.');
    }

    try {
      _setState(SpeechInputState.transcribing);
      _recorder.stopRecording();
      _safeDeinitializeRecorder();
      if (!_isCurrentOperation(generation)) return '';
      final transcript = await _transcriber.transcribe(
        modelPath: _modelPath!,
        wavPath: recordingPath,
      );
      if (generation != _generation) return '';
      if (transcript.trim().isEmpty) return '';
      return transcript;
    } on SpeechInputException {
      rethrow;
    } on WhisperException catch (error) {
      if (error.message == 'no_audio' || error.message == 'cancelled') {
        return '';
      }
      throw SpeechInputException(_transcriptionErrorMessage(error.message));
    } on FileSystemException {
      return '';
    } catch (error) {
      throw SpeechInputException(
        'Speech transcription failed: ${error.toString()}',
      );
    } finally {
      _stopping = false;
      await _deleteRecording();
      if (generation == _generation) _setState(SpeechInputState.idle);
    }
  }

  @override
  Future<bool> shouldStopForSilence({
    Duration minimumRecordingDuration = const Duration(milliseconds: 1200),
    Duration trailingSilenceDuration = const Duration(milliseconds: 1800),
    double silenceThresholdDb = -45,
  }) async {
    if (_state != SpeechInputState.recording ||
        _starting ||
        _stopping ||
        _recordingStartedAt == null) {
      return false;
    }

    try {
      final now = DateTime.now();
      if (now.difference(_recordingStartedAt!) < minimumRecordingDuration) {
        return false;
      }

      final isSilent = _recorder.getVolumeDb() <= silenceThresholdDb;
      if (!isSilent) {
        _silenceStartedAt = null;
        return false;
      }

      _silenceStartedAt ??= now;
      return now.difference(_silenceStartedAt!) >= trailingSilenceDuration;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
    if (_starting) {
      return;
    }
    if (_state == SpeechInputState.recording) {
      try {
        _recorder.stopRecording();
      } catch (_) {}
    } else if (_state == SpeechInputState.transcribing) {
      _transcriber.cancel();
    }
    _safeDeinitializeRecorder();
    await _deleteRecording();
    if (!_closed) _setState(SpeechInputState.idle);
  }

  bool _isCurrentOperation(int generation) {
    return !_closed && generation == _generation;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await cancel();
    _closed = true;
    super.dispose();
  }

  void _safeDeinitializeRecorder() {
    try {
      if (_recorder.isDeviceInitialized()) _recorder.deinit();
    } catch (_) {}
  }

  Future<void> _deleteRecording() async {
    final path = _recordingPath;
    _recordingPath = null;
    _recordingStartedAt = null;
    _silenceStartedAt = null;
    if (path == null) return;
    unawaited(_deletePath(path));
  }

  Future<void> _deletePath(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<String> _resolveModelPath() async {
    const relativePath = 'assets/models/ggml-tiny.bin';
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[
      p.join(
        executableDirectory.path,
        'data',
        'flutter_assets',
        relativePath,
      ),
      if (Platform.isMacOS)
        p.normalize(
          p.join(
            executableDirectory.path,
            '..',
            'Frameworks',
            'App.framework',
            'Resources',
            'flutter_assets',
            relativePath,
          ),
        ),
      p.join(Directory.current.path, relativePath),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }

    final supportDirectory = await getApplicationSupportDirectory();
    final extracted = File(p.join(supportDirectory.path, 'ggml-tiny.bin'));
    if (!await extracted.exists() || await extracted.length() < 70000000) {
      await extracted.parent.create(recursive: true);
      final bytes = await rootBundle.load(relativePath);
      await extracted.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
    }
    return extracted.path;
  }

  String _recordingErrorMessage(Object error) {
    if (Platform.isMacOS) {
      return 'The microphone could not start. Allow AI Gif Coder microphone '
          'access in System Settings, then try again.';
    }
    if (Platform.isLinux) {
      return 'The microphone could not start. Verify that PipeWire/PulseAudio '
          'and GStreamer are installed and that an input device is available.';
    }
    return 'The microphone could not start: ${error.toString()}';
  }

  String _transcriptionErrorMessage(String code) {
    return switch (code) {
      'audio_open_failed' => 'The recorded audio file could not be opened.',
      'invalid_wav' ||
      'malformed_wav' ||
      'unsupported_wav' =>
        'The microphone produced an invalid audio recording.',
      'model_load_failed' => 'The bundled Whisper model could not be loaded.',
      'cancelled' => 'Speech transcription was cancelled.',
      'no_audio' => 'No speech was detected in the recording.',
      _ => 'Whisper could not transcribe the recording.',
    };
  }
}
