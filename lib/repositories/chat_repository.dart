import '../models/app_settings.dart';
import '../models/chat_character.dart';
import '../models/chat_session.dart';
import '../services/python_bridge.dart';

class ProviderDependencyStatus {
  const ProviderDependencyStatus({
    required this.provider,
    required this.installed,
    required this.packages,
    required this.imports,
    required this.missingImports,
  });

  final String provider;
  final bool installed;
  final List<String> packages;
  final List<String> imports;
  final List<String> missingImports;

  factory ProviderDependencyStatus.fromJson(
    String provider,
    Map<String, dynamic> json,
  ) {
    return ProviderDependencyStatus(
      provider: provider,
      installed: json['installed'] == true,
      packages: _stringListFromJson(json['packages']),
      imports: _stringListFromJson(json['imports']),
      missingImports: _stringListFromJson(json['missing_imports']),
    );
  }
}

class DependencyStatusResult {
  const DependencyStatusResult({
    required this.providers,
    required this.allowedProviders,
  });

  final Map<String, ProviderDependencyStatus> providers;
  final List<String> allowedProviders;

  bool get allInstalled {
    return providers.values.every((status) => status.installed);
  }

  List<String> get missingProviders {
    return providers.values
        .where((status) => !status.installed)
        .map((status) => status.provider)
        .toList(growable: false);
  }

  factory DependencyStatusResult.fromJson(Map<String, dynamic> json) {
    final providersJson = json['providers'];
    final providers = <String, ProviderDependencyStatus>{};
    if (providersJson is Map) {
      for (final entry in providersJson.entries) {
        final value = entry.value;
        if (value is Map) {
          final provider = entry.key.toString();
          providers[provider] = ProviderDependencyStatus.fromJson(
            provider,
            Map<String, dynamic>.from(value),
          );
        }
      }
    }
    return DependencyStatusResult(
      providers: providers,
      allowedProviders: _stringListFromJson(json['allowed_providers']),
    );
  }
}

class DependencyInstallResult {
  const DependencyInstallResult({
    required this.ok,
    required this.providers,
    required this.packages,
    required this.alreadyInstalled,
    this.stdout = '',
    this.stderr = '',
  });

  final bool ok;
  final List<String> providers;
  final List<String> packages;
  final bool alreadyInstalled;
  final String stdout;
  final String stderr;

  factory DependencyInstallResult.fromJson(Map<String, dynamic> json) {
    return DependencyInstallResult(
      ok: json['ok'] == true,
      providers: _stringListFromJson(json['providers']),
      packages: _stringListFromJson(json['packages']),
      alreadyInstalled: json['already_installed'] == true,
      stdout: json['stdout']?.toString() ?? '',
      stderr: json['stderr']?.toString() ?? '',
    );
  }
}

class ChatRepository {
  ChatRepository(this._bridge);

  final PythonBridge _bridge;

  Future<List<ChatCharacter>> listCharacters() async {
    final result = await _bridge.call(
      'list_characters',
      params: <String, dynamic>{'locale': 'zh_cn'},
    );
    if (result is! List) {
      return const <ChatCharacter>[];
    }
    return result
        .whereType<Map>()
        .map((json) => ChatCharacter.fromJson(Map<String, dynamic>.from(json)))
        .toList(growable: false);
  }

  Future<ChatSession?> init({
    String? characterPath,
    AppSettings? settings,
  }) async {
    final effectiveSettings = settings ?? AppSettings.defaultSettings;
    final params = <String, dynamic>{
      'new_session': true,
      ...effectiveSettings.toBridgeInitParams(),
    };
    if (characterPath != null && characterPath.isNotEmpty) {
      params['character_path'] = characterPath;
    }
    final result = await _bridge.call('init', params: params);
    if (result is! Map) {
      return null;
    }
    final session = result['session'];
    if (session is! Map) {
      return null;
    }
    return ChatSession.fromJson(Map<String, dynamic>.from(session));
  }

  Future<DependencyStatusResult> dependencyStatus(AppSettings settings) async {
    final result = await _bridge.call(
      'dependency.status',
      params: <String, dynamic>{'providers': settings.dependencyProviders()},
    );
    if (result is Map<String, dynamic>) {
      return DependencyStatusResult.fromJson(result);
    }
    if (result is Map) {
      return DependencyStatusResult.fromJson(Map<String, dynamic>.from(result));
    }
    return const DependencyStatusResult(
      providers: <String, ProviderDependencyStatus>{},
      allowedProviders: <String>[],
    );
  }

  Future<DependencyInstallResult> installDependencies(AppSettings settings) async {
    final result = await _bridge.call(
      'dependency.install',
      params: <String, dynamic>{
        'providers': settings.dependencyProviders(),
        'scope': 'current_runtime',
      },
    );
    if (result is Map<String, dynamic>) {
      return DependencyInstallResult.fromJson(result);
    }
    if (result is Map) {
      return DependencyInstallResult.fromJson(Map<String, dynamic>.from(result));
    }
    return const DependencyInstallResult(
      ok: false,
      providers: <String>[],
      packages: <String>[],
      alreadyInstalled: false,
    );
  }

  Future<void> ensureDependencies(AppSettings settings) async {
    final status = await dependencyStatus(settings);
    if (status.allInstalled) {
      return;
    }
    await installDependencies(settings);
  }

  Future<List<ChatSession>> listSessions() async {
    final result = await _bridge.call('list_sessions');
    if (result is! List) {
      return const <ChatSession>[];
    }
    return result
        .whereType<Map>()
        .map((json) => ChatSession.fromJson(Map<String, dynamic>.from(json)))
        .toList(growable: false);
  }

  Future<String> sendMessage(String message) async {
    final result = await _bridge.call(
      'send_message',
      params: <String, dynamic>{'message': message},
    );
    if (result is Map) {
      return result['content']?.toString() ?? '';
    }
    return '';
  }

  Future<void> shutdown() => _bridge.stop();
}

List<String> _stringListFromJson(Object? value) {
  if (value is List) {
    return value.map((item) => item.toString()).toList(growable: false);
  }
  return const <String>[];
}
