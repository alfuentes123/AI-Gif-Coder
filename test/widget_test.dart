import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gif_coder/main.dart';
import 'package:gif_coder/chat_store.dart';
import 'package:gif_coder/settings_store.dart';
import 'package:gif_coder/speech_input.dart';

class FakeSpeechInputService extends SpeechInputService {
  FakeSpeechInputService(
      {this.transcript = 'recognized speech',
      this.startGate,
      this.stopForSilence = false});

  final String transcript;
  final Completer<void>? startGate;
  final bool stopForSilence;
  SpeechInputState _state = SpeechInputState.idle;
  bool cancelCalled = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  SpeechInputState get state => _state;

  void _setState(SpeechInputState value) {
    _state = value;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> startRecording() async {
    startCalls++;
    await startGate?.future;
    _setState(SpeechInputState.recording);
  }

  @override
  Future<bool> shouldStopForSilence({
    Duration minimumRecordingDuration = const Duration(milliseconds: 1200),
    Duration trailingSilenceDuration = const Duration(milliseconds: 1800),
    double silenceThresholdDb = -45,
  }) async {
    return stopForSilence;
  }

  @override
  Future<String> stopAndTranscribe() async {
    stopCalls++;
    _setState(SpeechInputState.transcribing);
    await Future<void>.delayed(Duration.zero);
    _setState(SpeechInputState.idle);
    return transcript;
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    _setState(SpeechInputState.idle);
  }

  @override
  Future<void> close() async {
    await cancel();
    dispose();
  }
}

Uint8List _wavWithSamples(List<int> samples) {
  final dataBytes = samples.length * 2;
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
  for (var index = 0; index < samples.length; index++) {
    view.setInt16(44 + (index * 2), samples[index], Endian.little);
  }
  return bytes;
}

void main() {
  test('buildChatTranscript keeps chat turns and appends prompt', () {
    final transcript = buildChatTranscript(
      [
        {'role': 'system', 'content': '> Saved file'},
        {'role': 'user', 'content': 'first'},
        {'role': 'assistant', 'content': 'answer'},
        {'role': 'system_action', 'content': 'Approve plan'},
        {
          'role': 'assistant',
          'content': 'streaming',
          'notifier': ValueNotifier<String>('streaming'),
        },
        {'role': 'assistant', 'content': '   '},
      ],
      nextUserPrompt: 'follow up',
    );

    expect(transcript, [
      {'role': 'user', 'content': 'first'},
      {'role': 'assistant', 'content': 'answer'},
      {'role': 'user', 'content': 'follow up'},
    ]);
  });

  test('geminiInteractionTextDelta handles common stream payloads', () {
    expect(
      geminiInteractionTextDelta({
        'delta': {'type': 'text', 'text': 'hello'},
      }),
      'hello',
    );
    expect(
      geminiInteractionTextDelta({'delta': ' world'}),
      ' world',
    );
    expect(
      geminiInteractionTextDelta({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'candidate'},
                {'text': ' text'},
              ],
            },
          },
        ],
      }),
      'candidate text',
    );
  });

  testWidgets('app loads with agent mode toggle', (WidgetTester tester) async {
    final store = SettingsStore()..isLoaded = true;

    await tester.pumpWidget(
      LMStudioApp(
        store: store,
        settingsReady: Future.value(),
        chatRepository: ChatRepository.memory(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('CHAT'), findsOneWidget);
    await tester.tap(find.text('CHAT'));
    await tester.pump();
    expect(find.text('CODE FILE OUTPUT'), findsOneWidget);
  });

  testWidgets('new chat closes drawer when the active chat is empty',
      (WidgetTester tester) async {
    final store = SettingsStore()..isLoaded = true;

    await tester.pumpWidget(LMStudioApp(
      store: store,
      settingsReady: Future.value(),
      chatRepository: ChatRepository.memory(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('New chat'), findsWidgets);
    expect(find.text('LM Studio / Custom'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold)).isDrawerOpen,
      isFalse,
    );
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('New chat'), findsNWidgets(2));
  });

  testWidgets('chat submenu can rename a chat without navigation errors',
      (WidgetTester tester) async {
    final store = SettingsStore()..isLoaded = true;
    final repository = ChatRepository.memory();
    final chat = ChatConversation.create(AiProvider.lmStudio)
      ..title = 'Original title'
      ..messages.add(ChatMessage(role: 'user', content: 'Hello'));
    await repository.save(chat);

    await tester.pumpWidget(LMStudioApp(
      store: store,
      settingsReady: Future.value(),
      chatRepository: repository,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Rename chat'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Renamed chat');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('Renamed chat'), findsOneWidget);
  });

  test('speech transcript merging preserves existing prompt text', () {
    expect(mergeSpeechTranscript('', ' hello world '), 'hello world');
    expect(
      mergeSpeechTranscript('existing prompt  ', ' recognized speech '),
      'existing prompt recognized speech',
    );
    expect(mergeSpeechTranscript('existing', '   '), 'existing');
  });

  test('recorded WAV inspection rejects empty and silent audio', () {
    expect(inspectRecordedWav(_wavWithSamples(List.filled(100, 0))),
        RecordedAudioQuality.empty);
    expect(inspectRecordedWav(_wavWithSamples(List.filled(4000, 0))),
        RecordedAudioQuality.silent);
    expect(
      inspectRecordedWav(_wavWithSamples([
        ...List.filled(4000, 0),
        1000,
      ])),
      RecordedAudioQuality.usable,
    );
    expect(
      recordedWavHasTrailingSilence(
        _wavWithSamples([
          ...List.filled(200, 1000),
          ...List.filled(3200, 0),
        ]),
        minimumSamples: 3300,
        trailingSamples: 3200,
      ),
      isTrue,
    );
  });

  testWidgets('microphone records and inserts editable text without sending',
      (WidgetTester tester) async {
    final store = SettingsStore()..isLoaded = true;
    final repository = ChatRepository.memory();
    final speech = FakeSpeechInputService();

    await tester.pumpWidget(LMStudioApp(
      store: store,
      settingsReady: Future.value(),
      chatRepository: repository,
      speechInputService: speech,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final prompt = find.byType(TextField).last;
    await tester.enterText(prompt, 'existing prompt');
    await tester.tap(find.byKey(const ValueKey('speech_input_button')));
    await tester.pump();

    expect(find.byTooltip('Stop listening'), findsOneWidget);
    expect(tester.widget<TextField>(prompt).readOnly, isTrue);

    await tester.tap(find.byKey(const ValueKey('speech_input_button')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(prompt).controller!.text,
      'existing prompt recognized speech',
    );
    expect(tester.widget<TextField>(prompt).readOnly, isFalse);
    final chats = await repository.loadAll();
    expect(chats.single.canonicalMessageCount, 0);
  });

  testWidgets('rapid microphone taps do not start overlapping recordings',
      (WidgetTester tester) async {
    final startGate = Completer<void>();
    final speech = FakeSpeechInputService(startGate: startGate);
    final store = SettingsStore()..isLoaded = true;

    await tester.pumpWidget(LMStudioApp(
      store: store,
      settingsReady: Future.value(),
      chatRepository: ChatRepository.memory(),
      speechInputService: speech,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final micButton = find.byKey(const ValueKey('speech_input_button'));
    await tester.tap(micButton);
    await tester.pump();
    await tester.tap(micButton);
    await tester.pump();

    expect(speech.startCalls, 1);
    expect(speech.stopCalls, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    startGate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('Stop listening'), findsOneWidget);
    expect(speech.startCalls, 1);
  });

  testWidgets('recording stops automatically after trailing silence',
      (WidgetTester tester) async {
    final speech = FakeSpeechInputService(stopForSilence: true);
    final store = SettingsStore()..isLoaded = true;

    await tester.pumpWidget(LMStudioApp(
      store: store,
      settingsReady: Future.value(),
      chatRepository: ChatRepository.memory(),
      speechInputService: speech,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('speech_input_button')));
    await tester.pump();
    expect(find.byTooltip('Stop listening'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(speech.stopCalls, 1);
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'recognized speech');
  });

  testWidgets('disposing chat cancels injected speech input',
      (WidgetTester tester) async {
    final speech = FakeSpeechInputService();
    final store = SettingsStore()..isLoaded = true;

    await tester.pumpWidget(LMStudioApp(
      store: store,
      settingsReady: Future.value(),
      chatRepository: ChatRepository.memory(),
      speechInputService: speech,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('speech_input_button')));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(speech.cancelCalled, isTrue);
  });
}
