import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'settings_store.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.store});

  final SettingsStore store;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;

  late AiProvider _selectedProvider;
  late String _lmStudioUrl;
  late String _lmStudioApiKey;
  late String _lmStudioModel;
  late String _geminiApiKey;
  late String _geminiModel;
  late String _openRouterApiKey;
  late String _openRouterModel;
  late String _julesApiKey;
  late String _claudeApiKey;
  late String _claudeModel;
  late String _groqApiKey;
  late String _groqModel;
  late String _openAiApiKey;
  late String _openAiModel;
  late String _deepSeekApiKey;
  late String _deepSeekModel;
  String? _outputFolderPath;
  String? _julesRepo;
  String? _julesBranch;

  List<Map<String, dynamic>> _julesSources = [];
  List<String> _julesBranches = [];
  bool _fetchingSources = false;
  String? _sourcesError;

  List<String> _availableGifs = [];
  String? _connectionStatus;
  bool _testingConnection = false;

  SettingsStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _selectedProvider = _store.provider;
    _lmStudioUrl = _store.lmStudioUrl;
    _lmStudioApiKey = _store.lmStudioApiKey;
    _lmStudioModel = _store.lmStudioModel;
    _geminiApiKey = _store.geminiApiKey;
    _geminiModel = _store.geminiModel;
    _openRouterApiKey = _store.openRouterApiKey;
    _openRouterModel = _store.openRouterModel;
    _julesApiKey = _store.julesApiKey;
    _claudeApiKey = _store.claudeApiKey;
    _claudeModel = _store.claudeModel;
    _groqApiKey = _store.groqApiKey;
    _groqModel = _store.groqModel;
    _openAiApiKey = _store.openAiApiKey;
    _openAiModel = _store.openAiModel;
    _deepSeekApiKey = _store.deepSeekApiKey;
    _deepSeekModel = _store.deepSeekModel;
    _outputFolderPath = _store.outputFolderPath;
    _julesRepo = _store.julesRepo;
    _julesBranch = _store.julesBranch;

    _urlController = TextEditingController(text: _lmStudioUrl);
    _apiKeyController =
        TextEditingController(text: _getApiKeyForProvider(_selectedProvider));
    _modelController =
        TextEditingController(text: _getModelForProvider(_selectedProvider));

    _refreshGifList();
    if (_selectedProvider == AiProvider.jules &&
        _apiKeyController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchJulesSources();
      });
    }
  }

  String _getApiKeyForProvider(AiProvider provider) {
    return switch (provider) {
      AiProvider.lmStudio => _lmStudioApiKey,
      AiProvider.gemini => _geminiApiKey,
      AiProvider.openRouter => _openRouterApiKey,
      AiProvider.jules => _julesApiKey,
      AiProvider.claude => _claudeApiKey,
      AiProvider.groq => _groqApiKey,
      AiProvider.openAi => _openAiApiKey,
      AiProvider.deepSeek => _deepSeekApiKey,
    };
  }

  String _getModelForProvider(AiProvider provider) {
    return switch (provider) {
      AiProvider.lmStudio => _lmStudioModel,
      AiProvider.gemini => _geminiModel,
      AiProvider.openRouter => _openRouterModel,
      AiProvider.jules => 'jules-coding-agent',
      AiProvider.claude => _claudeModel,
      AiProvider.groq => _groqModel,
      AiProvider.openAi => _openAiModel,
      AiProvider.deepSeek => _deepSeekModel,
    };
  }

  void _saveCurrentFields() {
    switch (_selectedProvider) {
      case AiProvider.lmStudio:
        _lmStudioUrl = _urlController.text.trim();
        _lmStudioApiKey = _apiKeyController.text.trim();
        _lmStudioModel = _modelController.text.trim();
        break;
      case AiProvider.gemini:
        _geminiApiKey = _apiKeyController.text.trim();
        _geminiModel = _modelController.text.trim();
        break;
      case AiProvider.openRouter:
        _openRouterApiKey = _apiKeyController.text.trim();
        _openRouterModel = _modelController.text.trim();
        break;
      case AiProvider.jules:
        _julesApiKey = _apiKeyController.text.trim();
        break;
      case AiProvider.claude:
        _claudeApiKey = _apiKeyController.text.trim();
        _claudeModel = _modelController.text.trim();
        break;
      case AiProvider.groq:
        _groqApiKey = _apiKeyController.text.trim();
        _groqModel = _modelController.text.trim();
        break;
      case AiProvider.openAi:
        _openAiApiKey = _apiKeyController.text.trim();
        _openAiModel = _modelController.text.trim();
        break;
      case AiProvider.deepSeek:
        _deepSeekApiKey = _apiKeyController.text.trim();
        _deepSeekModel = _modelController.text.trim();
        break;
    }
  }

  void _loadFieldsForProvider(AiProvider provider) {
    _selectedProvider = provider;
    switch (provider) {
      case AiProvider.lmStudio:
        _urlController.text = _lmStudioUrl;
        _apiKeyController.text = _lmStudioApiKey;
        _modelController.text = _lmStudioModel;
        break;
      case AiProvider.gemini:
        _apiKeyController.text = _geminiApiKey;
        _modelController.text = _geminiModel;
        break;
      case AiProvider.openRouter:
        _apiKeyController.text = _openRouterApiKey;
        _modelController.text = _openRouterModel;
        break;
      case AiProvider.jules:
        _apiKeyController.text = _julesApiKey;
        break;
      case AiProvider.claude:
        _apiKeyController.text = _claudeApiKey;
        _modelController.text = _claudeModel;
        break;
      case AiProvider.groq:
        _apiKeyController.text = _groqApiKey;
        _modelController.text = _groqModel;
        break;
      case AiProvider.openAi:
        _apiKeyController.text = _openAiApiKey;
        _modelController.text = _openAiModel;
        break;
      case AiProvider.deepSeek:
        _apiKeyController.text = _deepSeekApiKey;
        _modelController.text = _deepSeekModel;
        break;
    }
    _connectionStatus = null;
  }

  Future<void> _fetchJulesSources() async {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) {
      setState(() {
        _sourcesError = 'Please enter an API Key first';
        _julesSources = [];
      });
      return;
    }
    setState(() {
      _fetchingSources = true;
      _sourcesError = null;
    });
    try {
      final response = await http.get(
        Uri.parse('https://jules.googleapis.com/v1alpha/sources'),
        headers: {
          'X-Goog-Api-Key': key,
        },
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic>? sourcesJson = data['sources'];
        if (sourcesJson != null) {
          setState(() {
            _julesSources = sourcesJson.cast<Map<String, dynamic>>();
            _sourcesError = null;

            if (_julesRepo != null &&
                !_julesSources.any((s) => s['name'] == _julesRepo)) {
              _julesRepo = null;
              _julesBranch = null;
            }
            if (_julesRepo == null && _julesSources.isNotEmpty) {
              _julesRepo = _julesSources.first['name'] as String?;
            }
            _updateJulesBranches();
          });
        } else {
          setState(() {
            _julesSources = [];
            _sourcesError = 'No connected sources found in Jules.';
          });
        }
      } else {
        setState(() {
          _sourcesError = 'Failed to fetch sources: ${response.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sourcesError = 'Error fetching sources: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _fetchingSources = false);
      }
    }
  }

  void _updateJulesBranches() {
    if (_julesRepo == null) {
      _julesBranches = [];
      _julesBranch = null;
      return;
    }
    final selectedSource = _julesSources.firstWhere(
      (s) => s['name'] == _julesRepo,
      orElse: () => {},
    );
    final githubRepo = selectedSource['githubRepo'] as Map<String, dynamic>?;
    final branchesJson = githubRepo?['branches'] as List<dynamic>?;
    if (branchesJson != null) {
      _julesBranches = branchesJson
          .map((b) => (b['displayName'] ?? b['name'] ?? '') as String)
          .where((name) => name.isNotEmpty)
          .toList();
      if (_julesBranch != null && !_julesBranches.contains(_julesBranch)) {
        _julesBranch = null;
      }
      if (_julesBranch == null && _julesBranches.isNotEmpty) {
        _julesBranch = _julesBranches.first;
      }
    } else {
      _julesBranches = [];
      _julesBranch = null;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _refreshGifList() async {
    final gifs = await _store.listGifsInFolder();
    if (mounted) setState(() => _availableGifs = gifs);
  }

  Future<void> _pickGifFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select folder containing GIF files',
    );
    if (path == null) return;

    _store.gifFolderPath = path;
    _store.invalidateGifCache();
    _availableGifs = await _store.listGifsInFolder();

    for (final state in AppState.values) {
      final preferred = state.defaultFileName;
      final exact = _availableGifs
          .where((f) => f.toLowerCase() == preferred.toLowerCase())
          .toList();
      if (exact.isNotEmpty) {
        _store.gifFiles[state] = exact.first;
      } else if (_availableGifs.isNotEmpty) {
        _store.gifFiles[state] = _availableGifs.first;
      }
    }
    setState(() {});
  }

  void _restoreDefaultGifs() {
    setState(() {
      _store.gifFolderPath = null;
      for (final state in AppState.values) {
        _store.gifFiles[state] = state.defaultFileName;
      }
      _store.invalidateGifCache();
      _availableGifs = [];
    });
  }

  Future<void> _pickOutputFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select folder for generated code files',
    );
    if (path == null || !mounted) return;
    setState(() => _outputFolderPath = path);
  }

  void _restoreDefaultOutputFolder() {
    setState(() => _outputFolderPath = null);
  }

  Future<void> _testConnection() async {
    setState(() {
      _testingConnection = true;
      _connectionStatus = null;
    });
    _saveCurrentFields();

    try {
      final modelName = _modelController.text.trim();
      if (modelName.isEmpty) {
        setState(() {
          _connectionStatus = 'Model name is required';
          _testingConnection = false;
        });
        return;
      }

      String testUrl;
      final Map<String, String> headers = {
        'Content-Type': 'application/json',
      };

      switch (_selectedProvider) {
        case AiProvider.lmStudio:
          final base =
              _urlController.text.trim().replaceAll(RegExp(r'/+$'), '');
          testUrl = '$base/v1/chat/completions';
          final key = _apiKeyController.text.trim();
          if (key.isNotEmpty) {
            headers['Authorization'] = 'Bearer $key';
          }
          break;
        case AiProvider.gemini:
          testUrl =
              'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';
          final key = _apiKeyController.text.trim();
          if (key.isEmpty) {
            setState(() {
              _connectionStatus = 'API Key is required';
              _testingConnection = false;
            });
            return;
          }
          headers['Authorization'] = 'Bearer $key';
          break;
        case AiProvider.openRouter:
          testUrl = 'https://openrouter.ai/api/v1/chat/completions';
          final key = _apiKeyController.text.trim();
          if (key.isEmpty) {
            setState(() {
              _connectionStatus = 'API Key is required';
              _testingConnection = false;
            });
            return;
          }
          headers['Authorization'] = 'Bearer $key';
          headers['HTTP-Referer'] =
              'https://github.com/alfuentes123/AI-Gif-Coder';
          headers['X-Title'] = 'AI Gif Coder';
          break;
        case AiProvider.jules:
          testUrl = 'https://jules.googleapis.com/v1alpha/sources';
          final key = _apiKeyController.text.trim();
          if (key.isEmpty) {
            setState(() {
              _connectionStatus = 'API Key is required';
              _testingConnection = false;
            });
            return;
          }
          headers['X-Goog-Api-Key'] = key;
          break;
        case AiProvider.claude:
          testUrl = 'https://api.anthropic.com/v1/messages';
          final key = _apiKeyController.text.trim();
          if (key.isEmpty) {
            setState(() {
              _connectionStatus = 'API Key is required';
              _testingConnection = false;
            });
            return;
          }
          headers['x-api-key'] = key;
          headers['anthropic-version'] = '2023-06-01';
          break;
        case AiProvider.groq:
          testUrl = 'https://api.groq.com/openai/v1/responses';
          final key = _apiKeyController.text.trim();
          if (key.isEmpty) {
            setState(() {
              _connectionStatus = 'API Key is required';
              _testingConnection = false;
            });
            return;
          }
          headers['Authorization'] = 'Bearer $key';
          break;
        case AiProvider.openAi:
          testUrl = 'https://api.openai.com/v1/responses';
          final key = _apiKeyController.text.trim();
          if (key.isEmpty) {
            setState(() {
              _connectionStatus = 'API Key is required';
              _testingConnection = false;
            });
            return;
          }
          headers['Authorization'] = 'Bearer $key';
          break;
        case AiProvider.deepSeek:
          testUrl = 'https://api.deepseek.com/chat/completions';
          final key = _apiKeyController.text.trim();
          if (key.isEmpty) {
            setState(() {
              _connectionStatus = 'API Key is required';
              _testingConnection = false;
            });
            return;
          }
          headers['Authorization'] = 'Bearer $key';
          break;
      }

      final http.Response response;
      if (_selectedProvider == AiProvider.jules) {
        response = await http
            .get(
              Uri.parse(testUrl),
              headers: headers,
            )
            .timeout(const Duration(seconds: 10));
      } else if (_selectedProvider == AiProvider.claude) {
        response = await http
            .post(
              Uri.parse(testUrl),
              headers: headers,
              body: jsonEncode({
                'model': modelName,
                'max_tokens': 1,
                'messages': [
                  {'role': 'user', 'content': 'ping'}
                ],
              }),
            )
            .timeout(const Duration(seconds: 10));
      } else if (_selectedProvider == AiProvider.openAi ||
          _selectedProvider == AiProvider.groq) {
        response = await http
            .post(
              Uri.parse(testUrl),
              headers: headers,
              body: jsonEncode({
                'model': modelName,
                'input': 'ping',
                'max_output_tokens': 16,
              }),
            )
            .timeout(const Duration(seconds: 10));
      } else {
        response = await http
            .post(
              Uri.parse(testUrl),
              headers: headers,
              body: jsonEncode({
                'model': modelName,
                'messages': [
                  {'role': 'user', 'content': 'ping'}
                ],
                'max_tokens': 1,
              }),
            )
            .timeout(const Duration(seconds: 10));
      }

      if (!mounted) return;
      setState(() {
        if (response.statusCode == 200) {
          _connectionStatus = 'Connected successfully';
        } else {
          String errorMsg;
          try {
            final body = jsonDecode(response.body);
            errorMsg = body['error']?['message'] ??
                'Status code ${response.statusCode}';
          } catch (_) {
            errorMsg = response.body.isNotEmpty
                ? (response.body.length > 100
                    ? '${response.body.substring(0, 100)}...'
                    : response.body)
                : 'Status code ${response.statusCode}';
          }
          _connectionStatus = 'Failed: $errorMsg';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectionStatus = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  Future<void> _saveAndClose() async {
    _saveCurrentFields();

    _store.provider = _selectedProvider;
    _store.lmStudioUrl = _lmStudioUrl;
    _store.lmStudioApiKey = _lmStudioApiKey;
    _store.lmStudioModel = _lmStudioModel;
    _store.geminiApiKey = _geminiApiKey;
    _store.geminiModel = _geminiModel;
    _store.openRouterApiKey = _openRouterApiKey;
    _store.openRouterModel = _openRouterModel;
    _store.julesApiKey = _julesApiKey;
    _store.claudeApiKey = _claudeApiKey;
    _store.claudeModel = _claudeModel;
    _store.groqApiKey = _groqApiKey;
    _store.groqModel = _groqModel;
    _store.openAiApiKey = _openAiApiKey;
    _store.openAiModel = _openAiModel;
    _store.deepSeekApiKey = _deepSeekApiKey;
    _store.deepSeekModel = _deepSeekModel;
    _store.julesRepo = _julesRepo;
    _store.julesBranch = _julesBranch;
    _store.outputFolderPath = _outputFolderPath;

    await _store.save();
    if (mounted) Navigator.pop(context, true);
  }

  Widget _buildProviderOption(AiProvider provider) {
    final isJules = provider == AiProvider.jules;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isJules
            ? const Color(0xFF210C44)
            : const Color(0xFF6B7280).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isJules
              ? const Color(0xFF210C44).withValues(alpha: 0.95)
              : const Color(0xFF6B7280).withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Text(
        provider.label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isJules
              ? Colors.white
              : const Color.fromARGB(255, 238, 238, 238)
                  .withValues(alpha: 0.95),
        ),
      ),
    );
  }

  Widget _buildConnectionTab() {
    final providerItems = [
      ...AiProvider.values.where((p) => p != AiProvider.jules).toList()
        ..sort((a, b) => a.label.compareTo(b.label)),
      AiProvider.jules,
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<AiProvider>(
            initialValue: _selectedProvider,
            isDense: false,
            isExpanded: true,
            itemHeight: null,
            decoration: const InputDecoration(
              labelText: 'API Provider',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            selectedItemBuilder: (context) => providerItems
                .map(
                  (p) => Align(
                    alignment: Alignment.centerLeft,
                    child: _buildProviderOption(p),
                  ),
                )
                .toList(),
            items: providerItems
                .map((p) => DropdownMenuItem(
                      value: p,
                      child: _buildProviderOption(p),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _saveCurrentFields();
                  _loadFieldsForProvider(v);
                  if (v == AiProvider.jules) {
                    _fetchJulesSources();
                  }
                });
              }
            },
          ),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_selectedProvider == AiProvider.lmStudio) ...[
                  TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'Connection URL',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: _apiKeyController,
                  decoration: InputDecoration(
                    labelText: _selectedProvider == AiProvider.lmStudio
                        ? 'API Key (Optional)'
                        : 'API Key',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                if (_selectedProvider != AiProvider.jules) ...[
                  TextField(
                    controller: _modelController,
                    decoration: const InputDecoration(
                      labelText: 'Model name',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (_selectedProvider == AiProvider.jules) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'GitHub Integration',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      if (_fetchingSources)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 18),
                          visualDensity: VisualDensity.compact,
                          onPressed: _fetchJulesSources,
                          tooltip: 'Fetch Repositories',
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_sourcesError != null) ...[
                    Text(
                      _sourcesError!,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.orangeAccent),
                    ),
                    const SizedBox(height: 6),
                  ],
                  DropdownButtonFormField<String>(
                    key: ValueKey(_julesSources),
                    initialValue: _julesRepo,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'GitHub Repository',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: _julesSources.map((source) {
                      final name = source['name'] as String;
                      String displayName = name;
                      if (name.startsWith('sources/')) {
                        displayName = name.replaceFirst('sources/', '');
                        if (displayName.startsWith('github/')) {
                          displayName = displayName.replaceFirst('github/', '');
                        }
                      }
                      return DropdownMenuItem<String>(
                        value: name,
                        child:
                            Text(displayName, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _julesRepo = val;
                        _julesBranch = null;
                        _updateJulesBranches();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_julesRepo),
                    initialValue: _julesBranch,
                    decoration: const InputDecoration(
                      labelText: 'Branch',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: _julesBranches.map((branch) {
                      return DropdownMenuItem<String>(
                        value: branch,
                        child: Text(branch),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _julesBranch = val;
                      });
                    },
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _testingConnection ? null : _testConnection,
                child: _testingConnection
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Test'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _connectionStatus ?? 'Test connection (consumes 1 request)',
                  style: TextStyle(
                    fontSize: 12,
                    color: _connectionStatus == null
                        ? Colors.grey
                        : _connectionStatus!.startsWith('Connected')
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildGifsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickGifFolder,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Choose GIF folder'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _restoreDefaultGifs,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('Restore defaults'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _store.gifFolderPath ?? 'No folder selected',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (_store.gifFolderPath != null && _availableGifs.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'No .gif files found in this folder.',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
              ),
            ),
          if (_availableGifs.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final state in AppState.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DropdownButtonFormField<String>(
                  initialValue: _availableGifs.contains(_store.gifFiles[state])
                      ? _store.gifFiles[state]
                      : null,
                  decoration: InputDecoration(
                    labelText: state.label,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: _availableGifs
                      .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _store.gifFiles[state] = v);
                    }
                  },
                ),
              ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildOutputTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Code file output',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Files returned in code file output mode will be saved directly '
            'into this folder.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pickOutputFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Choose output folder'),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _outputFolderPath ?? 'Default: Documents/Gif_Coder_Outputs',
              style: const TextStyle(fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_outputFolderPath != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _restoreDefaultOutputFolder,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('Use default folder'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: AlertDialog(
        title: const Text('Settings'),
        content: SizedBox(
          width: 440,
          height: 400,
          child: Column(
            children: [
              TabBar(
                tabs: const [
                  Tab(text: 'Connection'),
                  Tab(text: 'Output'),
                  Tab(text: 'GIFs'),
                ],
                indicatorColor: Theme.of(context).colorScheme.primary,
                labelColor: Theme.of(context).colorScheme.primary,
                unselectedLabelColor:
                    Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildConnectionTab(),
                    _buildOutputTab(),
                    _buildGifsTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _saveAndClose, child: const Text('Save')),
        ],
      ),
    );
  }
}
