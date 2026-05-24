import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'settings_dialog.dart';
import 'settings_store.dart';
import 'window_setup.dart';

final SettingsStore appSettings = SettingsStore();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settingsReady = appSettings.load();
  runApp(LMStudioApp(store: appSettings, settingsReady: settingsReady));
  if (isDesktopPlatform) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(configureAppWindow());
    });
  }
}

class LMStudioApp extends StatelessWidget {
  const LMStudioApp(
      {super.key, required this.store, required this.settingsReady});

  final SettingsStore store;
  final Future<void> settingsReady;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gif Coder',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0d0d0d),
        colorScheme: const ColorScheme.dark(
          primary: Colors.grey,
          secondary: Colors.grey,
        ),
        useMaterial3: true,
      ),
      home: ChatPage(store: store, settingsReady: settingsReady),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.store, required this.settingsReady});

  final SettingsStore store;
  final Future<void> settingsReady;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  SettingsStore get _settings => widget.store;
  AppState _state = AppState.waiting;
  bool _agentMode = false;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  String? _gifPath;
  ValueNotifier<String>? _currentReplyNotifier;
  bool _stopRequested = false;
  bool _expandedChat = false;

  String? _activeJulesSessionId;
  Timer? _julesPollTimer;
  final Set<String> _processedJulesActivities = {};

  @override
  void initState() {
    super.initState();
    if (_settings.isLoaded) {
      _gifPath = _settings.getCachedGifPath(_state);
    }
    widget.settingsReady.then((_) {
      if (mounted) _refreshGif();
    });
  }

  void _refreshGif() {
    final path = _settings.getCachedGifPath(_state);
    if (path == _gifPath) return;
    setState(() => _gifPath = path);
  }

  @override
  void dispose() {
    _stopRequested = true;
    _julesPollTimer?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _stopResponse() {
    setState(() => _stopRequested = true);
  }

  void _scrollToEnd({bool force = false}) {
    if (!force && _scrollController.hasClients) {
      final position = _scrollController.position;
      if (position.extentAfter > 40.0) {
        return;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _saveFile(String filename, String content) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final outputsDir = Directory(p.join(directory.path, 'Gif_Coder_Outputs'));
      if (!await outputsDir.exists()) {
        await outputsDir.create(recursive: true);
      }
      final safeFilename = p.basename(filename);
      final file = File(p.join(outputsDir.path, safeFilename));
      await file.writeAsString(content);
      final savedPath =
          p.join('Documents', 'Gif_Coder_Outputs', p.basename(file.path));
      _addSystemMessage('Saved to $savedPath');
    } catch (e) {
      _addSystemMessage('Save failed ($filename): $e');
    }
  }

  void _addSystemMessage(String msg) {
    setState(() => _messages.add({'role': 'system', 'content': '> $msg'}));
    _scrollToEnd(force: true);
  }

  Future<void> _sendMessage() async {
    final prompt = _inputController.text.trim();
    if (prompt.isEmpty || _state != AppState.waiting) return;
    _stopRequested = false;

    if (_settings.provider == AiProvider.jules) {
      await _sendJulesMessage(prompt);
      return;
    }

    setState(() {
      _messages.add({'role': 'user', 'content': prompt});
      _state = AppState.thinking;
      _gifPath = _settings.getCachedGifPath(_state);
    });
    _inputController.clear();
    _scrollToEnd(force: true);

    final client = http.Client();
    try {
      final List<Map<String, String>> messages = [
        if (_agentMode)
          {
            'role': 'system',
            'content':
                'Agentic mode: Wrap code in [FILE: name.ext]...[/FILE]. No filler. Never use ``` markdown fences. Never add helper methods for testing, no test cases.',
          },
        {'role': 'user', 'content': prompt},
      ];

      final request =
          http.Request('POST', Uri.parse(_settings.chatCompletionsUrl));
      request.headers['Content-Type'] = 'application/json';
      if (_settings.apiKey.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer ${_settings.apiKey}';
      }
      if (_settings.provider == AiProvider.openRouter) {
        request.headers['HTTP-Referer'] =
            'https://github.com/alfuentes123/AI-Gif-Coder';
        request.headers['X-Title'] = 'AI Gif Coder';
      }
      request.body = jsonEncode({
        'model': _settings.modelName,
        'messages': messages,
        'stream': true,
      });

      final response = await client.send(request);

      if (response.statusCode == 200) {
        _currentReplyNotifier = ValueNotifier<String>('');

        setState(() {
          _messages.add({
            'role': 'assistant',
            'content': '',
            'notifier': _currentReplyNotifier
          });
          _state = AppState.thinking;
          _gifPath = _settings.getCachedGifPath(_state);
        });

        String reply = '';
        Timer? typingTimer;

        void updateTypingState() {
          if (!mounted) return;
          if (_state != AppState.replying) {
            setState(() {
              _state = AppState.replying;
              _gifPath = _settings.getCachedGifPath(_state);
            });
          }
          typingTimer?.cancel();
          typingTimer = Timer(const Duration(milliseconds: 1200), () {
            if (mounted && _state == AppState.replying) {
              setState(() {
                _state = AppState.thinking;
                _gifPath = _settings.getCachedGifPath(_state);
              });
            }
          });
        }

        await for (final line in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (_stopRequested) break;
          if (line.startsWith('data: ') && line.trim() != 'data: [DONE]') {
            final dataStr = line.substring(6);
            try {
              final data = jsonDecode(dataStr);
              final choices = data['choices'] as List;
              if (choices.isNotEmpty) {
                final delta = choices[0]['delta'];
                if (delta != null && delta['content'] != null) {
                  reply += delta['content'];
                  final filtered = _filterThoughts(reply);
                  _currentReplyNotifier?.value = filtered;
                  _scrollToEnd();
                  if (filtered.isNotEmpty) {
                    updateTypingState();
                  }
                }
              }
            } catch (_) {}
          }
        }

        typingTimer?.cancel();

        if (mounted) {
          setState(() {
            _messages.last['content'] = _filterThoughts(reply);
            _messages.last.remove('notifier');
          });
        }
        _currentReplyNotifier?.dispose();
        _currentReplyNotifier = null;

        if (_agentMode && !_stopRequested) {
          final regExp = RegExp(r'\[FILE:\s*(.*?)\s*\]([\s\S]*?)\[\/FILE\]');
          final matches = regExp.allMatches(reply);
          if (matches.isNotEmpty) {
            setState(() {
              _state = AppState.working;
              _gifPath = _settings.getCachedGifPath(_state);
            });
            for (final match in matches) {
              await _saveFile(match.group(1)!.trim(), match.group(2)!.trim());
              await Future.delayed(const Duration(milliseconds: 2100));
            }
          }
        }
      } else {
        final errBody = await response.stream.bytesToString();
        try {
          final errJson = jsonDecode(errBody);
          final errMsg = errJson['error']?['message'] ?? errBody;
          _addSystemMessage('Server error: ${response.statusCode} - $errMsg');
        } catch (_) {
          _addSystemMessage('Server error: ${response.statusCode} - $errBody');
        }
      }
    } catch (e) {
      _addSystemMessage('Connection error: $e');
    } finally {
      client.close();
      if (mounted) {
        setState(() {
          _state = AppState.waiting;
          _gifPath = _settings.getCachedGifPath(_state);
        });
      }
    }
  }

  Future<void> _sendJulesMessage(String prompt) async {
    _stopRequested = false;

    final apiKey = _settings.julesApiKey;
    final repo = _settings.julesRepo;
    final branch = _settings.julesBranch;

    if (apiKey.isEmpty || repo == null || branch == null) {
      _addSystemMessage(
          'Please configure Jules API key, GitHub repository, and branch in Settings first.');
      setState(() {
        _state = AppState.waiting;
        _gifPath = _settings.getCachedGifPath(_state);
      });
      return;
    }

    setState(() {
      _messages.add({'role': 'user', 'content': prompt});
      _state = AppState.thinking;
      _gifPath = _settings.getCachedGifPath(_state);
    });
    _inputController.clear();
    _scrollToEnd(force: true);

    final client = http.Client();
    try {
      String sessionId;
      if (_activeJulesSessionId == null) {
        _addSystemMessage('Creating new Jules session...');
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
              'githubRepoContext': {
                'startingBranch': branch,
              },
            },
            'automationMode': 'AUTO_CREATE_PR',
            'title': 'Gif Coder Task',
          }),
        );

        if (response.statusCode != 200) {
          throw Exception(
              'Failed to create session: ${response.statusCode} - ${response.body}');
        }

        final data = jsonDecode(response.body);
        sessionId = data['name'] as String;
        setState(() {
          _activeJulesSessionId = sessionId;
          _processedJulesActivities.clear();
        });
        _addSystemMessage('Session created: $sessionId');
      } else {
        sessionId = _activeJulesSessionId!;
        _addSystemMessage('Sending message to active session...');

        final response = await client.post(
          Uri.parse(
              'https://jules.googleapis.com/v1alpha/$sessionId:sendMessage'),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': apiKey,
          },
          body: jsonEncode({
            'prompt': prompt,
          }),
        );

        if (response.statusCode != 200) {
          _addSystemMessage(
              'Session might be completed. Creating a new session instead...');
          _activeJulesSessionId = null;
          await _sendJulesMessage(prompt);
          return;
        }
      }

      _startJulesPolling(sessionId, apiKey);
    } catch (e) {
      _addSystemMessage('Jules error: $e');
      setState(() {
        _state = AppState.waiting;
        _gifPath = _settings.getCachedGifPath(_state);
      });
    } finally {
      client.close();
    }
  }

  void _startJulesPolling(String sessionId, String apiKey) {
    _julesPollTimer?.cancel();

    _pollJulesStatus(sessionId, apiKey);

    _julesPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || _stopRequested) {
        timer.cancel();
        if (mounted) {
          setState(() {
            _state = AppState.waiting;
            _gifPath = _settings.getCachedGifPath(_state);
          });
        }
        return;
      }
      _pollJulesStatus(sessionId, apiKey);
    });
  }

  Future<void> _pollJulesStatus(String sessionId, String apiKey) async {
    final client = http.Client();
    try {
      final sessionUrl = 'https://jules.googleapis.com/v1alpha/$sessionId';
      final sessionResponse = await client.get(
        Uri.parse(sessionUrl),
        headers: {'X-Goog-Api-Key': apiKey},
      );

      if (!mounted) return;

      String sessionStateStr = 'QUEUED';
      if (sessionResponse.statusCode == 200) {
        final sessionData = jsonDecode(sessionResponse.body);
        sessionStateStr = (sessionData['state'] ?? 'QUEUED') as String;
      }

      AppState nextState = AppState.thinking;
      if (sessionStateStr == 'IN_PROGRESS') {
        nextState = AppState.working;
      } else if (sessionStateStr == 'COMPLETED' ||
          sessionStateStr == 'FAILED' ||
          sessionStateStr == 'PAUSED') {
        nextState = AppState.waiting;
      } else if (sessionStateStr == 'AWAITING_PLAN_APPROVAL' ||
          sessionStateStr == 'AWAITING_USER_FEEDBACK') {
        nextState = AppState.replying;
      }

      if (_state != nextState) {
        setState(() {
          _state = nextState;
          _gifPath = _settings.getCachedGifPath(_state);
        });
      }

      final activitiesUrl =
          'https://jules.googleapis.com/v1alpha/$sessionId/activities';
      final activitiesResponse = await client.get(
        Uri.parse(activitiesUrl),
        headers: {'X-Goog-Api-Key': apiKey},
      );

      if (!mounted) return;

      if (activitiesResponse.statusCode == 200) {
        final data = jsonDecode(activitiesResponse.body);
        final List<dynamic>? activities = data['activities'];
        if (activities != null && activities.isNotEmpty) {
          final sortedActivities = List.from(activities);
          sortedActivities.sort((a, b) {
            final aTime = a['createTime'] != null
                ? DateTime.parse(a['createTime'] as String)
                : DateTime.fromMillisecondsSinceEpoch(0);
            final bTime = b['createTime'] != null
                ? DateTime.parse(b['createTime'] as String)
                : DateTime.fromMillisecondsSinceEpoch(0);
            return aTime.compareTo(bTime);
          });

          for (final activity in sortedActivities) {
            final actName = activity['name'] as String?;
            if (actName == null ||
                _processedJulesActivities.contains(actName)) {
              continue;
            }
            _processedJulesActivities.add(actName);

            if (activity['agentMessaged'] != null) {
              final agentMsg =
                  activity['agentMessaged']['agentMessage'] as String?;
              if (agentMsg != null && agentMsg.trim().isNotEmpty) {
                setState(() {
                  _messages.add({
                    'role': 'assistant',
                    'content': _filterThoughts(agentMsg),
                  });
                });
                _scrollToEnd();
              }
            } else if (activity['planGenerated'] != null) {
              final plan = activity['planGenerated']['plan'];
              final steps =
                  plan != null ? plan['steps'] as List<dynamic>? : null;
              String planText = 'Plan Generated:\n';
              if (steps != null) {
                for (var i = 0; i < steps.length; i++) {
                  final step = steps[i];
                  final desc = step['description'] ?? 'Step ${i + 1}';
                  planText += '- $desc\n';
                }
              } else {
                planText += 'No plan steps detailed.';
              }

              _addSystemMessage(planText);

              if (sessionStateStr == 'AWAITING_PLAN_APPROVAL') {
                _addPlanApprovalPrompt(sessionId, apiKey);
              }
            } else if (activity['progressUpdated'] != null) {
              final title = activity['progressUpdated']['title'] ?? '';
              final desc = activity['progressUpdated']['description'] ?? '';
              if (title.isNotEmpty || desc.isNotEmpty) {
                _addSystemMessage('Progress: $title - $desc');
              }
            } else if (activity['sessionCompleted'] != null) {
              _addSystemMessage('Jules task completed successfully!');
            } else if (activity['sessionFailed'] != null) {
              _addSystemMessage('Jules task failed.');
            }
          }
        }
      }

      if (sessionStateStr == 'COMPLETED' || sessionStateStr == 'FAILED') {
        _julesPollTimer?.cancel();
        _julesPollTimer = null;
        _activeJulesSessionId = null;
        setState(() {
          _state = AppState.waiting;
          _gifPath = _settings.getCachedGifPath(_state);
        });
      }
    } catch (e) {
      debugPrint('Error polling Jules: $e');
    } finally {
      client.close();
    }
  }

  void _addPlanApprovalPrompt(String sessionId, String apiKey) {
    setState(() {
      _messages.add({
        'role': 'system_action',
        'content': 'Jules is waiting for plan approval.',
        'actionLabel': 'Approve Plan',
        'onAction': () async {
          _addSystemMessage('Approving plan...');
          try {
            final response = await http.post(
              Uri.parse(
                  'https://jules.googleapis.com/v1alpha/$sessionId:approvePlan'),
              headers: {
                'Content-Type': 'application/json',
                'X-Goog-Api-Key': apiKey,
              },
              body: jsonEncode({}),
            );
            if (response.statusCode == 200) {
              _addSystemMessage('Plan approved successfully.');
              _pollJulesStatus(sessionId, apiKey);
            } else {
              _addSystemMessage(
                  'Failed to approve plan: ${response.statusCode} - ${response.body}');
            }
          } catch (e) {
            _addSystemMessage('Error approving plan: $e');
          }
        }
      });
    });
    _scrollToEnd(force: true);
  }

  String _filterThoughts(String text) {
    // Filter fully-closed tags
    String filtered = text.replaceAll(
        RegExp(r'<(think|thought)>[\s\S]*?<\/\1>', caseSensitive: false), '');
    // Strip any unclosed tag and everything following it
    final openIndex =
        filtered.toLowerCase().lastIndexOf(RegExp(r'<(think|thought)'));
    if (openIndex != -1) {
      filtered = filtered.substring(0, openIndex);
    }
    return filtered.trim();
  }

  List<ContentBlock> _parseContent(String text) {
    final List<ContentBlock> blocks = [];
    final List<String> lines = text.split('\n');

    BlockType currentState = BlockType.text;
    String? currentHeading;
    List<String> currentLines = [];

    void commitBlock() {
      if (currentLines.isEmpty && currentState == BlockType.text) return;
      final content = currentLines.join('\n');
      blocks.add(ContentBlock(
        type: currentState,
        content: content,
        heading: currentHeading,
      ));
      currentLines = [];
    }

    for (final line in lines) {
      if (currentState == BlockType.text) {
        if (line.trimLeft().startsWith('```')) {
          commitBlock();
          currentState = BlockType.code;
          final lang = line.trim().substring(3).trim();
          currentHeading = lang.isNotEmpty ? lang : null;
        } else if (line.trim().startsWith('[FILE:') && line.contains(']')) {
          commitBlock();
          currentState = BlockType.file;
          final startIdx = line.indexOf('[FILE:') + 6;
          final endIdx = line.indexOf(']', startIdx);
          if (endIdx != -1) {
            currentHeading = line.substring(startIdx, endIdx).trim();
          } else {
            currentHeading = 'file';
          }
        } else {
          currentLines.add(line);
        }
      } else if (currentState == BlockType.code) {
        if (line.trimLeft().startsWith('```')) {
          commitBlock();
          currentState = BlockType.text;
          currentHeading = null;
        } else {
          currentLines.add(line);
        }
      } else if (currentState == BlockType.file) {
        if (line.trim().contains('[/FILE]')) {
          final idx = line.indexOf('[/FILE]');
          final before = line.substring(0, idx);
          if (before.isNotEmpty) {
            currentLines.add(before);
          }
          commitBlock();
          currentState = BlockType.text;
          currentHeading = null;
          final after = line.substring(idx + 7);
          if (after.isNotEmpty) {
            currentLines.add(after);
          }
        } else {
          currentLines.add(line);
        }
      }
    }

    commitBlock();
    return blocks;
  }

  Widget _buildMessageContent(String content, bool isSystem) {
    final blocks = _parseContent(content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks.map((block) {
        if (block.type == BlockType.text) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              block.content,
              style: TextStyle(
                color: isSystem ? Colors.white54 : Colors.white.withValues(alpha: 0.95),
                fontSize: isSystem ? 10 : 12,
                height: 1.3,
                fontStyle: isSystem ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          );
        } else {
          final isFile = block.type == BlockType.file;
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1E36), // Deep rich blue
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.blueAccent.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (block.heading != null && block.heading!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      isFile ? 'FILE: ${block.heading}' : block.heading!.toUpperCase(),
                      style: TextStyle(
                        color: Colors.blueAccent.shade100,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                Text(
                  block.content,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white.withValues(alpha: 0.95),
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          );
        }
      }).toList(),
    );
  }

  Future<void> _openSettings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => SettingsDialog(store: _settings),
    );
    if (saved == true && mounted) {
      setState(() {});
      _refreshGif();
    }
  }

  /// Clears the settings button and a gap above the GIF frame.
  static const double _topSettingsReserve = 35;

  /// Clears the message list, prompt bar, and a gap below the GIF frame.
  static const double _bottomPromptReserve = 50;

  Widget _buildBackgroundGif(BuildContext context) {
    final filePath = _gifPath;
    final topPadding = MediaQuery.paddingOf(context).top + _topSettingsReserve;
    final bottomPadding =
        MediaQuery.paddingOf(context).bottom + _bottomPromptReserve;
    Widget image;
    if (filePath != null) {
      image = Image.file(
        File(filePath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
      );
    } else {
      image = Image.asset(
        'assets/gifs/${_state.defaultFileName}',
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, bottomPadding),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              if (_settings.provider == AiProvider.jules)
                Positioned(
                  top: 12,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.purpleAccent.withValues(alpha: 0.5),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.purple.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Text(
                      'JULES',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isJules = _settings.provider == AiProvider.jules;
    final displayAgentMode = !isJules && _agentMode;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _buildBackgroundGif(context)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 160,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                    Colors.black.withValues(alpha: 0.92),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message:
                        isJules ? 'Code file output is disabled for Jules' : '',
                    child: GestureDetector(
                      onTap: isJules
                          ? null
                          : () => setState(() => _agentMode = !_agentMode),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayAgentMode ? 'CODE FILE OUTPUT' : 'CHAT',
                            style: TextStyle(
                              fontSize: 12,
                              color: isJules
                                  ? Colors.white.withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.7),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 8),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeInOut,
                            width: 38,
                            height: 20,
                            margin: const EdgeInsets.only(right: 2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: isJules
                                  ? const Color.fromARGB(20, 83, 83, 83)
                                  : (displayAgentMode
                                      ? const Color.fromARGB(255, 175, 175, 175)
                                      : const Color.fromARGB(58, 83, 83, 83)),
                            ),
                            child: AnimatedAlign(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeInOut,
                              alignment: displayAgentMode
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                width: 16,
                                height: 16,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isJules
                                      ? Colors.white.withValues(alpha: 0.3)
                                      : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    tooltip: 'Settings',
                    onPressed: _openSettings,
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_messages.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: InkWell(
                            onTap: () =>
                                setState(() => _expandedChat = !_expandedChat),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  width: 0.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _expandedChat
                                        ? Icons.unfold_less_rounded
                                        : Icons.unfold_more_rounded,
                                    size: 12,
                                    color: Colors.white.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _expandedChat ? 'COLLAPSE' : 'EXPAND',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.5,
                                      color:
                                          Colors.white.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      constraints: BoxConstraints(
                        maxHeight:
                            _messages.isEmpty ? 0 : (_expandedChat ? 600 : 88),
                      ),
                      child: _messages.isEmpty
                          ? const SizedBox.shrink()
                          : ListView.builder(
                              controller: _scrollController,
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: _messages.length,
                              itemBuilder: (context, index) {
                                final msg = _messages[index];
                                final isSystem = msg['role'] == 'system';
                                final isSystemAction =
                                    msg['role'] == 'system_action';
                                final notifier =
                                    msg['notifier'] as ValueNotifier<String>?;

                                Widget textWidget;
                                if (isSystemAction) {
                                  final actionLabel =
                                      msg['actionLabel'] as String;
                                  final onAction =
                                      msg['onAction'] as VoidCallback?;
                                  textWidget = Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        msg['content'] as String,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                          height: 1.3,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      ElevatedButton(
                                        onPressed: onAction == null
                                            ? null
                                            : () {
                                                setState(() {
                                                  msg['onAction'] =
                                                      null; // disable
                                                });
                                                onAction();
                                              },
                                        style: ElevatedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 6),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: Text(actionLabel,
                                            style:
                                                const TextStyle(fontSize: 11)),
                                      ),
                                    ],
                                  );
                                } else if (notifier != null) {
                                  textWidget = ValueListenableBuilder<String>(
                                    valueListenable: notifier,
                                    builder: (context, content, _) =>
                                        _buildMessageContent(content, isSystem),
                                  );
                                } else {
                                  textWidget = _buildMessageContent(
                                      msg['content'] as String, isSystem);
                                }

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.black
                                            .withValues(alpha: 0.65),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: textWidget,
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 6),
                    Material(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _inputController,
                              enabled: _state == AppState.waiting,
                              style: const TextStyle(fontSize: 13),
                              onSubmitted: (_) => _sendMessage(),
                              decoration: InputDecoration(
                                hintText: _state == AppState.waiting
                                    ? 'Prompt…'
                                    : _state.label,
                                hintStyle: const TextStyle(fontSize: 13),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                          if (_state != AppState.waiting)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.stop_circle_outlined,
                                  size: 20),
                              tooltip: 'Stop',
                              color: Colors.redAccent,
                              onPressed: _stopRequested ? null : _stopResponse,
                            )
                          else
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.send_rounded, size: 20),
                              onPressed: _sendMessage,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum BlockType {
  text,
  code,
  file,
}

class ContentBlock {
  final BlockType type;
  final String content;
  final String? heading;

  ContentBlock({
    required this.type,
    required this.content,
    this.heading,
  });
}

