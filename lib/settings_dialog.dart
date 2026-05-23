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

    _urlController = TextEditingController(text: _lmStudioUrl);
    _apiKeyController =
        TextEditingController(text: _getApiKeyForProvider(_selectedProvider));
    _modelController =
        TextEditingController(text: _getModelForProvider(_selectedProvider));

    _refreshGifList();
  }

  String _getApiKeyForProvider(AiProvider provider) {
    return switch (provider) {
      AiProvider.lmStudio => _lmStudioApiKey,
      AiProvider.gemini => _geminiApiKey,
      AiProvider.openRouter => _openRouterApiKey,
    };
  }

  String _getModelForProvider(AiProvider provider) {
    return switch (provider) {
      AiProvider.lmStudio => _lmStudioModel,
      AiProvider.gemini => _geminiModel,
      AiProvider.openRouter => _openRouterModel,
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
    }
    _connectionStatus = null;
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
      }

      final response = await http
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

    await _store.save();
    if (mounted) Navigator.pop(context, true);
  }

  Widget _buildConnectionTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<AiProvider>(
            initialValue: _selectedProvider,
            decoration: const InputDecoration(
              labelText: 'API Provider',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: AiProvider.values
                .map((p) => DropdownMenuItem(
                      value: p,
                      child: Text(p.label),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _saveCurrentFields();
                  _loadFieldsForProvider(v);
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
                TextField(
                  controller: _modelController,
                  decoration: const InputDecoration(
                    labelText: 'Model name',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
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
                  initialValue:
                      _availableGifs.contains(_store.gifFiles[state])
                          ? _store.gifFiles[state]
                          : null,
                  decoration: InputDecoration(
                    labelText: state.label,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: _availableGifs
                      .map(
                          (f) => DropdownMenuItem(value: f, child: Text(f)))
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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
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
                  Tab(text: 'GIFs'),
                ],
                indicatorColor: Theme.of(context).colorScheme.primary,
                labelColor: Theme.of(context).colorScheme.primary,
                unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildConnectionTab(),
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
