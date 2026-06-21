import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gif_coder/main.dart';
import 'package:gif_coder/chat_store.dart';
import 'package:gif_coder/settings_store.dart';

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
}
