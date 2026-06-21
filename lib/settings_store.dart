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

enum AiProvider {
  lmStudio,
  gemini,
  openRouter,
  jules,
  claude,
  groq,
  openAi,
  deepSeek,
}

extension AiProviderExtension on AiProvider {
  String get label => switch (this) {
        AiProvider.lmStudio => 'LM Studio / Custom',
        AiProvider.gemini => 'Google AI Studio',
        AiProvider.openRouter => 'OpenRouter',
        AiProvider.jules => 'Jules by Google',
        AiProvider.claude => 'Claude',
        AiProvider.groq => 'Groq',
        AiProvider.openAi => 'OpenAI',
        AiProvider.deepSeek => 'DeepSeek',
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

  String claudeApiKey = '';
  String claudeModel = 'claude-sonnet-4-5';

  String groqApiKey = '';
  String groqModel = 'llama-3.3-70b-versatile';

  String openAiApiKey = '';
  String openAiModel = 'gpt-5.5';

  String deepSeekApiKey = '';
  String deepSeekModel = 'deepseek-v4-flash';

  String? outputFolderPath;
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
      AiProvider.claude => 'https://api.anthropic.com/v1',
      AiProvider.groq => 'https://api.groq.com/openai/v1',
      AiProvider.openAi => 'https://api.openai.com/v1',
      AiProvider.deepSeek => 'https://api.deepseek.com',
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
      AiProvider.claude => claudeApiKey,
      AiProvider.groq => groqApiKey,
      AiProvider.openAi => openAiApiKey,
      AiProvider.deepSeek => deepSeekApiKey,
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
      case AiProvider.claude:
        claudeApiKey = val;
        break;
      case AiProvider.groq:
        groqApiKey = val;
        break;
      case AiProvider.openAi:
        openAiApiKey = val;
        break;
      case AiProvider.deepSeek:
        deepSeekApiKey = val;
        break;
    }
  }

  String get modelName {
    return switch (provider) {
      AiProvider.lmStudio => lmStudioModel,
      AiProvider.gemini => geminiModel,
      AiProvider.openRouter => openRouterModel,
      AiProvider.jules => 'jules-coding-agent',
      AiProvider.claude => claudeModel,
      AiProvider.groq => groqModel,
      AiProvider.openAi => openAiModel,
      AiProvider.deepSeek => deepSeekModel,
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
      case AiProvider.claude:
        claudeModel = val;
        break;
      case AiProvider.groq:
        groqModel = val;
        break;
      case AiProvider.openAi:
        openAiModel = val;
        break;
      case AiProvider.deepSeek:
        deepSeekModel = val;
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
      AiProvider.claude => 'https://api.anthropic.com/v1/messages',
      AiProvider.groq => 'https://api.groq.com/openai/v1/chat/completions',
      AiProvider.openAi => 'https://api.openai.com/v1/chat/completions',
      AiProvider.deepSeek => 'https://api.deepseek.com/chat/completions',
    };
  }

  String get responsesUrl {
    return switch (provider) {
      AiProvider.openAi => 'https://api.openai.com/v1/responses',
      AiProvider.groq => 'https://api.groq.com/openai/v1/responses',
      _ => chatCompletionsUrl,
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
      AiProvider.claude => 'https://api.anthropic.com/v1/models',
      AiProvider.groq => 'https://api.groq.com/openai/v1/models',
      AiProvider.openAi => 'https://api.openai.com/v1/models',
      AiProvider.deepSeek => 'https://api.deepseek.com/models',
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

    claudeApiKey = await _secureStorage.read(key: 'claude_api_key') ?? '';
    claudeModel = prefs.getString('claude_model_name') ?? 'claude-sonnet-4-5';

    groqApiKey = await _secureStorage.read(key: 'groq_api_key') ?? '';
    groqModel = prefs.getString('groq_model_name') ?? 'llama-3.3-70b-versatile';

    openAiApiKey = await _secureStorage.read(key: 'open_ai_api_key') ?? '';
    openAiModel = prefs.getString('open_ai_model_name') ?? 'gpt-5.5';

    deepSeekApiKey = await _secureStorage.read(key: 'deep_seek_api_key') ?? '';
    deepSeekModel =
        prefs.getString('deep_seek_model_name') ?? 'deepseek-v4-flash';

    outputFolderPath = prefs.getString('output_folder');
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

    await _secureStorage.write(key: 'claude_api_key', value: claudeApiKey);
    await prefs.setString('claude_model_name', claudeModel);

    await _secureStorage.write(key: 'groq_api_key', value: groqApiKey);
    await prefs.setString('groq_model_name', groqModel);

    await _secureStorage.write(key: 'open_ai_api_key', value: openAiApiKey);
    await prefs.setString('open_ai_model_name', openAiModel);

    await _secureStorage.write(key: 'deep_seek_api_key', value: deepSeekApiKey);
    await prefs.setString('deep_seek_model_name', deepSeekModel);

    // Save legacy keys for maximum backward compatibility
    await prefs.setString('server_url', serverUrl);
    await _secureStorage.write(key: 'api_key', value: apiKey);
    await prefs.setString('model_name', modelName);

    if (outputFolderPath != null && outputFolderPath!.isNotEmpty) {
      await prefs.setString('output_folder', outputFolderPath!);
    } else {
      await prefs.remove('output_folder');
    }
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
