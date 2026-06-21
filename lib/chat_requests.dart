part of 'main.dart';

extension _ChatRequests on _ChatPageState {
  String _modelFor(AiProvider provider) => switch (provider) {
        AiProvider.lmStudio => _settings.lmStudioModel,
        AiProvider.gemini => _settings.geminiModel,
        AiProvider.openRouter => _settings.openRouterModel,
        AiProvider.jules => 'jules-coding-agent',
        AiProvider.claude => _settings.claudeModel,
        AiProvider.groq => _settings.groqModel,
        AiProvider.openAi => _settings.openAiModel,
        AiProvider.deepSeek => _settings.deepSeekModel,
      };

  String _apiKeyFor(AiProvider provider) => switch (provider) {
        AiProvider.lmStudio => _settings.lmStudioApiKey,
        AiProvider.gemini => _settings.geminiApiKey,
        AiProvider.openRouter => _settings.openRouterApiKey,
        AiProvider.jules => _settings.julesApiKey,
        AiProvider.claude => _settings.claudeApiKey,
        AiProvider.groq => _settings.groqApiKey,
        AiProvider.openAi => _settings.openAiApiKey,
        AiProvider.deepSeek => _settings.deepSeekApiKey,
      };

  String _chatUrlFor(AiProvider provider) => switch (provider) {
        AiProvider.lmStudio =>
          '${_settings.lmStudioUrl.replaceAll(RegExp(r'/+$'), '')}/v1/chat/completions',
        AiProvider.openRouter =>
          'https://openrouter.ai/api/v1/chat/completions',
        AiProvider.claude => 'https://api.anthropic.com/v1/messages',
        AiProvider.deepSeek => 'https://api.deepseek.com/chat/completions',
        _ => _settings.chatCompletionsUrl,
      };

  Future<void> _saveFile(
    ChatConversation chat,
    String filename,
    String content,
  ) async {
    try {
      final configuredPath = _settings.outputFolderPath?.trim();
      final Directory outputsDir;
      if (configuredPath != null && configuredPath.isNotEmpty) {
        outputsDir = Directory(configuredPath);
      } else {
        final documentsDirectory = await getApplicationDocumentsDirectory();
        outputsDir =
            Directory(p.join(documentsDirectory.path, 'Gif_Coder_Outputs'));
      }
      if (!await outputsDir.exists()) {
        await outputsDir.create(recursive: true);
      }
      final file = File(p.join(outputsDir.path, p.basename(filename)));
      await file.writeAsString(content);
      _addSystemMessage('Saved to ${file.path}', chat: chat);
    } catch (error) {
      _addSystemMessage('Save failed ($filename): $error', chat: chat);
    }
  }

  void _addSystemMessage(String message, {ChatConversation? chat}) {
    final target = chat ?? _activeChat;
    if (target == null) return;
    target.messages.add(ChatMessage(role: 'system', content: '> $message'));
    target.updatedAt = DateTime.now().toUtc();
    unawaited(_chatRepository.save(target));
    _notifyState();
    if (target.id == _activeChatId) _scrollToEnd(force: true);
  }

  void _setRuntimeState(_ChatRuntime runtime, AppState state) {
    runtime.state = state;
    _notifyState(() {
      if (runtime == _activeRuntime) {
        _gifPath = _settings.getCachedGifPath(state);
      }
    });
  }

  ChatMessage _beginAssistant(
    ChatConversation chat,
    _ChatRuntime runtime,
    AiProvider provider,
  ) {
    final notifier = ValueNotifier<String>('');
    runtime.replyNotifier = notifier;
    final message = ChatMessage(
      role: 'assistant',
      content: '',
      provider: provider,
      notifier: notifier,
    );
    chat.messages.add(message);
    _notifyState();
    return message;
  }

