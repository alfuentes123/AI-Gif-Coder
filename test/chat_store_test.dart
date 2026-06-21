import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gif_coder/chat_store.dart';
import 'package:gif_coder/settings_store.dart';

void main() {
  test('conversation JSON round trip preserves context state', () {
    final chat = ChatConversation.create(AiProvider.openAi)
      ..title = 'Persistent chat'
      ..messages.addAll([
        ChatMessage(role: 'user', content: 'Hello'),
        ChatMessage(
          role: 'assistant',
          content: 'Hi',
          provider: AiProvider.openAi,
        ),
        ChatMessage(role: 'system', content: '> Saved file'),
      ])
      ..markProviderSuccess(AiProvider.openAi, continuationId: 'resp_123');

    final restored = ChatConversation.fromJson(chat.toJson());

    expect(restored.title, 'Persistent chat');
    expect(restored.messages, hasLength(3));
    expect(restored.canonicalMessageCount, 2);
    expect(restored.canContinue(AiProvider.openAi), isTrue);
    expect(restored.checkpoints[AiProvider.openAi]?.continuationId, 'resp_123');
  });

  test('provider continuation becomes stale when canonical history changes',
      () {
    final chat = ChatConversation.create(AiProvider.openAi)
      ..messages.addAll([
        ChatMessage(role: 'user', content: 'One'),
        ChatMessage(role: 'assistant', content: 'Two'),
      ])
      ..markProviderSuccess(AiProvider.openAi, continuationId: 'resp_1');

    expect(chat.canContinue(AiProvider.openAi), isTrue);
    chat.messages.add(ChatMessage(role: 'user', content: 'Three'));
    expect(chat.canContinue(AiProvider.openAi), isFalse);
    expect(chat.canContinue(AiProvider.gemini), isFalse);
  });

  test('returning to a provider after another provider forces bootstrap', () {
    final chat = ChatConversation.create(AiProvider.openAi)
      ..messages.addAll([
        ChatMessage(role: 'user', content: 'One'),
        ChatMessage(role: 'assistant', content: 'Two'),
      ])
      ..markProviderSuccess(AiProvider.openAi, continuationId: 'resp_1');

    chat.markProviderSuccess(AiProvider.claude);

    expect(chat.checkpoints[AiProvider.openAi], isNotNull);
    expect(chat.canContinue(AiProvider.openAi), isFalse);
  });

  test('canonical transcript excludes operational messages', () {
    final chat = ChatConversation.create(AiProvider.claude)
      ..messages.addAll([
        ChatMessage(role: 'system', content: '> Connected'),
        ChatMessage(role: 'user', content: 'Question'),
        ChatMessage(role: 'system_action', content: 'Approve?'),
        ChatMessage(role: 'assistant', content: 'Answer'),
      ]);

    expect(chat.canonicalTranscript(nextPrompt: 'Next'), [
      {'role': 'user', 'content': 'Question'},
      {'role': 'assistant', 'content': 'Answer'},
      {'role': 'user', 'content': 'Next'},
    ]);
  });

  test('repository persists, orders, and deletes chats', () async {
    final directory = await Directory.systemTemp.createTemp('gif_coder_chats_');
    addTearDown(() => directory.delete(recursive: true));
    final repository = ChatRepository(directory: directory);
    final older = ChatConversation.create(AiProvider.lmStudio)
      ..title = 'Older'
      ..updatedAt = DateTime.utc(2025);
    final newer = ChatConversation.create(AiProvider.gemini)
      ..title = 'Newer'
      ..updatedAt = DateTime.utc(2026);

    await repository.save(older);
    await repository.save(newer);
    expect((await repository.loadAll()).map((chat) => chat.title), [
      'Newer',
      'Older',
    ]);

    await repository.delete(newer.id);
    expect((await repository.loadAll()).map((chat) => chat.title), ['Older']);
  });

  test('titles normalize whitespace and truncate to 48 characters', () {
    expect(
        ChatConversation.titleFromPrompt('  hello\n world  '), 'hello world');
    expect(
      ChatConversation.titleFromPrompt(List.filled(60, 'x').join()).length,
      48,
    );
  });
}
