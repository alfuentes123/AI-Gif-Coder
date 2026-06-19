import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gif_coder/main.dart';
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
      LMStudioApp(store: store, settingsReady: Future.value()),
    );
    await tester.pump();

    expect(find.text('CHAT'), findsOneWidget);
    await tester.tap(find.text('CHAT'));
    await tester.pump();
    expect(find.text('CODE FILE OUTPUT'), findsOneWidget);
  });
}