  Future<void> _finishAssistant(
    ChatConversation chat,
    _ChatRuntime runtime,
    ChatMessage message,
    String reply,
    AiProvider provider, {
    String? continuationId,
  }) async {
    message.content = _filterThoughts(reply);
    message.notifier?.dispose();
    message.notifier = null;
    runtime.replyNotifier = null;
    if (runtime.stopRequested) {
      chat.invalidateCheckpoints();
    } else {
      chat.markProviderSuccess(provider, continuationId: continuationId);
    }
    await _chatRepository.save(chat);
    _notifyState();
    await _handleAgentFileOutput(chat, runtime, reply);
  }

  Future<void> _handleAgentFileOutput(
    ChatConversation chat,
    _ChatRuntime runtime,
    String reply,
  ) async {
    if (!runtime.fileOutputMode || runtime.stopRequested) return;
    final matches =
        RegExp(r'\[FILE:\s*(.*?)\s*\]([\s\S]*?)\[\/FILE\]').allMatches(reply);
    if (matches.isEmpty) return;
    _setRuntimeState(runtime, AppState.working);
    for (final match in matches) {
      if (runtime.stopRequested) break;
      await _saveFile(chat, match.group(1)!.trim(), match.group(2)!.trim());
      await Future<void>.delayed(const Duration(milliseconds: 2100));
    }
  }

  String? _providerCompatibilityMessage(ChatConversation chat) {
    if (chat.kind == ChatKind.jules && _settings.provider != AiProvider.jules) {
      return 'Incompatible provider. Switch to Jules to continue this chat.';
    }
    if (chat.kind == ChatKind.standard &&
        _settings.provider == AiProvider.jules) {
      return 'Jules requires a Jules chat. Create a new chat or switch providers.';
    }
    return null;
  }

  Future<void> _sendMessage() async {
    final chat = _activeChat;
    if (chat == null) return;
    final runtime = _runtimeFor(chat);
    final prompt = _inputController.text.trim();
    if (prompt.isEmpty || runtime.isBusy) return;
    final incompatibility = _providerCompatibilityMessage(chat);
    if (incompatibility != null) {
      _addSystemMessage(incompatibility, chat: chat);
      return;
    }

    runtime.stopRequested = false;
    runtime.fileOutputMode = _agentMode;
    if (_settings.provider == AiProvider.jules) {
      await _sendJulesMessage(chat, runtime, prompt);
      return;
    }

    final provider = _settings.provider;
    final mayContinue = chat.canContinue(provider);
    final continuationId = chat.checkpoints[provider]?.continuationId;
    final transcript = chat.canonicalTranscript(nextPrompt: prompt);
    chat.messages.add(ChatMessage(role: 'user', content: prompt));
    if (chat.title == 'New chat') {
      chat.title = ChatConversation.titleFromPrompt(prompt);
    }
    chat.updatedAt = DateTime.now().toUtc();
    _setRuntimeState(runtime, AppState.thinking);
    _inputController.clear();
    _scrollToEnd(force: true);
    await _chatRepository.save(chat);

    switch (provider) {
      case AiProvider.gemini:
        await _sendGeminiInteraction(chat, runtime, provider, prompt,
            transcript, mayContinue ? continuationId : null);
      case AiProvider.openAi:
      case AiProvider.groq:
        await _sendResponsesMessage(chat, runtime, provider, prompt, transcript,
            mayContinue ? continuationId : null);
      case AiProvider.claude:
        await _sendClaudeMessage(chat, runtime, provider, transcript);
      case AiProvider.lmStudio:
      case AiProvider.openRouter:
      case AiProvider.deepSeek:
        await _sendChatCompletions(chat, runtime, provider, transcript);
      case AiProvider.jules:
        break;
    }
  }

  void _markTyping(
    _ChatRuntime runtime,
    Timer? current,
    void Function(Timer timer) saveTimer,
  ) {
    _setRuntimeState(runtime, AppState.replying);
    current?.cancel();
    saveTimer(Timer(const Duration(milliseconds: 1200), () {
      if (runtime.state == AppState.replying) {
        _setRuntimeState(runtime, AppState.thinking);
      }
    }));
  }

