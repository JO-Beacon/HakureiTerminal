import '../../models/assistant.dart';
import 'http_runtime_client.dart';

abstract class AssistantProviderAdapter {
  const AssistantProviderAdapter();

  String get id;

  Future<List<Assistant>> listAssistants();
}

class GensokyoAiHttpAssistantProviderAdapter extends AssistantProviderAdapter {
  const GensokyoAiHttpAssistantProviderAdapter(this.client);

  final GensokyoAiHttpRuntimeClient client;

  @override
  String get id => AssistantProviderId.gensokyoAi.value;

  @override
  Future<List<Assistant>> listAssistants() async {
    final result = await client.call('character.list');
    if (result is! List) {
      return const <Assistant>[];
    }
    return result
        .whereType<Map>()
        .map((item) {
          final character = Map<String, dynamic>.from(item);
          final remoteId = character['id']?.toString() ?? '';
          return Assistant(
            id: 'gensokyoai_${client.connection.id}_$remoteId',
            name: character['name']?.toString() ?? remoteId,
            description: character['greeting']?.toString() ?? '',
            providerId: AssistantProviderId.gensokyoAi,
            providerAssistantId: remoteId,
            metadata: <String, dynamic>{
              'external_connection_id': client.connection.id,
              'remote_character_id': remoteId,
              'diagnostics': character['diagnostics'],
            },
          );
        })
        .toList(growable: false);
  }
}
