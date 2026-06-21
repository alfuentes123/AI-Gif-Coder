import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chat_store.dart';
import 'settings_dialog.dart';
import 'settings_store.dart';
import 'window_setup.dart';

part 'chat_requests.dart';

final SettingsStore appSettings = SettingsStore();

List<Map<String, String>> buildChatTranscript(
  List<Map<String, dynamic>> messages, {
  String? nextUserPrompt,
}) {
  final transcript = <Map<String, String>>[];
  for (final message in messages) {
    final role = message['role'];
    if (role != 'user' && role != 'assistant') continue;
    if (message.containsKey('notifier')) continue;

    final content = message['content'];
    if (content is! String || content.trim().isEmpty) continue;

    transcript.add({
      'role': role as String,
      'content': content,
    });
  }
  if (nextUserPrompt != null && nextUserPrompt.trim().isNotEmpty) {
    transcript.add({'role': 'user', 'content': nextUserPrompt});
  }
  return transcript;
}

String? geminiInteractionTextDelta(Map<String, dynamic> data) {
  String? textFrom(dynamic value) {
    if (value is String) return value;
    if (value is Map) {
      final text = value['text'] ?? value['content'] ?? value['delta'];
      if (text is String) return text;

      final parts = value['parts'];
      if (parts is List) {
        return parts
            .whereType<Map>()
            .map((part) => part['text'])
            .whereType<String>()
            .join();
      }
    }
    return null;
  }

  final delta = data['delta'];
  final deltaText = textFrom(delta);
  if (deltaText != null) return deltaText;

  final directText = textFrom(data);
  if (directText != null) return directText;

  final candidates = data['candidates'];
  if (candidates is List && candidates.isNotEmpty) {
    final first = candidates.first;
    if (first is Map) {
      return textFrom(first['content']);
    }
  }

  return null;
}

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
      {super.key,
      required this.store,
      required this.settingsReady,
      this.chatRepository});

  final SettingsStore store;
  final Future<void> settingsReady;
  final ChatRepository? chatRepository;

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
      home: ChatPage(
        store: store,
        settingsReady: settingsReady,
        chatRepository: chatRepository,
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.store,
    required this.settingsReady,
    this.chatRepository,
  });

  final SettingsStore store;
  final Future<void> settingsReady;
  final ChatRepository? chatRepository;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatRuntime {
  AppState state = AppState.waiting;
  bool stopRequested = false;
  bool fileOutputMode = false;
  ValueNotifier<String>? replyNotifier;
  Timer? julesPollTimer;
  final Set<http.Client> clients = {};

  bool get isBusy => state != AppState.waiting;

  void requestStop() {
    stopRequested = true;
    if (julesPollTimer != null) {
      julesPollTimer?.cancel();
      julesPollTimer = null;
      state = AppState.waiting;
    }
  }

  void cancel() {
    stopRequested = true;
    julesPollTimer?.cancel();
    julesPollTimer = null;
    for (final client in clients.toList()) {
      client.close();
    }
    clients.clear();
    state = AppState.waiting;
  }
}

class _ChatPageState extends State<ChatPage> {
  SettingsStore get _settings => widget.store;
  bool _agentMode = false;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final ChatRepository _chatRepository;
  final List<ChatConversation> _chats = [];
  final Map<String, _ChatRuntime> _chatRuntimes = {};
  String? _activeChatId;
  bool _chatsLoaded = false;
  String? _gifPath;
  bool _expandedChat = false;

  static const String _agentModeInstruction =
      'Agentic mode: Wrap code in [FILE: name.ext]...[/FILE]. No filler. Never use ``` markdown fences. Never add helper methods for testing, no test cases.';

  @override
  void initState() {
    super.initState();
    _chatRepository = widget.chatRepository ?? ChatRepository();
    widget.settingsReady.then((_) => _loadChats());
  }

  ChatConversation? get _activeChat {
    final id = _activeChatId;
    if (id == null) return null;
    for (final chat in _chats) {
      if (chat.id == id) return chat;
    }
    return null;
  }

  _ChatRuntime? get _activeRuntime {
    final chat = _activeChat;
    return chat == null ? null : _runtimeFor(chat);
  }

  AppState get _state => _activeRuntime?.state ?? AppState.waiting;
  List<ChatMessage> get _messages => _activeChat?.messages ?? const [];

  _ChatRuntime _runtimeFor(ChatConversation chat) =>
      _chatRuntimes.putIfAbsent(chat.id, _ChatRuntime.new);

  void _notifyState([VoidCallback? mutation]) {
    if (!mounted) return;
    setState(mutation ?? () {});
  }

  Future<void> _loadChats() async {
    final loaded = await _chatRepository.loadAll();
    if (!mounted) return;
    if (loaded.isEmpty) {
      loaded.add(ChatConversation.create(_settings.provider));
      await _chatRepository.save(loaded.first);
    }
    setState(() {
      _chats
        ..clear()
        ..addAll(loaded);
      _activeChatId = _chats.first.id;
      _chatsLoaded = true;
    });
    _refreshGif();
    for (final chat in _chats) {
      if (chat.kind == ChatKind.jules && chat.julesSessionId != null) {
        _startJulesPolling(chat, _runtimeFor(chat), chat.julesSessionId!,
            _settings.julesApiKey);
      }
    }
  }