  Future<void> _sendChatCompletions(
    ChatConversation chat,
    _ChatRuntime runtime,
    AiProvider provider,
    List<Map<String, String>> transcript,
  ) async {
    final client = http.Client();
    runtime.clients.add(client);
    Timer? typingTimer;
    try {
      final request = http.Request('POST', Uri.parse(_chatUrlFor(provider)));
      request.headers['Content-Type'] = 'application/json';
      final apiKey = _apiKeyFor(provider);
      if (apiKey.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $apiKey';
      }
      if (provider == AiProvider.openRouter) {
        request.headers['HTTP-Referer'] =
            'https://github.com/alfuentes123/AI-Gif-Coder';
        request.headers['X-Title'] = 'AI Gif Coder';
      }
      request.body = jsonEncode({
        'model': _modelFor(provider),
        'messages': [
          if (runtime.fileOutputMode)
            {
              'role': 'system',
              'content': _ChatPageState._agentModeInstruction,
            },
          ...transcript,
        ],
        'stream': true,
      });
      final response = await client.send(request);
      if (response.statusCode != 200) {
        _addSystemMessage(
          'Server error: ${response.statusCode} - ${await response.stream.bytesToString()}',
          chat: chat,
        );
        return;
      }
      final message = _beginAssistant(chat, runtime, provider);
      var reply = '';
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (runtime.stopRequested) break;
        if (!line.startsWith('data: ') || line.trim() == 'data: [DONE]') {
          continue;
        }
        try {
          final choices = jsonDecode(line.substring(6))['choices'] as List;
          final content =
              choices.isEmpty ? null : choices.first['delta']?['content'];
          if (content is String) {
            reply += content;
            message.notifier?.value = _filterThoughts(reply);
            _markTyping(runtime, typingTimer, (timer) => typingTimer = timer);
            if (chat.id == _activeChatId) _scrollToEnd();
          }
        } catch (_) {}
      }
      typingTimer?.cancel();
      await _finishAssistant(chat, runtime, message, reply, provider);
    } catch (error) {
      if (!runtime.stopRequested) {
        _addSystemMessage('Connection error: $error', chat: chat);
      }
    } finally {
      runtime.clients.remove(client);
      client.close();
      _setRuntimeState(runtime, AppState.waiting);
    }
  }

  Future<void> _sendResponsesMessage(
    ChatConversation chat,
    _ChatRuntime runtime,
    AiProvider provider,
    String prompt,
    List<Map<String, String>> transcript,
    String? previousId, {
    bool retried = false,
  }) async {
    final client = http.Client();
    runtime.clients.add(client);
    Timer? typingTimer;
    try {
      final response = await client.send(
        http.Request(
          'POST',
          Uri.parse(provider == AiProvider.openAi
              ? 'https://api.openai.com/v1/responses'
              : 'https://api.groq.com/openai/v1/responses'),
        )
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${_apiKeyFor(provider)}',
          })
          ..body = jsonEncode({
            'model': _modelFor(provider),
            'input': previousId == null ? transcript : prompt,
            'stream': true,
            if (previousId != null) 'previous_response_id': previousId,
            if (runtime.fileOutputMode)
              'instructions': _ChatPageState._agentModeInstruction,
          }),
      );
      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        if (!retried &&
            previousId != null &&
            (response.statusCode == 400 || response.statusCode == 404)) {
          chat.checkpoints.remove(provider);
          await _sendResponsesMessage(
            chat,
            runtime,
            provider,
            prompt,
            transcript,
            null,
            retried: true,
          );
          return;
        }
        _addSystemMessage(
          'Server error: ${response.statusCode} - $errorBody',
          chat: chat,
        );
        return;
      }
      final message = _beginAssistant(chat, runtime, provider);
      var reply = '';
      String? responseId;
      String? eventName;
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (runtime.stopRequested) break;
        if (line.startsWith('event: ')) {
          eventName = line.substring(7).trim();
          continue;
        }
        if (!line.startsWith('data: ') || line.trim() == 'data: [DONE]') {
          continue;
        }
        try {
          final data = jsonDecode(line.substring(6)) as Map<String, dynamic>;
          final type = data['type'] ?? eventName;
          if (type == 'response.created') {
            responseId = data['response']?['id'] as String?;
          } else if (type == 'response.output_text.delta' &&
              data['delta'] is String) {
            reply += data['delta'] as String;
            message.notifier?.value = _filterThoughts(reply);
            _markTyping(runtime, typingTimer, (timer) => typingTimer = timer);
            if (chat.id == _activeChatId) _scrollToEnd();
          } else if (type == 'response.completed') {
            responseId = data['response']?['id'] as String? ?? responseId;
          }
        } catch (_) {}
      }
      typingTimer?.cancel();
      await _finishAssistant(
        chat,
        runtime,
        message,
        reply,
        provider,
        continuationId: responseId,
      );
    } catch (error) {
      if (!runtime.stopRequested) {
        _addSystemMessage('Connection error: $error', chat: chat);
      }
    } finally {
      runtime.clients.remove(client);
      client.close();
      if (!retried || runtime.clients.isEmpty) {
        _setRuntimeState(runtime, AppState.waiting);
      }
    }
  }

  Future<void> _sendClaudeMessage(
    ChatConversation chat,
    _ChatRuntime runtime,
    AiProvider provider,
    List<Map<String, String>> transcript,
  ) async {
    final client = http.Client();
    runtime.clients.add(client);
    Timer? typingTimer;
    try {
      final response = await client.send(
        http.Request('POST', Uri.parse(_chatUrlFor(provider)))
          ..headers.addAll({
            'Content-Type': 'application/json',
            'x-api-key': _settings.claudeApiKey,
            'anthropic-version': '2023-06-01',
          })
          ..body = jsonEncode({
            'model': _modelFor(provider),
            'max_tokens': 4096,
            'messages': transcript,
            'stream': true,
            if (runtime.fileOutputMode)
              'system': _ChatPageState._agentModeInstruction,
          }),
      );
      if (response.statusCode != 200) {
        _addSystemMessage(
          'Server error: ${response.statusCode} - ${await response.stream.bytesToString()}',
          chat: chat,
        );
        return;
      }
      final message = _beginAssistant(chat, runtime, provider);
      var reply = '';
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (runtime.stopRequested) break;
        if (!line.startsWith('data: ')) continue;
        try {
          final data = jsonDecode(line.substring(6));
          if (data['type'] == 'content_block_delta' &&
              data['delta']?['text'] is String) {
            reply += data['delta']['text'] as String;
            message.notifier?.value = _filterThoughts(reply);
            _markTyping(runtime, typingTimer, (timer) => typingTimer = timer);
            if (chat.id == _activeChatId) _scrollToEnd();
          }
        } catch (_) {}
      }
      typingTimer?.cancel();
      await _finishAssistant(chat, runtime, message, reply, provider);
    } catch (error) {
      if (!runtime.stopRequested) {
        _addSystemMessage('Connection error: $error', chat: chat);
      }
    } finally {
      runtime.clients.remove(client);
      client.close();
      _setRuntimeState(runtime, AppState.waiting);
    }
  }

  String _serializedTranscript(List<Map<String, String>> transcript) {
    return transcript.map((message) {
      final role = message['role'] == 'assistant' ? 'ASSISTANT' : 'USER';
      return '[$role]\n${message['content']}';
    }).join('\n\n');
  }

  Future<void> _sendGeminiInteraction(
    ChatConversation chat,
    _ChatRuntime runtime,
    AiProvider provider,
    String prompt,
    List<Map<String, String>> transcript,
    String? previousId, {
    bool retried = false,
  }) async {
    final client = http.Client();
    runtime.clients.add(client);
    Timer? typingTimer;
    try {
      final response = await client.send(
        http.Request(
          'POST',
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/interactions',
          ),
        )
          ..headers.addAll({
            'Content-Type': 'application/json',
            'x-goog-api-key': _settings.geminiApiKey,
            'Api-Revision': '2026-05-20',
          })
          ..body = jsonEncode({
            'model': _modelFor(provider),
            'input':
                previousId == null ? _serializedTranscript(transcript) : prompt,
            'stream': true,
            if (previousId != null) 'previous_interaction_id': previousId,
            if (runtime.fileOutputMode)
              'system_instruction': _ChatPageState._agentModeInstruction,
          }),
      );
      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        if (!retried &&
            previousId != null &&
            (response.statusCode == 400 || response.statusCode == 404)) {
          chat.checkpoints.remove(provider);
          await _sendGeminiInteraction(
            chat,
            runtime,
            provider,
            prompt,
            transcript,
            null,
            retried: true,
          );
          return;
        }
        _addSystemMessage(
          'Server error: ${response.statusCode} - $errorBody',
          chat: chat,
        );
        return;
      }
      final message = _beginAssistant(chat, runtime, provider);
      var reply = '';
      String? interactionId;
      String? eventName;
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (runtime.stopRequested) break;
        if (line.startsWith('event: ')) {
          eventName = line.substring(7).trim();
          continue;
        }
        if (!line.startsWith('data: ') || line.trim() == 'data: [DONE]') {
          continue;
        }
        try {
          final data = jsonDecode(line.substring(6)) as Map<String, dynamic>;
          final type = data['event_type'] ?? data['type'] ?? eventName;
          if (type == 'interaction.created') {
            interactionId = data['interaction']?['id'] as String?;
          } else if (type == 'step.delta' ||
              type == 'response.output_text.delta' ||
              type == 'content.delta' ||
              type == 'message.delta') {
            final text = geminiInteractionTextDelta(data);
            if (text != null) {
              reply += text;
              message.notifier?.value = _filterThoughts(reply);
              _markTyping(runtime, typingTimer, (timer) => typingTimer = timer);
              if (chat.id == _activeChatId) _scrollToEnd();
            }
          } else if (type == 'interaction.completed') {
            interactionId =
                data['interaction']?['id'] as String? ?? interactionId;
          }
        } catch (_) {}
      }
      typingTimer?.cancel();
      await _finishAssistant(
        chat,
        runtime,
        message,
        reply,
        provider,
        continuationId: interactionId,
      );
    } catch (error) {
      if (!runtime.stopRequested) {
        _addSystemMessage('Connection error: $error', chat: chat);
      }
    } finally {
      runtime.clients.remove(client);
      client.close();
      if (!retried || runtime.clients.isEmpty) {
        _setRuntimeState(runtime, AppState.waiting);
      }
    }
  }

  Future<void> _sendJulesMessage(
    ChatConversation chat,
    _ChatRuntime runtime,
    String prompt,
  ) async {
    runtime.stopRequested = false;
    final apiKey = _settings.julesApiKey;
    final repo = _settings.julesRepo;
    final branch = _settings.julesBranch;
    if (apiKey.isEmpty || repo == null || branch == null) {
      _addSystemMessage(
        'Please configure Jules API key, GitHub repository, and branch in Settings first.',
        chat: chat,
      );
      return;
    }

    chat.messages.add(ChatMessage(role: 'user', content: prompt));
    if (chat.title == 'New chat') {
      chat.title = ChatConversation.titleFromPrompt(prompt);
    }
    chat.updatedAt = DateTime.now().toUtc();
    _setRuntimeState(runtime, AppState.thinking);
    _inputController.clear();
    if (chat.id == _activeChatId) _scrollToEnd(force: true);
    await _chatRepository.save(chat);

    final client = http.Client();
    runtime.clients.add(client);
    try {
      var sessionId = chat.julesSessionId;
      if (sessionId == null) {
        sessionId = await _createJulesSession(
          client,
          chat,
          prompt,
          apiKey,
          repo,
          branch,
        );
      } else {
        _addSystemMessage('Sending message to active session...', chat: chat);
        final response = await client.post(
          Uri.parse(
            'https://jules.googleapis.com/v1alpha/$sessionId:sendMessage',
          ),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': apiKey,
          },
          body: jsonEncode({'prompt': prompt}),
        );
        if (response.statusCode != 200) {
          _addSystemMessage(
            'The previous Jules session is no longer active. Creating a new session...',
            chat: chat,
          );
          chat.julesSessionId = null;
          sessionId = await _createJulesSession(
            client,
            chat,
            prompt,
            apiKey,
            repo,
            branch,
          );
        }
      }
      _startJulesPolling(chat, runtime, sessionId, apiKey);
    } catch (error) {
      _addSystemMessage('Jules error: $error', chat: chat);
      _setRuntimeState(runtime, AppState.waiting);
    } finally {
      runtime.clients.remove(client);
      client.close();
    }
  }

  Future<String> _createJulesSession(
    http.Client client,
    ChatConversation chat,
    String prompt,
    String apiKey,
    String repo,
    String branch,
  ) async {
    _addSystemMessage('Creating new Jules session...', chat: chat);
    final response = await client.post(
      Uri.parse('https://jules.googleapis.com/v1alpha/sessions'),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
      },
      body: jsonEncode({
        'prompt': prompt,
        'sourceContext': {
          'source': repo,
          'githubRepoContext': {'startingBranch': branch},
        },
        'automationMode': 'AUTO_CREATE_PR',
        'title': chat.title,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create session: ${response.statusCode} - ${response.body}',
      );
    }
    final sessionId = jsonDecode(response.body)['name'] as String;
    chat.julesSessionId = sessionId;
    chat.processedJulesActivityIds.clear();
    chat.lastUsedProvider = AiProvider.jules;
    await _chatRepository.save(chat);
    _addSystemMessage('Session created: $sessionId', chat: chat);
    return sessionId;
  }

  void _startJulesPolling(
    ChatConversation chat,
    _ChatRuntime runtime,
    String sessionId,
    String apiKey,
  ) {
    if (apiKey.isEmpty) return;
    runtime.julesPollTimer?.cancel();
    unawaited(_pollJulesStatus(chat, runtime, sessionId, apiKey));
    runtime.julesPollTimer =
        Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || runtime.stopRequested) {
        timer.cancel();
        runtime.julesPollTimer = null;
        _setRuntimeState(runtime, AppState.waiting);
        return;
      }
      unawaited(_pollJulesStatus(chat, runtime, sessionId, apiKey));
    });
  }

  Future<void> _pollJulesStatus(
    ChatConversation chat,
    _ChatRuntime runtime,
    String sessionId,
    String apiKey,
  ) async {
    final client = http.Client();
    runtime.clients.add(client);
    try {
      final sessionResponse = await client.get(
        Uri.parse('https://jules.googleapis.com/v1alpha/$sessionId'),
        headers: {'X-Goog-Api-Key': apiKey},
      );
      if (sessionResponse.statusCode != 200) return;
      final sessionData = jsonDecode(sessionResponse.body);
      final sessionState = (sessionData['state'] ?? 'QUEUED') as String;
      final nextState = switch (sessionState) {
        'IN_PROGRESS' => AppState.working,
        'COMPLETED' || 'FAILED' || 'PAUSED' => AppState.waiting,
        'AWAITING_PLAN_APPROVAL' ||
        'AWAITING_USER_FEEDBACK' =>
          AppState.replying,
        _ => AppState.thinking,
      };
      _setRuntimeState(runtime, nextState);

      final activitiesResponse = await client.get(
        Uri.parse(
          'https://jules.googleapis.com/v1alpha/$sessionId/activities',
        ),
        headers: {'X-Goog-Api-Key': apiKey},
      );
      if (activitiesResponse.statusCode == 200) {
        final activities =
            jsonDecode(activitiesResponse.body)['activities'] as List<dynamic>?;
        if (activities != null) {
          activities.sort((a, b) {
            final aTime = DateTime.tryParse(a['createTime'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0);
            final bTime = DateTime.tryParse(b['createTime'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0);
            return aTime.compareTo(bTime);
          });
          for (final activity in activities) {
            final name = activity['name'] as String?;
            if (name == null || !chat.processedJulesActivityIds.add(name)) {
              continue;
            }
            if (activity['agentMessaged'] != null) {
              final text = activity['agentMessaged']['agentMessage'] as String?;
              if (text != null && text.trim().isNotEmpty) {
                chat.messages.add(ChatMessage(
                  role: 'assistant',
                  content: _filterThoughts(text),
                  provider: AiProvider.jules,
                ));
                chat.lastUsedProvider = AiProvider.jules;
              }
            } else if (activity['planGenerated'] != null) {
              final steps =
                  activity['planGenerated']['plan']?['steps'] as List<dynamic>?;
              final planText = StringBuffer('Plan Generated:\n');
              if (steps == null || steps.isEmpty) {
                planText.write('No plan steps detailed.');
              } else {
                for (var index = 0; index < steps.length; index++) {
                  planText.writeln(
                    '- ${steps[index]['description'] ?? 'Step ${index + 1}'}',
                  );
                }
              }
              _addSystemMessage(planText.toString(), chat: chat);
              if (sessionState == 'AWAITING_PLAN_APPROVAL') {
                _addPlanApprovalPrompt(chat);
              }
            } else if (activity['progressUpdated'] != null) {
              final progress = activity['progressUpdated'];
              _addSystemMessage(
                'Progress: ${progress['title'] ?? ''} - ${progress['description'] ?? ''}',
                chat: chat,
              );
            } else if (activity['sessionCompleted'] != null) {
              _addSystemMessage('Jules task completed successfully!',
                  chat: chat);
            } else if (activity['sessionFailed'] != null) {
              _addSystemMessage('Jules task failed.', chat: chat);
            }
          }
          chat.updatedAt = DateTime.now().toUtc();
          await _chatRepository.save(chat);
          _notifyState();
          if (chat.id == _activeChatId) _scrollToEnd();
        }
      }

      if (sessionState == 'COMPLETED' || sessionState == 'FAILED') {
        runtime.julesPollTimer?.cancel();
        runtime.julesPollTimer = null;
        chat.julesSessionId = null;
        await _chatRepository.save(chat);
        _setRuntimeState(runtime, AppState.waiting);
      }
    } catch (error) {
      debugPrint('Error polling Jules: $error');
    } finally {
      runtime.clients.remove(client);
      client.close();
    }
  }

  void _addPlanApprovalPrompt(ChatConversation chat) {
    if (chat.messages.any((message) =>
        message.kind == 'jules_plan_approval' &&
        message.content == 'Jules is waiting for plan approval.')) {
      return;
    }
    chat.messages.add(ChatMessage(
      role: 'system_action',
      content: 'Jules is waiting for plan approval.',
      kind: 'jules_plan_approval',
      actionLabel: 'Approve Plan',
    ));
    unawaited(_chatRepository.save(chat));
    _notifyState();
  }

  Future<void> _approveJulesPlan(ChatConversation chat) async {
    final sessionId = chat.julesSessionId;
    if (sessionId == null) return;
    _addSystemMessage('Approving plan...', chat: chat);
    try {
      final response = await http.post(
        Uri.parse(
          'https://jules.googleapis.com/v1alpha/$sessionId:approvePlan',
        ),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _settings.julesApiKey,
        },
        body: jsonEncode({}),
      );
      if (response.statusCode == 200) {
        chat.messages.removeWhere(
          (message) => message.kind == 'jules_plan_approval',
        );
        _addSystemMessage('Plan approved successfully.', chat: chat);
        await _chatRepository.save(chat);
        await _pollJulesStatus(
          chat,
          _runtimeFor(chat),
          sessionId,
          _settings.julesApiKey,
        );
      } else {
        _addSystemMessage(
          'Failed to approve plan: ${response.statusCode} - ${response.body}',
          chat: chat,
        );
      }
    } catch (error) {
      _addSystemMessage('Error approving plan: $error', chat: chat);
    }
  }
}
