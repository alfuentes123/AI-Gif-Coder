import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

enum AppState { waiting, thinking, replying, working }

extension AppStateInfo on AppState {
  String get label => switch (this) {
        AppState.waiting => 'Waiting',
        AppState.thinking => 'Thinking',
        AppState.replying => 'Replying',
        AppState.working => 'Working',
      };

  String get defaultFileName => '$name.gif';
}

class SettingsStore {
  String serverUrl = 'http://localhost:1234';
  String apiKey = '';
  String modelName = 'local-model';
  String? gifFolderPath;
  final Map<AppState, String> gifFiles = {
    for (final s in AppState.values) s: s.defaultFileName,
  };
  final Map<AppState, String?> _gifPathCache = {};
  bool isLoaded = false;
  final _secureStorage = const FlutterSecureStorage();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString('server_url') ?? serverUrl;
    apiKey = await _secureStorage.read(key: 'api_key') ?? apiKey;
    modelName = prefs.getString('model_name') ?? modelName;
    gifFolderPath = prefs.getString('gif_folder');
    for (final state in AppState.values) {
      gifFiles[state] =
          prefs.getString('gif_file_${state.name}') ?? state.defaultFileName;
    }
    invalidateGifCache();
    await _populateCache();
    isLoaded = true;
  }

  Future<void> _populateCache() async {
    for (final state in AppState.values) {
      await resolveGifPathAsync(state);
    }
  }

  void invalidateGifCache() => _gifPathCache.clear();

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', serverUrl);
    await _secureStorage.write(key: 'api_key', value: apiKey);
    await prefs.setString('model_name', modelName);
    if (gifFolderPath != null) {
      await prefs.setString('gif_folder', gifFolderPath!);
    } else {
      await prefs.remove('gif_folder');
    }
    for (final state in AppState.values) {
      await prefs.setString('gif_file_${state.name}', gifFiles[state]!);
    }
    invalidateGifCache();
    await _populateCache();
  }

  Future<List<String>> listGifsInFolder() async {
    final folder = gifFolderPath;
    if (folder == null || folder.isEmpty) return [];
    final dir = Directory(folder);
    if (!await dir.exists()) return [];
    final items = await dir.list().toList();
    return items
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .where((n) => n.toLowerCase().endsWith('.gif'))
        .toList()
      ..sort();
  }

  String? getCachedGifPath(AppState state) => _gifPathCache[state];

  Future<String?> resolveGifPathAsync(AppState state) async {
    final folder = gifFolderPath;
    if (folder == null || folder.isEmpty) {
      _gifPathCache[state] = null;
      return null;
    }
    final name = gifFiles[state];
    if (name == null || name.isEmpty) {
      _gifPathCache[state] = null;
      return null;
    }
    final fullPath = p.join(folder, name);
    final resolved = await File(fullPath).exists() ? fullPath : null;
    _gifPathCache[state] = resolved;
    return resolved;
  }
}