  void _refreshGif() {
    final path = _settings.getCachedGifPath(_state);
    if (path == _gifPath) return;
    setState(() => _gifPath = path);
  }

  @override
  void dispose() {
    for (final runtime in _chatRuntimes.values) {
      runtime.cancel();
    }
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _stopResponse() {
    final runtime = _activeRuntime;
    if (runtime == null) return;
    setState(runtime.requestStop);
    _refreshGif();
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
            child: SelectableText(
              block.content,
              style: TextStyle(
                color: isSystem
                    ? Colors.white54
                    : Colors.white.withValues(alpha: 0.95),
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
                    child: SelectableText(
                      isFile
                          ? 'FILE: ${block.heading}'
                          : block.heading!.toUpperCase(),
                      style: TextStyle(
                        color: Colors.blueAccent.shade100,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                SelectableText(
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

  Future<void> _newChat() async {
    if (_activeChat?.canonicalMessageCount == 0) {
      if (mounted && (_scaffoldKey.currentState?.isDrawerOpen ?? false)) {
        Navigator.of(context).pop();
      }
      return;
    }
    final chat = ChatConversation.create(_settings.provider);
    setState(() {
      _chats.insert(0, chat);
      _activeChatId = chat.id;
      _inputController.clear();
      _gifPath = _settings.getCachedGifPath(AppState.waiting);
    });
    await _chatRepository.save(chat);
    if (mounted && (_scaffoldKey.currentState?.isDrawerOpen ?? false)) {
      Navigator.of(context).pop();
    }
  }

  void _selectChat(ChatConversation chat) {
    setState(() {
      _activeChatId = chat.id;
      _inputController.clear();
      _gifPath = _settings.getCachedGifPath(_runtimeFor(chat).state);
    });
    Navigator.of(context).pop();
    _scrollToEnd(force: true);
  }

  Future<void> _renameChat(ChatConversation chat) async {
    var draftTitle = chat.title;
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextFormField(
          initialValue: chat.title,
          autofocus: true,
          maxLength: 80,
          onChanged: (value) => draftTitle = value,
          onFieldSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draftTitle),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    setState(() {
      chat.title = title.trim();
      chat.updatedAt = DateTime.now().toUtc();
    });
    await _chatRepository.save(chat);
  }

  Future<void> _deleteChat(ChatConversation chat) async {
    final runtime = _runtimeFor(chat);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(runtime.isBusy
            ? 'This chat is still working. Deleting it will stop the active request.'
            : 'This permanently removes “${chat.title}” from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    runtime.cancel();
    _chatRuntimes.remove(chat.id);
    _chats.remove(chat);
    await _chatRepository.delete(chat.id);
    if (_chats.isEmpty) {
      final replacement = ChatConversation.create(_settings.provider);
      _chats.add(replacement);
      await _chatRepository.save(replacement);
    }
    if (_activeChatId == chat.id) _activeChatId = _chats.first.id;
    if (mounted) {
      setState(() {
        _gifPath = _settings.getCachedGifPath(_state);
      });
    }
  }

  Widget _buildChatDrawer() {
    final sorted = [..._chats]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return Drawer(
      width: 280,
      backgroundColor: const Color(0xFF151515),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _newChat,
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('New chat'),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: sorted.length,
                itemBuilder: (context, index) {
                  final chat = sorted[index];
                  final runtime = _runtimeFor(chat);
                  final selected = chat.id == _activeChatId;
                  return ListTile(
                    selected: selected,
                    selectedTileColor: Colors.white.withValues(alpha: 0.08),
                    leading: runtime.isBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chat_bubble_outline, size: 18),
                    title: Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      chat.lastUsedProvider.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    onTap: () => _selectChat(chat),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Chat actions',
                      onSelected: (action) {
                        if (action == 'rename') {
                          _renameChat(chat);
                        } else if (action == 'delete') {
                          _deleteChat(chat);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF210C44),
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
                      'JULES BY GOOGLE',
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
    final incompatibility = _activeChat == null
        ? null
        : _providerCompatibilityMessage(_activeChat!);
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildChatDrawer(),
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
              alignment: Alignment.topLeft,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.menu_rounded, size: 22),
                tooltip: 'Chats',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
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
                                final isSystem = msg.role == 'system';
                                final isSystemAction =
                                    msg.role == 'system_action';
                                final notifier = msg.notifier;

                                Widget textWidget;
                                if (isSystemAction) {
                                  textWidget = Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SelectableText(
                                        msg.content,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                          height: 1.3,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      ElevatedButton(
                                        onPressed:
                                            msg.kind == 'jules_plan_approval'
                                                ? () => _approveJulesPlan(
                                                      _activeChat!,
                                                    )
                                                : null,
                                        style: ElevatedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 6),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: Text(msg.actionLabel ?? 'Action',
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
                                      msg.content, isSystem);
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
                    if (incompatibility != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          incompatibility,
                          style: const TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    Material(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _inputController,
                              enabled: _chatsLoaded &&
                                  _state == AppState.waiting &&
                                  incompatibility == null,
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
                              onPressed: _activeRuntime?.stopRequested == true
                                  ? null
                                  : _stopResponse,
                            )
                          else
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.send_rounded, size: 20),
                              onPressed:
                                  incompatibility == null ? _sendMessage : null,
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
