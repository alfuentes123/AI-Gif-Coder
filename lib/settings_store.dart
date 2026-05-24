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

enum AiProvider { lmStudio, gemini, openRouter, jules }

extension AiProviderExtension on AiProvider {
  String get label => switch (this) {
        AiProvider.lmStudio => 'LM Studio / Custom',
        AiProvider.gemini => 'Gemini',
        AiProvider.openRouter => 'OpenRouter',
        AiProvider.jules => 'Jules (Google Labs)',
      };
}

class SettingsStore {
  AiProvider provider = AiProvider.lmStudio;

  String lmStudioUrl = 'http://localhost:1234';
  String lmStudioApiKey = '';
  String lmStudioModel = 'local-model';

  String geminiApiKey = '';
  String geminiModel = 'gemma-4-31b-it';

  String openRouterApiKey = '';
  String openRouterModel = 'openrouter/owl-alpha';

  String julesApiKey = '';
  String? julesRepo;
  String? julesBranch;

  String? gifFolderPath;
  final Map<AppState, String> gifFiles = {
    for (final s in AppState.values) s: s.defaultFileName,
  };
  final Map<AppState, String?> _gifPathCache = {};
  bool isLoaded = false;
  final _secureStorage = const FlutterSecureStorage();

  String get serverUrl {
    return switch (provider) {
      AiProvider.lmStudio => lmStudioUrl,
      AiProvider.gemini =>
        'https://generativelanguage.googleapis.com/v1beta/openai/',
      AiProvider.openRouter => 'https://openrouter.ai/api/v1',
      AiProvider.jules => 'https://jules.googleapis.com/v1alpha',
    };
  }

  set serverUrl(String val) {
    if (provider == AiProvider.lmStudio) {
      lmStudioUrl = val;
    }
  }

  String get apiKey {
    return switch (provider) {
      AiProvider.lmStudio => lmStudioApiKey,
      AiProvider.gemini => geminiApiKey,
      AiProvider.openRouter => openRouterApiKey,
      AiProvider.jules => julesApiKey,
    };
  }

  set apiKey(String val) {
    switch (provider) {
      case AiProvider.lmStudio:
        lmStudioApiKey = val;
        break;
      case AiProvider.gemini:
        geminiApiKey = val;
        break;
      case AiProvider.openRouter:
        openRouterApiKey = val;
        break;
      case AiProvider.jules:
        julesApiKey = val;
        break;
    }
  }

  String get modelName {
    return switch (provider) {
      AiProvider.lmStudio => lmStudioModel,
      AiProvider.gemini => geminiModel,
      AiProvider.openRouter => openRouterModel,
      AiProvider.jules => 'jules-coding-agent',
    };
  }

  set modelName(String val) {
    switch (provider) {
      case AiProvider.lmStudio:
        lmStudioModel = val;
        break;
      case AiProvider.gemini:
        geminiModel = val;
        break;
      case AiProvider.openRouter:
        openRouterModel = val;
        break;
      case AiProvider.jules:
        break;
    }
  }

  String get chatCompletionsUrl {
    return switch (provider) {
      AiProvider.lmStudio =>
        '${serverUrl.replaceAll(RegExp(r'/+$'), '')}/v1/chat/completions',
      AiProvider.gemini =>
        'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      AiProvider.openRouter => 'https://openrouter.ai/api/v1/chat/completions',
      AiProvider.jules => 'https://jules.googleapis.com/v1alpha/sessions',
    };
  }

  String get modelsUrl {
    return switch (provider) {
      AiProvider.lmStudio =>
        '${serverUrl.replaceAll(RegExp(r'/+$'), '')}/v1/models',
      AiProvider.gemini =>
        'https://generativelanguage.googleapis.com/v1beta/openai/models',
      AiProvider.openRouter => 'https://openrouter.ai/api/v1/models',
      AiProvider.jules => 'https://jules.googleapis.com/v1alpha/sources',
    };
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final providerStr = prefs.getString('api_provider');
    provider = AiProvider.values.firstWhere(
      (e) => e.name == providerStr,
      orElse: () => AiProvider.lmStudio,
    );

    lmStudioUrl = prefs.getString('lm_studio_server_url') ??
        prefs.getString('server_url') ??
        'http://localhost:1234';
    lmStudioApiKey = await _secureStorage.read(key: 'lm_studio_api_key') ??
        await _secureStorage.read(key: 'api_key') ??
        '';
    lmStudioModel = prefs.getString('lm_studio_model_name') ??
        prefs.getString('model_name') ??
        'local-model';

    geminiApiKey = await _secureStorage.read(key: 'gemini_api_key') ?? '';
    geminiModel = prefs.getString('gemini_model_name') ?? 'gemini-2.5-flash';

    openRouterApiKey =
        await _secureStorage.read(key: 'open_router_api_key') ?? '';
    openRouterModel =
        prefs.getString('open_router_model_name') ?? 'google/gemini-2.5-flash';

    julesApiKey = await _secureStorage.read(key: 'jules_api_key') ?? '';
    julesRepo = prefs.getString('jules_repo');
    julesBranch = prefs.getString('jules_branch');

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

    await prefs.setString('api_provider', provider.name);

    await prefs.setString('lm_studio_server_url', lmStudioUrl);
    await _secureStorage.write(key: 'lm_studio_api_key', value: lmStudioApiKey);
    await prefs.setString('lm_studio_model_name', lmStudioModel);

    await _secureStorage.write(key: 'gemini_api_key', value: geminiApiKey);
    await prefs.setString('gemini_model_name', geminiModel);

    await _secureStorage.write(
        key: 'open_router_api_key', value: openRouterApiKey);
    await prefs.setString('open_router_model_name', openRouterModel);

    await _secureStorage.write(key: 'jules_api_key', value: julesApiKey);
    if (julesRepo != null) {
      await prefs.setString('jules_repo', julesRepo!);
    } else {
      await prefs.remove('jules_repo');
    }
    if (julesBranch != null) {
      await prefs.setString('jules_branch', julesBranch!);
    } else {
      await prefs.remove('jules_branch');
    }

    // Save legacy keys for maximum backward compatibility
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
