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

class ChatSession {
  ChatSession({required this.title});

  String title;
  final List<Map<String, dynamic>> messages = [];
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
  final List<ChatSession> _chats = [];
  int _activeChatIndex = 0;
  int _nextChatNumber = 1;
  String? _gifPath;
  ValueNotifier<String>? _currentReplyNotifier;
  bool _stopRequested = false;
  bool _expandedChat = false;
  bool _showChatTabs = false;

  List<Map<String, dynamic>> get _messages =>
      _chats[_activeChatIndex].messages;
  ChatSession get _activeChat => _chats[_activeChatIndex];
  bool get _canSwitchChat => _state == AppState.waiting;

  @override
  void initState() {
    super.initState();
    _chats.add(ChatSession(title: _newChatTitle()));
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

  String _newChatTitle() => 'Chat ${_nextChatNumber++}';

  void _startNewChat() {
    if (!_canSwitchChat) return;
    setState(() {
      _chats.add(ChatSession(title: _newChatTitle()));
      _activeChatIndex = _chats.length - 1;
      _expandedChat = false;
    });
    _scrollToEnd();
  }

  void _selectChat(int index) {
    if (!_canSwitchChat || index == _activeChatIndex) return;
    setState(() {
      _activeChatIndex = index;
      if (_messages.isEmpty) {
        _expandedChat = false;
      }
    });
    _scrollToEnd();
  }

  void _updateChatTitle(String prompt) {
    final userCount =
        _messages.where((msg) => msg['role'] == 'user').length;
    if (userCount > 1) return;
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;
    final firstLine = trimmed.split('\n').first.trim();
    if (firstLine.isEmpty) return;
    final maxLength = 28;
    _activeChat.title = firstLine.length > maxLength
        ? '${firstLine.substring(0, maxLength)}…'
        : firstLine;
  }

  List<Map<String, String>> _buildContextMessages() {
    final history = _messages
        .where((msg) =>
            msg['role'] == 'user' || msg['role'] == 'assistant')
        .map((msg) => {
              'role': msg['role'] as String,
              'content': msg['content'] as String,
            })
        .toList();
    if (!_agentMode) return history;
    return [
      {
        'role': 'system',
        'content':
            'Agentic mode: Wrap code in [FILE: name.ext]...[/FILE]. No filler. Never use ``` markdown fences. Never add helper methods for testing, no test cases.',
      },
      ...history,
    ];
  }

  @override
  void dispose() {
    _stopRequested = true;
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _stopResponse() {
    setState(() => _stopRequested = true);
  }

  void _scrollToEnd() {
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
    _scrollToEnd();
  }

  Future<void> _sendMessage() async {
    final prompt = _inputController.text.trim();
    if (prompt.isEmpty || _state != AppState.waiting) return;
    _stopRequested = false;

    setState(() {
      _messages.add({'role': 'user', 'content': prompt});
      _state = AppState.thinking;
      _gifPath = _settings.getCachedGifPath(_state);
      _updateChatTitle(prompt);
    });
    _inputController.clear();
    _scrollToEnd();

    final client = http.Client();
    try {
      final List<Map<String, String>> messages = _buildContextMessages();

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

  Future<void> _openSettings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => SettingsDialog(store: _settings),
    );
    if (saved == true && mounted) {
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
          child: image,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _buildBackgroundGif(context)),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () =>
                          setState(() => _showChatTabs = !_showChatTabs),
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
                              _showChatTabs
                                  ? Icons.keyboard_arrow_left_rounded
                                  : Icons.chat_bubble_outline_rounded,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _showChatTabs ? 'HIDE CHATS' : 'SHOW CHATS',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: !_showChatTabs
                          ? const SizedBox.shrink()
                          : Container(
                              width: 200,
                              constraints:
                                  const BoxConstraints(maxHeight: 320),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  width: 0.5,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 6),
                                    child: Row(
                                      children: [
                                        Text(
                                          'CHATS',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 0.6,
                                            color: Colors.white
                                                .withValues(alpha: 0.7),
                                          ),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          visualDensity:
                                              VisualDensity.compact,
                                          icon: const Icon(
                                              Icons.add_circle_outline,
                                              size: 18),
                                          tooltip: 'New chat',
                                          onPressed:
                                              _canSwitchChat ? _startNewChat : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Divider(height: 1),
                                  Flexible(
                                    child: ListView.builder(
                                      shrinkWrap: true,
                                      itemCount: _chats.length,
                                      itemBuilder: (context, index) {
                                        final chat = _chats[index];
                                        final isActive =
                                            index == _activeChatIndex;
                                        final canTap = _canSwitchChat;
                                        return InkWell(
                                          onTap: canTap
                                              ? () => _selectChat(index)
                                              : null,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: isActive
                                                  ? Colors.white
                                                      .withValues(alpha: 0.1)
                                                  : Colors.transparent,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  isActive
                                                      ? Icons
                                                          .chat_bubble_rounded
                                                      : Icons
                                                          .chat_bubble_outline_rounded,
                                                  size: 14,
                                                  color: Colors.white
                                                      .withValues(alpha: 0.7),
                                                ),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                  child: Text(
                                                    chat.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: canTap
                                                                  ? 0.85
                                                                  : 0.5),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
                  GestureDetector(
                    onTap: () => setState(() => _agentMode = !_agentMode),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _agentMode ? 'CODE FILE OUTPUT' : 'CHAT',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.7),
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
                            color: _agentMode
                                ? const Color.fromARGB(255, 175, 175, 175)
                                : const Color.fromARGB(58, 83, 83, 83),
                          ),
                          child: AnimatedAlign(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeInOut,
                            alignment: _agentMode
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              width: 16,
                              height: 16,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
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
                                final notifier =
                                    msg['notifier'] as ValueNotifier<String>?;

                                Widget textWidget;
                                if (notifier != null) {
                                  textWidget = ValueListenableBuilder<String>(
                                    valueListenable: notifier,
                                    builder: (context, content, _) => Text(
                                      content,
                                      style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.95),
                                        fontSize: 12,
                                        height: 1.3,
                                      ),
                                    ),
                                  );
                                } else {
                                  textWidget = Text(
                                    msg['content'] as String,
                                    style: TextStyle(
                                      color: isSystem
                                          ? Colors.white54
                                          : Colors.white
                                              .withValues(alpha: 0.95),
                                      fontSize: isSystem ? 10 : 12,
                                      height: 1.3,
                                      fontStyle: isSystem
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                    ),
                                  );
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
