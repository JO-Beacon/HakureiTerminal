import 'external_runtime_event.dart';
import 'http_runtime_client.dart';

/// Provider-neutral facade for the management surface of an external Agent
/// runtime. Implementations must forward the runtime's own state semantics.
abstract interface class ExternalAgentRuntime {
  Stream<ExternalRuntimeEvent> get events;

  Future<Map<String, dynamic>> info();
  Future<Map<String, dynamic>> runtimeInfo();
  Future<Map<String, dynamic>> health();
  Future<Map<String, dynamic>> currentSession();
  Future<List<Map<String, dynamic>>> listSessions();
  Future<List<Map<String, dynamic>>> listMemory({
    String? topicName,
    int limit = 50,
    int offset = 0,
  });
  Future<Map<String, dynamic>> searchMemory(
    String query, {
    int topK = 5,
    double threshold = 0.7,
  });
  Future<Map<String, dynamic>> memoryGraph();
  Future<Map<String, dynamic>> getMemory(String memoryId);
  Future<Map<String, dynamic>> addMemory(
    String content, {
    String? topicName,
    double importance = 0,
    double emotionalValence = 0,
  });
  Future<Map<String, dynamic>> updateMemory(
    String memoryId, {
    String? content,
    double? importance,
    List<String>? tags,
  });
  Future<Map<String, dynamic>> deleteMemory(String memoryId);
  Future<Map<String, dynamic>> currentScene();
  Future<List<Map<String, dynamic>>> listScenes();
  Future<Map<String, dynamic>> switchScene(String sceneId);
  Future<Map<String, dynamic>> sceneGraph();
  Future<Map<String, dynamic>> currentInitiativeTimer();
  Future<Map<String, dynamic>> updateInitiativeTimer({
    String? timerId,
    num? delaySeconds,
    String? dueAt,
    String? pendingSummary,
    bool? enabled,
  });
  Future<Map<String, dynamic>> cancelInitiativeTimer({String? timerId});
  Future<Map<String, dynamic>> triggerInitiativeTimer({String? timerId});
  Future<Map<String, dynamic>> externalToolStatus({bool includeTools = true});
  Future<Map<String, dynamic>> worldState();
  Future<List<Map<String, dynamic>>> worldRoster();
  Future<List<Map<String, dynamic>>> worldTranscript({int limit = 100});
  Future<List<Map<String, dynamic>>> listWorldSessions();
  Future<Map<String, dynamic>> uploadCharacterPackage({
    required String filename,
    required List<int> bytes,
    String? locale,
    bool overwrite = false,
    bool allowUntrusted = false,
  });
  Future<dynamic> invoke(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]);
}

/// Public HTTP/WebSocket implementation for an independently deployed Runtime.
class GensokyoAiHttpRuntimeFacade implements ExternalAgentRuntime {
  GensokyoAiHttpRuntimeFacade(this.client);

  final GensokyoAiHttpRuntimeClient client;

  @override
  Stream<ExternalRuntimeEvent> get events => client.events;

  @override
  Future<Map<String, dynamic>> info() => client.info();

  @override
  Future<Map<String, dynamic>> runtimeInfo() => _mapCall('runtime.info');

  @override
  Future<Map<String, dynamic>> health() => client.health();

  @override
  Future<Map<String, dynamic>> currentSession() => _mapCall('session.current');

  @override
  Future<List<Map<String, dynamic>>> listSessions() async {
    final sessions = <Map<String, dynamic>>[];
    final seenCursors = <String>{};
    String? cursor;
    while (true) {
      final result = await _mapCall('session.list', <String, dynamic>{
        'limit': 200,
        'cursor': ?cursor,
      });
      final page = result['sessions'];
      if (page is List) {
        sessions.addAll(
          page.whereType<Map>().map((item) => Map<String, dynamic>.from(item)),
        );
      }
      if (result['has_more'] != true) break;
      final nextCursor = result['next_cursor']?.toString().trim();
      if (nextCursor == null ||
          nextCursor.isEmpty ||
          !seenCursors.add(nextCursor)) {
        throw const FormatException(
          'GensokyoAI session.list returned an invalid pagination cursor',
        );
      }
      cursor = nextCursor;
    }
    return List<Map<String, dynamic>>.unmodifiable(sessions);
  }

  @override
  Future<List<Map<String, dynamic>>> listMemory({
    String? topicName,
    int limit = 50,
    int offset = 0,
  }) => _listCall(
    'memory.list',
    params: <String, dynamic>{
      if (topicName != null && topicName.isNotEmpty) 'topic_name': topicName,
      'limit': limit,
      'offset': offset,
    },
    resultKey: 'items',
  );

  @override
  Future<Map<String, dynamic>> searchMemory(
    String query, {
    int topK = 5,
    double threshold = 0.7,
  }) => _mapCall('memory.search', <String, dynamic>{
    'query': query,
    'top_k': topK,
    'threshold': threshold,
  });

