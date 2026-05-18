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
  List<String> _availableGifs = [];
  String? _connectionStatus;
  bool _testingConnection = false;

  SettingsStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: _store.serverUrl);
    _apiKeyController = TextEditingController(text: _store.apiKey);
    _modelController = TextEditingController(text: _store.modelName);
    _refreshGifList();
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
    final base = _urlController.text.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final apiKey = _apiKeyController.text.trim();
      final headers =
          apiKey.isNotEmpty ? {'Authorization': 'Bearer $apiKey'} : null;
      final response = await http
          .get(Uri.parse('$base/v1/models'), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _connectionStatus = response.statusCode == 200
            ? 'Connected successfully'
            : 'Server returned HTTP ${response.statusCode}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectionStatus = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  Future<void> _saveAndClose() async {
    _store.serverUrl = _urlController.text.trim();
    _store.apiKey = _apiKeyController.text.trim();
    _store.modelName = _modelController.text.trim();
    await _store.save();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Connection',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Connection URL',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
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
                      _connectionStatus ?? 'Test reachability to /v1/models',
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
              TextField(
                controller: _apiKeyController,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  isDense: true,
                  border: OutlineInputBorder(),
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
              const Divider(height: 28),
              const Text('Background GIFs',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickGifFolder,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Choose GIF folder'),
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
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _saveAndClose, child: const Text('Save')),
      ],
    );
  }
}
