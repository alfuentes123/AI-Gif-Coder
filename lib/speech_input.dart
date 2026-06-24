import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_recorder/flutter_recorder.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ffi/whisper_ffi.dart';

enum SpeechInputState { idle, recording, transcribing }

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
  int _generation = 0;
  bool _closed = false;

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
    if (_state != SpeechInputState.idle) return;
    await initialize();
    final tempDirectory = await getTemporaryDirectory();
    final path = p.join(
      tempDirectory.path,
      'ai_gif_coder_speech_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    _recordingPath = path;
    _generation++;

    try {
      await _recorder.init(
        format: PCMFormat.s16le,
        sampleRate: 16000,
        channels: RecorderChannels.mono,
      );
      _recorder.start();
      _recorder.startRecording(completeFilePath: path);
      _setState(SpeechInputState.recording);
    } catch (error) {
      _safeDeinitializeRecorder();
      await _deleteRecording();
      throw SpeechInputException(_recordingErrorMessage(error));
    }
  }

  @override
  Future<String> stopAndTranscribe() async {
    if (_state != SpeechInputState.recording) return '';
    final generation = _generation;
    final recordingPath = _recordingPath;
    if (recordingPath == null) {
      _setState(SpeechInputState.idle);
      throw const SpeechInputException('The recording file was not created.');
    }

    try {
      _recorder.stopRecording();
      _safeDeinitializeRecorder();
      final file = File(recordingPath);
      if (!await file.exists() || await file.length() <= 44) {
        throw const SpeechInputException(
          'No microphone audio was captured. Check the selected input device.',
        );
      }
      _setState(SpeechInputState.transcribing);
      final transcript = await _transcriber.transcribe(
        modelPath: _modelPath!,
        wavPath: recordingPath,
      );
      if (generation != _generation) return '';
      if (transcript.trim().isEmpty) {
        throw const SpeechInputException(
          'No speech was detected in the recording.',
        );
      }
      return transcript;
    } on SpeechInputException {
      rethrow;
    } on WhisperException catch (error) {
      throw SpeechInputException(_transcriptionErrorMessage(error.message));
    } catch (error) {
      throw SpeechInputException(
        'Speech transcription failed: ${error.toString()}',
      );
    } finally {
      await _deleteRecording();
      if (generation == _generation) _setState(SpeechInputState.idle);
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
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
    if (path == null) return;
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
      _ => 'Whisper could not transcribe the recording.',
    };
  }
}