  @override
  Future<Map<String, dynamic>> memoryGraph() => _mapCall('memory.graph');

  @override
  Future<Map<String, dynamic>> getMemory(String memoryId) =>
      _mapCall('memory.get', <String, dynamic>{'memory_id': memoryId});

  @override
  Future<Map<String, dynamic>> addMemory(
    String content, {
    String? topicName,
    double importance = 0,
    double emotionalValence = 0,
  }) => _mapCall('memory.add', <String, dynamic>{
    'content': content,
    if (topicName != null && topicName.isNotEmpty) 'topic_name': topicName,
    'importance': importance,
    'emotional_valence': emotionalValence,
  });

  @override
  Future<Map<String, dynamic>> updateMemory(
    String memoryId, {
    String? content,
    double? importance,
    List<String>? tags,
  }) {
    final params = <String, dynamic>{'memory_id': memoryId};
    if (content != null) {
      params['content'] = content;
    }
    if (importance != null) {
      params['importance'] = importance;
    }
    if (tags != null) {
      params['tags'] = tags;
    }
    return _mapCall('memory.update', params);
  }

  @override
  Future<Map<String, dynamic>> deleteMemory(String memoryId) =>
      _mapCall('memory.delete', <String, dynamic>{'memory_id': memoryId});

  @override
  Future<Map<String, dynamic>> currentScene() => _mapCall('scene.current');

  @override
  Future<List<Map<String, dynamic>>> listScenes() => _listCall('scene.list');

  @override
  Future<Map<String, dynamic>> switchScene(String sceneId) =>
      _mapCall('scene.switch', <String, dynamic>{'scene_id': sceneId});

  @override
  Future<Map<String, dynamic>> sceneGraph() => _mapCall('scene.graph');

  @override
  Future<Map<String, dynamic>> currentInitiativeTimer() =>
      _mapCall('initiative_timer.current');

  @override
  Future<Map<String, dynamic>> updateInitiativeTimer({
    String? timerId,
    num? delaySeconds,
    String? dueAt,
    String? pendingSummary,
    bool? enabled,
  }) {
    final params = <String, dynamic>{};
    if (timerId != null && timerId.isNotEmpty) {
      params['timer_id'] = timerId;
    }
    if (delaySeconds != null) {
      params['delay_seconds'] = delaySeconds;
    }
    if (dueAt != null && dueAt.isNotEmpty) {
      params['due_at'] = dueAt;
    }
    if (pendingSummary != null) {
      params['pending_summary'] = pendingSummary;
    }
    if (enabled != null) {
      params['enabled'] = enabled;
    }
    return _mapCall('initiative_timer.update', params);
  }

  @override
  Future<Map<String, dynamic>> cancelInitiativeTimer({String? timerId}) =>
      _mapCall('initiative_timer.cancel', <String, dynamic>{
        if (timerId != null && timerId.isNotEmpty) 'timer_id': timerId,
      });

  @override
  Future<Map<String, dynamic>> triggerInitiativeTimer({String? timerId}) =>
      _mapCall('initiative_timer.trigger', <String, dynamic>{
        if (timerId != null && timerId.isNotEmpty) 'timer_id': timerId,
      });

  @override
  Future<Map<String, dynamic>> externalToolStatus({bool includeTools = true}) =>
      _mapCall('external_tool.status', <String, dynamic>{
        'include_tools': includeTools,
      });

  @override
  Future<Map<String, dynamic>> worldState() => _mapCall('world.state');

  @override
  Future<List<Map<String, dynamic>>> worldRoster() =>
      _listCall('world.roster', resultKey: 'roster');

  @override
  Future<List<Map<String, dynamic>>> worldTranscript({int limit = 100}) =>
      _listCall(
        'world.transcript',
        params: <String, dynamic>{'limit': limit.clamp(1, 500)},
        resultKey: 'entries',
      );

  @override
  Future<List<Map<String, dynamic>>> listWorldSessions() =>
      _listCall('world.session.list', resultKey: 'sessions');

  @override
  Future<Map<String, dynamic>> uploadCharacterPackage({
    required String filename,
    required List<int> bytes,
    String? locale,
    bool overwrite = false,
    bool allowUntrusted = false,
  }) => client.uploadCharacterPackage(
    filename: filename,
    bytes: bytes,
    locale: locale,
    overwrite: overwrite,
    allowUntrusted: allowUntrusted,
  );

  @override
  Future<dynamic> invoke(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) => client.call(method, params);

  Future<Map<String, dynamic>> _mapCall(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    final result = await client.call(method, params);
    return result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> _listCall(
    String method, {
    Map<String, dynamic> params = const <String, dynamic>{},
    String? resultKey,
  }) async {
    final result = await client.call(method, params);
    final value = resultKey == null
        ? result
        : result is Map
        ? result[resultKey]
        : result;
    return value is List
        ? value
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
  }
}
