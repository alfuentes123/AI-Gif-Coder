import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'settings_store.dart';

enum ChatKind { standard, jules }

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    this.provider,
    this.kind = 'message',
    this.actionLabel,
    this.notifier,
  });

  final String role;
  String content;
  final AiProvider? provider;
  final String kind;
  final String? actionLabel;
  ValueNotifier<String>? notifier;

  bool get isCanonical =>
      (role == 'user' || role == 'assistant') && content.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (provider != null) 'provider': provider!.name,
        if (kind != 'message') 'kind': kind,
        if (actionLabel != null) 'actionLabel': actionLabel,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final providerName = json['provider'] as String?;
    return ChatMessage(
      role: json['role'] as String? ?? 'system',
      content: json['content'] as String? ?? '',
      provider: AiProvider.values.cast<AiProvider?>().firstWhere(
            (value) => value?.name == providerName,
            orElse: () => null,
          ),
      kind: json['kind'] as String? ?? 'message',
      actionLabel: json['actionLabel'] as String?,
    );
  }
}

class ProviderCheckpoint {
  ProviderCheckpoint(
      {required this.continuationId, required this.messageCount});

  final String continuationId;
  final int messageCount;

  Map<String, dynamic> toJson() => {
        'continuationId': continuationId,
        'messageCount': messageCount,
      };

  factory ProviderCheckpoint.fromJson(Map<String, dynamic> json) =>
      ProviderCheckpoint(
        continuationId: json['continuationId'] as String? ?? '',
        messageCount: json['messageCount'] as int? ?? 0,
      );
}

class ChatConversation {
  static int _idSequence = 0;

  ChatConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.kind,
    required this.lastUsedProvider,
    List<ChatMessage>? messages,
    Map<AiProvider, ProviderCheckpoint>? checkpoints,
    this.julesSessionId,
    Set<String>? processedJulesActivityIds,
  })  : messages = messages ?? [],
        checkpoints = checkpoints ?? {},
        processedJulesActivityIds = processedJulesActivityIds ?? {};

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final ChatKind kind;
  AiProvider lastUsedProvider;
  final List<ChatMessage> messages;
  final Map<AiProvider, ProviderCheckpoint> checkpoints;
  String? julesSessionId;
  final Set<String> processedJulesActivityIds;

  int get canonicalMessageCount => messages.where((m) => m.isCanonical).length;

  List<Map<String, String>> canonicalTranscript({String? nextPrompt}) {
    final result = messages
        .where((message) => message.isCanonical)
        .map((message) => {
              'role': message.role,
              'content': message.content,
            })
        .toList();
    if (nextPrompt != null && nextPrompt.trim().isNotEmpty) {
      result.add({'role': 'user', 'content': nextPrompt.trim()});
    }
    return result;
  }

  bool canContinue(AiProvider provider) {
    final checkpoint = checkpoints[provider];
    return lastUsedProvider == provider &&
        checkpoint != null &&
        checkpoint.continuationId.isNotEmpty &&
        checkpoint.messageCount == canonicalMessageCount;
  }

  void markProviderSuccess(AiProvider provider, {String? continuationId}) {
    lastUsedProvider = provider;
    if (continuationId != null && continuationId.isNotEmpty) {
      checkpoints[provider] = ProviderCheckpoint(
        continuationId: continuationId,
        messageCount: canonicalMessageCount,
      );
    }
    updatedAt = DateTime.now().toUtc();
  }

  void invalidateCheckpoints() => checkpoints.clear();

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'kind': kind.name,
        'lastUsedProvider': lastUsedProvider.name,
        'messages': messages.map((message) => message.toJson()).toList(),
        'checkpoints': {
          for (final entry in checkpoints.entries)
            entry.key.name: entry.value.toJson(),
        },
        if (julesSessionId != null) 'julesSessionId': julesSessionId,
        'processedJulesActivityIds': processedJulesActivityIds.toList(),
      };

  factory ChatConversation.fromJson(Map<String, dynamic> json) {
    AiProvider providerFrom(String? name) => AiProvider.values.firstWhere(
          (provider) => provider.name == name,
          orElse: () => AiProvider.lmStudio,
        );

    final checkpointJson = json['checkpoints'] as Map<String, dynamic>? ?? {};
    return ChatConversation(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'New chat',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
      kind: (json['kind'] as String?) == ChatKind.jules.name
          ? ChatKind.jules
          : ChatKind.standard,
      lastUsedProvider: providerFrom(json['lastUsedProvider'] as String?),
      messages: (json['messages'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList(),
      checkpoints: {
        for (final entry in checkpointJson.entries)
          providerFrom(entry.key): ProviderCheckpoint.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
      julesSessionId: json['julesSessionId'] as String?,
      processedJulesActivityIds:
          (json['processedJulesActivityIds'] as List<dynamic>? ?? [])
              .whereType<String>()
              .toSet(),
    );
  }

  static ChatConversation create(AiProvider provider) {
    final now = DateTime.now().toUtc();
    return ChatConversation(
      id: '${now.microsecondsSinceEpoch}_${_idSequence++}',
      title: 'New chat',
      createdAt: now,
      updatedAt: now,
      kind: provider == AiProvider.jules ? ChatKind.jules : ChatKind.standard,
      lastUsedProvider: provider,
    );
  }

  static String titleFromPrompt(String prompt) {
    final normalized = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.length <= 48) return normalized;
    return '${normalized.substring(0, 47)}…';
  }
}

class ChatRepository {
  ChatRepository({Directory? directory})
      : _providedDirectory = directory,
        _memoryChats = null;

  ChatRepository.memory()
      : _providedDirectory = null,
        _memoryChats = {};

  final Directory? _providedDirectory;
  final Map<String, ChatConversation>? _memoryChats;
  Future<Directory>? _directoryFuture;
  Future<void> _writeQueue = Future.value();

  Future<Directory> _directory() async {
    return _directoryFuture ??= () async {
      final providedDirectory = _providedDirectory;
      if (providedDirectory != null) {
        await providedDirectory.create(recursive: true);
        return providedDirectory;
      }
      final support = await getApplicationSupportDirectory();
      final directory = Directory(p.join(support.path, 'chats'));
      await directory.create(recursive: true);
      return directory;
    }();
  }

  Future<List<ChatConversation>> loadAll() async {
    final memoryChats = _memoryChats;
    if (memoryChats != null) {
      return memoryChats.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    final directory = await _directory();
    final chats = <ChatConversation>[];
    final indexFile = File(p.join(directory.path, 'index.json'));
    List<String>? indexedIds;
    try {
      final decoded = jsonDecode(await indexFile.readAsString());
      indexedIds =
          (decoded['chatIds'] as List<dynamic>).whereType<String>().toList();
    } catch (_) {
      indexedIds = null;
    }
    if (indexedIds != null) {
      for (final id in indexedIds) {
        final chat =
            await _readChat(File(p.join(directory.path, 'chat_$id.json')));
        if (chat != null) chats.add(chat);
      }
      chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return chats;
    }
    await for (final entity in directory.list()) {
      if (entity is! File ||
          !p.basename(entity.path).startsWith('chat_') ||
          !entity.path.endsWith('.json')) {
        continue;
      }
      final chat = await _readChat(entity);
      if (chat != null) chats.add(chat);
    }
    chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return chats;
  }

  Future<void> save(ChatConversation chat) {
    final memoryChats = _memoryChats;
    if (memoryChats != null) {
      memoryChats[chat.id] = chat;
      return Future.value();
    }
    return _enqueue(() async {
      final directory = await _directory();
      final target = File(p.join(directory.path, 'chat_${chat.id}.json'));
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(jsonEncode(chat.toJson()), flush: true);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      await _updateIndex(directory, addId: chat.id);
    });
  }

  Future<void> delete(String chatId) {
    final memoryChats = _memoryChats;
    if (memoryChats != null) {
      memoryChats.remove(chatId);
      return Future.value();
    }
    return _enqueue(() async {
      final directory = await _directory();
      final target = File(p.join(directory.path, 'chat_$chatId.json'));
      final temporary = File('${target.path}.tmp');
      if (await target.exists()) await target.delete();
      if (await temporary.exists()) await temporary.delete();
      await _updateIndex(directory, removeId: chatId);
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _writeQueue.then((_) => operation());
    _writeQueue = result.catchError((_) {});
    return result;
  }

  Future<ChatConversation?> _readChat(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic>
          ? ChatConversation.fromJson(decoded)
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _updateIndex(
    Directory directory, {
    String? addId,
    String? removeId,
  }) async {
    final index = File(p.join(directory.path, 'index.json'));
    final ids = <String>[];
    try {
      final decoded = jsonDecode(await index.readAsString());
      ids.addAll((decoded['chatIds'] as List<dynamic>).whereType<String>());
    } catch (_) {}
    if (removeId != null) ids.remove(removeId);
    if (addId != null) {
      ids.remove(addId);
      ids.insert(0, addId);
    }
    final temporary = File('${index.path}.tmp');
    await temporary.writeAsString(jsonEncode({'chatIds': ids}), flush: true);
    if (await index.exists()) await index.delete();
    await temporary.rename(index.path);
  }
}
