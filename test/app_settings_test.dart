import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';

void main() {
  group('ModelServiceSettings', () {
    test('serializes and deserializes every model field', () {
      const settings = ModelServiceSettings(
        provider: 'openai',
        model: 'gpt-4o',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
        temperature: '0.7',
        topP: '0.9',
        maxTokens: '2048',
        timeout: '60',
        stream: false,
        think: true,
        reasoningEffort: 'high',
        useProxy: true,
      );

      final json = settings.toJson();
      expect(json['provider'], 'openai');
      expect(json['model'], 'gpt-4o');
      expect(json['base_url'], 'https://api.openai.com/v1');
      expect(json['api_key'], 'sk-test');
      expect(json['temperature'], '0.7');
      expect(json['top_p'], '0.9');
      expect(json['max_tokens'], '2048');
      expect(json['timeout'], '60');
      expect(json['stream'], isFalse);
      expect(json['think'], isTrue);
      expect(json['reasoning_effort'], 'high');
      expect(json['use_proxy'], isTrue);

      final restored = ModelServiceSettings.fromJson(json);
      expect(restored.provider, settings.provider);
      expect(restored.model, settings.model);
      expect(restored.baseUrl, settings.baseUrl);
      expect(restored.apiKey, settings.apiKey);
      expect(restored.temperature, settings.temperature);
      expect(restored.topP, settings.topP);
      expect(restored.maxTokens, settings.maxTokens);
      expect(restored.timeout, settings.timeout);
      expect(restored.stream, settings.stream);
      expect(restored.think, settings.think);
      expect(restored.reasoningEffort, settings.reasoningEffort);
      expect(restored.useProxy, settings.useProxy);
    });

    test('accepts legacy name field when deserializing', () {
      final settings = ModelServiceSettings.fromJson(<String, dynamic>{
        'provider': 'deepseek',
        'name': 'deepseek-chat',
        'stream': 'false',
        'think': 'true',
        'use_proxy': 1,
      });

      expect(settings.provider, 'deepseek');
      expect(settings.model, 'deepseek-chat');
      expect(settings.stream, isFalse);
      expect(settings.think, isTrue);
      expect(settings.useProxy, isTrue);
    });
  });

  group('EmbeddingServiceSettings', () {
    test('serializes and deserializes every embedding field', () {
      const settings = EmbeddingServiceSettings(
        provider: 'openai',
        model: 'text-embedding-3-large',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-embedding',
        dimensions: '3072',
        timeout: '30',
        useProxy: true,
      );

      final json = settings.toJson();
      expect(json['provider'], 'openai');
      expect(json['model'], 'text-embedding-3-large');
      expect(json['base_url'], 'https://api.openai.com/v1');
      expect(json['api_key'], 'sk-embedding');
      expect(json['dimensions'], '3072');
      expect(json['timeout'], '30');
      expect(json['use_proxy'], isTrue);

      final restored = EmbeddingServiceSettings.fromJson(json);
      expect(restored.provider, settings.provider);
      expect(restored.model, settings.model);
      expect(restored.baseUrl, settings.baseUrl);
      expect(restored.apiKey, settings.apiKey);
      expect(restored.dimensions, settings.dimensions);
      expect(restored.timeout, settings.timeout);
      expect(restored.useProxy, settings.useProxy);
    });

    test('accepts legacy name field when deserializing', () {
      final settings = EmbeddingServiceSettings.fromJson(<String, dynamic>{
        'provider': 'openai',
        'name': 'text-embedding-3-small',
        'use_proxy': 'true',
      });

      expect(settings.provider, 'openai');
      expect(settings.model, 'text-embedding-3-small');
      expect(settings.useProxy, isTrue);
    });
  });

  group('AppSettings', () {
    test('round-trips multiple profiles and active dependency policy', () {
      final createdAt = DateTime.utc(2026, 5, 7, 1, 2, 3);
      final updatedAt = DateTime.utc(2026, 5, 7, 4, 5, 6);
      final settings = AppSettings(
        activeProfileId: 'profile-2',
        dependencyInstallPolicy: DependencyInstallPolicy.ask,
        profiles: <ModelProfile>[
          ModelProfile(
            id: 'profile-1',
            name: 'DeepSeek',
            model: const ModelServiceSettings(
              provider: 'deepseek',
              model: 'deepseek-chat',
              baseUrl: 'https://api.deepseek.com/v1',
              apiKey: 'deepseek-key',
              temperature: '0.8',
              topP: '0.95',
              maxTokens: '4096',
              timeout: '120',
              stream: true,
              think: false,
              useProxy: false,
            ),
            embedding: const EmbeddingServiceSettings(
              provider: 'openai',
              model: 'text-embedding-3-small',
              dimensions: '1536',
            ),
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          ModelProfile(
            id: 'profile-2',
            name: 'Claude',
            model: const ModelServiceSettings(
              provider: 'claude',
              model: 'claude-3-5-sonnet-latest',
              stream: false,
              think: true,
              reasoningEffort: 'medium',
              useProxy: true,
            ),
            embedding: const EmbeddingServiceSettings(),
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        ],
      );

      final restored = AppSettings.fromJson(settings.toJson());

      expect(restored.profiles, hasLength(2));
      expect(restored.activeProfileId, 'profile-2');
      expect(restored.activeProfile.name, 'Claude');
      expect(restored.dependencyInstallPolicy, DependencyInstallPolicy.ask);
      expect(restored.profiles.first.createdAt, createdAt);
      expect(restored.profiles.first.updatedAt, updatedAt);
      expect(restored.profiles.first.model.provider, 'deepseek');
      expect(restored.profiles.first.model.model, 'deepseek-chat');
      expect(restored.profiles.first.model.maxTokens, '4096');
      expect(restored.profiles.first.embedding.model, 'text-embedding-3-small');
      expect(restored.profiles.last.model.provider, 'claude');
      expect(restored.profiles.last.model.stream, isFalse);
      expect(restored.profiles.last.model.think, isTrue);
      expect(restored.profiles.last.model.useProxy, isTrue);
    });

    test('migrates legacy single-profile settings to default ModelProfile', () {
      final migrated = AppSettings.fromJson(<String, dynamic>{
        'dependency_install_policy': 'manual',
        'model': <String, dynamic>{
          'provider': 'openai',
          'name': 'gpt-4o-mini',
          'base_url': 'https://api.openai.com/v1',
          'api_key': 'legacy-model-key',
          'temperature': 0.6,
          'top_p': 0.85,
          'max_tokens': 1024,
          'timeout': 45,
          'stream': false,
          'think': true,
          'reasoning_effort': 'low',
          'use_proxy': true,
        },
        'embedding': <String, dynamic>{
          'provider': 'openai',
          'name': 'text-embedding-3-large',
          'base_url': 'https://api.openai.com/v1',
          'api_key': 'legacy-embedding-key',
          'dimensions': 3072,
          'timeout': 20,
          'use_proxy': true,
        },
      });

      expect(migrated.profiles, hasLength(1));
      expect(migrated.activeProfileId, 'default');
      expect(migrated.dependencyInstallPolicy, DependencyInstallPolicy.manual);
      expect(migrated.activeProfile.name, '默认配置');
      expect(migrated.model.provider, 'openai');
      expect(migrated.model.model, 'gpt-4o-mini');
      expect(migrated.model.baseUrl, 'https://api.openai.com/v1');
      expect(migrated.model.apiKey, 'legacy-model-key');
      expect(migrated.model.temperature, '0.6');
      expect(migrated.model.topP, '0.85');
      expect(migrated.model.maxTokens, '1024');
      expect(migrated.model.timeout, '45');
      expect(migrated.model.stream, isFalse);
      expect(migrated.model.think, isTrue);
      expect(migrated.model.reasoningEffort, 'low');
      expect(migrated.model.useProxy, isTrue);
      expect(migrated.embedding.provider, 'openai');
      expect(migrated.embedding.model, 'text-embedding-3-large');
      expect(migrated.embedding.dimensions, '3072');
      expect(migrated.embedding.timeout, '20');
      expect(migrated.embedding.useProxy, isTrue);
    });

    test('falls back to first profile when active profile id is missing', () {
      final settings = AppSettings.fromJson(<String, dynamic>{
        'active_profile_id': 'missing-profile',
        'profiles': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'profile-1',
            'name': 'Only Profile',
            'model': <String, dynamic>{
              'provider': 'deepseek',
              'model': 'deepseek-chat',
            },
            'embedding': <String, dynamic>{
              'provider': 'openai',
              'model': 'text-embedding-3-small',
            },
            'created_at': '2026-05-07T00:00:00.000Z',
            'updated_at': '2026-05-07T01:00:00.000Z',
          },
        ],
      });

      expect(settings.activeProfileId, 'profile-1');
      expect(settings.activeProfile.name, 'Only Profile');
    });

    test('returns unique dependency providers for active profile only', () {
      final settings = AppSettings(
        activeProfileId: 'profile-1',
        profiles: <ModelProfile>[
          ModelProfile(
            id: 'profile-1',
            name: 'OpenAI Only',
            model: const ModelServiceSettings(
              provider: 'openai',
              model: 'gpt-4o-mini',
            ),
            embedding: const EmbeddingServiceSettings(
              provider: 'openai',
              model: 'text-embedding-3-small',
            ),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
          ModelProfile(
            id: 'profile-2',
            name: 'Claude Inactive',
            model: const ModelServiceSettings(
              provider: 'claude',
              model: 'claude-3-5-sonnet-latest',
            ),
            embedding: const EmbeddingServiceSettings(),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ],
      );

      expect(settings.dependencyProviders(), <String>['openai']);
    });

    test('builds normalized bridge init params from active profile', () {
      final settings = AppSettings(
        activeProfileId: 'profile-1',
        profiles: <ModelProfile>[
          ModelProfile(
            id: 'profile-1',
            name: 'Bridge Profile',
            model: const ModelServiceSettings(
              provider: ' openai ',
              model: ' gpt-4o ',
              baseUrl: 'https://api.openai.com/v1/chat/completions/',
              apiKey: ' sk-test ',
              temperature: '0.7',
              topP: '0.9',
              maxTokens: '2048',
              timeout: '60',
              stream: true,
              think: false,
              reasoningEffort: ' medium ',
              useProxy: true,
            ),
            embedding: const EmbeddingServiceSettings(
              provider: ' openai ',
              model: ' text-embedding-3-small ',
              baseUrl: 'https://api.openai.com/v1/',
              apiKey: ' sk-embedding ',
              dimensions: '1536',
              timeout: '30',
              useProxy: true,
            ),
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ],
      );

      final params = settings.toBridgeInitParams();
      final model = params['model_overrides'] as Map<String, dynamic>;
      final embedding = params['embedding_overrides'] as Map<String, dynamic>;

      expect(model['provider'], 'openai');
      expect(model['name'], 'gpt-4o');
      expect(model['base_url'], 'https://api.openai.com/v1');
      expect(model['api_key'], 'sk-test');
      expect(model['temperature'], 0.7);
      expect(model['top_p'], 0.9);
      expect(model['max_tokens'], 2048);
      expect(model['timeout'], 60);
      expect(model['stream'], isTrue);
      expect(model['think'], isFalse);
      expect(model['reasoning_effort'], 'medium');
      expect(model['use_proxy'], isTrue);

      expect(embedding['provider'], 'openai');
      expect(embedding['name'], 'text-embedding-3-small');
      expect(embedding['base_url'], 'https://api.openai.com/v1');
      expect(embedding['api_key'], 'sk-embedding');
      expect(embedding['dimensions'], 1536);
      expect(embedding['timeout'], 30);
      expect(embedding['use_proxy'], isTrue);
    });
  });
}
