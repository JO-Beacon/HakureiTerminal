import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/app_settings.dart';
import '../app_logger.dart';
import '../../models/runtime_identity.dart';
import 'external_runtime_event.dart';
import 'runtime_connection.dart';
import 'runtime_reply.dart';
import 'runtime_stream_event.dart';

typedef RuntimeWebSocketConnector =
    Future<WebSocket> Function(String url, {Map<String, dynamic>? headers});

Future<WebSocket> _defaultWebSocketConnector(
  String url, {
  Map<String, dynamic>? headers,
}) => WebSocket.connect(url, headers: headers);

class GensokyoAiHttpRuntimeClient {
  GensokyoAiHttpRuntimeClient({
    required this.connection,
    HttpClient? httpClient,
    RuntimeEndpointPolicy endpointPolicy = const RuntimeEndpointPolicy(),
    AppLogger? logger,
    RuntimeWebSocketConnector? webSocketConnector,
  }) : _httpClient = httpClient ?? HttpClient(),
       _endpointPolicy = endpointPolicy,
       _logger = logger ?? AppLogger.instance,
       _webSocketConnector = webSocketConnector ?? _defaultWebSocketConnector;

  final ExternalRuntimeConnectionSettings connection;
  final HttpClient _httpClient;
  final RuntimeEndpointPolicy _endpointPolicy;
  final AppLogger _logger;
  final RuntimeWebSocketConnector _webSocketConnector;
  final StreamController<ExternalRuntimeEvent> _events =
      StreamController<ExternalRuntimeEvent>.broadcast();
  final StreamController<bool> _connectionStates =
      StreamController<bool>.broadcast();
  final Map<String, StreamController<Map<String, dynamic>>> _streamFrames =
      <String, StreamController<Map<String, dynamic>>>{};
  WebSocket? _webSocket;
  StreamSubscription<dynamic>? _webSocketSubscription;
  Future<void>? _connectionRequest;
  Future<void>? _webSocketConnect;
  bool _subscribed = false;
  Future<void>? _subscriptionRequest;
  int _nextRequestId = 1;
  int? _lastEventSequence;
  Set<String> _runtimeCapabilities = const <String>{};
  String? _activeStreamId;
  String? _activeStreamRequestId;
  String? _activeSessionId;
  final Map<String, int> _sessionRevisions = <String, int>{};
  _PendingMessageOperation? _unresolvedMessageOperation;
  Future<void>? _disposeRequest;
  bool _disposed = false;

  Stream<ExternalRuntimeEvent> get events => _events.stream;
  Stream<bool> get connectionStates => _connectionStates.stream;
  bool get hasActiveStream => _activeStreamId != null;
  String get agentId => connection.agentId;
  String? get activeSessionId => _activeSessionId;
  bool get supportsMediaImageInput =>
      _runtimeCapabilities.contains('media.upload') &&
      _runtimeCapabilities.contains('media.image_input');

  int? sessionRevision(String sessionId) => _sessionRevisions[sessionId];

  Future<void> connect() {
    if (_webSocket != null) return Future<void>.value();
    final pending = _connectionRequest;
    if (pending != null) return pending;
    late final Future<void> request;
    request = _connect().whenComplete(() {
      if (identical(_connectionRequest, request)) {
        _connectionRequest = null;
      }
    });
    _connectionRequest = request;
    return request;
  }

  Future<void> _connect() async {
    await _logger.trace<void>(
      'runtime.connect',
      component: 'runtime',
      data: _connectionLogData,
      operation: () async {
        await negotiate();
        await _ensureWebSocket();
      },
    );
  }

  Future<Map<String, dynamic>> negotiate() async {
    if (connection.agentId.trim().isEmpty) {
      throw StateError('Runtime connection is missing its persisted agent_id');
    }
    final result = _asMap(await call('runtime.info'));
    _validateRuntimeInfo(result);
    _runtimeCapabilities = result['capabilities'] is List
        ? (result['capabilities'] as List)
              .map((item) => item.toString())
              .toSet()
        : const <String>{};
    return result;
  }

  Future<Map<String, dynamic>> info() => negotiate();

  Future<Map<String, dynamic>> health() =>
      getJson(_endpointPolicy.healthUri(connection.baseUrl));

  Future<Map<String, dynamic>> readiness() =>
      getJson(_endpointPolicy.readinessUri(connection.baseUrl));

  Uri mediaDownloadUri(String mediaId) => _endpointPolicy.mediaDownloadUri(
    connection.baseUrl,
    connection.agentId,
    mediaId,
  );

  Map<String, String> get mediaRequestHeaders =>
      runtimeAuthorizationHeaders(connection.authToken);

  Future<Map<String, dynamic>> uploadMedia({
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) => _postMultipartFile(
    _endpointPolicy.mediaUploadUri(connection.baseUrl, connection.agentId),
    filename: filename,
    bytes: bytes,
    contentType: contentType,
  );

  Future<Map<String, dynamic>> uploadCharacterPackage({
    required String filename,
    required List<int> bytes,
    String? locale,
    bool overwrite = false,
    bool allowUntrusted = false,
  }) => _postMultipartFile(
    _endpointPolicy.characterPackagesUri(
      connection.baseUrl,
      locale: locale,
      overwrite: overwrite,
      allowUntrusted: allowUntrusted,
    ),
    filename: filename,
    bytes: bytes,
    contentType: 'application/zip',
  );

  Future<Map<String, dynamic>> getJson(Uri uri) async {
    final stopwatch = Stopwatch()..start();
    final data = <String, Object?>{
      ..._connectionLogData,
      'endpoint': _logger.safeUri(uri),
    };
    _logger.debug('runtime.http.started', component: 'runtime', data: data);
    int? statusCode;
    try {
      final request = await _httpClient.getUrl(uri);
      request.followRedirects = false;
      _applyHeaders(request);
      final response = await request.close();
      statusCode = response.statusCode;
      final body = await utf8.decoder.bind(response).join();
      final decoded = _decodeMap(body);
      if (statusCode < 200 || statusCode >= 300) {
        throw _exceptionFromEnvelope(decoded, statusCode);
      }
      _logger.info(
        'runtime.http.succeeded',
        component: 'runtime',
        data: <String, Object?>{
          ...data,
          'status_code': statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
      );
      return decoded;
    } catch (error) {
      _logger.error(
        'runtime.http.failed',
        component: 'runtime',
        data: <String, Object?>{
          ...data,
          'status_code': ?statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
        error: error,
      );
      rethrow;
    }
  }

  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    if (method.startsWith('world.') &&
        !_readOnlyWorldMethods.contains(method)) {
      throw UnsupportedError(
        'HakureiTerminal only supports documented read-only world methods',
      );
    }
    final stopwatch = Stopwatch()..start();
    final data = <String, Object?>{
      ..._connectionLogData,
      'method': method,
      'endpoint': _logger.safeUri(_endpointPolicy.rpcUri(connection.baseUrl)),
    };
    _logger.debug('runtime.rpc.started', component: 'runtime', data: data);
    int? statusCode;
    try {
      final preparedParams = _prepareParams(method, params);
      final request = await _httpClient.postUrl(
        _endpointPolicy.rpcUri(connection.baseUrl),
      );
      request.followRedirects = false;
      _applyHeaders(request);
      request.headers.contentType = ContentType.json;
      final id = _requestId();
      request.write(
        jsonEncode(<String, dynamic>{
          'id': id,
          'method': method,
          'params': preparedParams,
        }),
      );
      final response = await request.close();
      statusCode = response.statusCode;
      final body = await utf8.decoder.bind(response).join();
      final envelope = _decodeMap(body);
      if (statusCode < 200 || statusCode >= 300) {
        throw _exceptionFromEnvelope(envelope, statusCode);
      }
      final result = _resultFromEnvelope(envelope);
      _recordResult(method, result);
      _logger.info(
        'runtime.rpc.succeeded',
        component: 'runtime',
        data: <String, Object?>{
          ...data,
          'status_code': statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
      );
      return result;
    } catch (error) {
      _logger.error(
        'runtime.rpc.failed',
        component: 'runtime',
        data: <String, Object?>{
          ...data,
          'status_code': ?statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
        error: error,
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>> renameSession({
    required String sessionId,
    required String title,
  }) async {
    final result = await call('session.rename', <String, dynamic>{
      'session_id': sessionId,
      'title': title,
    });
    return _asMap(result);
  }

  Future<Map<String, dynamic>> initialize({
    required String characterId,
    String? sessionId,
    bool newSession = false,
    ModelProfile? profile,
  }) async {
    final result = await call('agent.init', <String, dynamic>{
      if (characterId.trim().isNotEmpty) 'character': characterId.trim(),
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (newSession) 'new_session': true,
      if (profile != null) ..._profileOverrides(profile),
    });
    final mapped = _asMap(result);
    _recordResult('agent.init', mapped);
    return mapped;
  }

  Stream<RuntimeStreamEvent> streamMessage({
    required String sessionId,
    required int expectedRevision,
    required String latestUserInput,
    String? idempotencyKey,
  }) async* {
    yield* _streamMessage(
      sessionId: sessionId,
      expectedRevision: expectedRevision,
      message: latestUserInput.trim(),
      idempotencyKey: idempotencyKey,
    );
  }

  Stream<RuntimeStreamEvent> streamMessageParts({
    required String sessionId,
    required int expectedRevision,
    required List<Map<String, dynamic>> contentParts,
    String? idempotencyKey,
  }) => _streamMessage(
    sessionId: sessionId,
    expectedRevision: expectedRevision,
    message: List<Map<String, dynamic>>.unmodifiable(contentParts),
    idempotencyKey: idempotencyKey,
  );

  Stream<RuntimeStreamEvent> _streamMessage({
    required String sessionId,
    required int expectedRevision,
    required Object message,
    String? idempotencyKey,
  }) async* {
    final streamStopwatch = Stopwatch()..start();
    final streamLogData = <String, Object?>{
      ..._connectionLogData,
      'session_ref': _logger.reference(sessionId),
      'expected_revision': expectedRevision,
      'message_kind': message is String ? 'text' : 'parts',
      if (message is String) 'input_chars': message.length,
      if (message is List) 'part_count': message.length,
    };
    if ((message is String && message.isEmpty) ||
        (message is List && message.isEmpty)) {
      _logger.warning(
        'runtime.stream.rejected',
        component: 'runtime',
        data: <String, Object?>{...streamLogData, 'reason': 'empty_message'},
      );
      yield const RuntimeStreamFailed(message: '消息不能为空');
      return;
    }
    final unresolved = _unresolvedMessageOperation;
    if (unresolved != null) {
      _logger.warning(
        'runtime.stream.rejected',
        component: 'runtime',
        data: <String, Object?>{
          ...streamLogData,
          'reason': 'previous_operation_unresolved',
        },
      );
      yield RuntimeStreamFailed(
        message: '上一次发送的服务端状态尚未确认，请先刷新会话',
        metadata: <String, dynamic>{
          'code': 'message.operation_status_required',
          'session_id': unresolved.sessionId,
          'idempotency_key': unresolved.idempotencyKey,
        },
      );
      return;
    }
    final id = _requestId();
    final operation = _PendingMessageOperation(
      sessionId: sessionId,
      idempotencyKey: idempotencyKey ?? generateRuntimeUuidV4(),
    );
    StreamController<Map<String, dynamic>>? frames;
    var partial = '';
    var reasoning = '';
    final toolEvents = <Map<String, dynamic>>[];
    var requestSubmitted = false;
    _logger.info(
      'runtime.stream.started',
      component: 'runtime',
      data: streamLogData,
    );
    try {
      frames = await _openStream(id);
      _activeStreamRequestId = id;
      _webSocket!.add(
        jsonEncode(<String, dynamic>{
          'id': id,
          'method': 'agent.send_message_stream',
          'params':
              _prepareParams('agent.send_message_stream', <String, dynamic>{
                'session_id': sessionId,
                'expected_revision': expectedRevision,
                'idempotency_key': operation.idempotencyKey,
                'message': message,
              }),
        }),
      );
      requestSubmitted = true;
      _unresolvedMessageOperation = operation;

      var acknowledged = false;
      await for (final frame in frames.stream) {
        if (frame['ok'] == false) {
          throw _exceptionFromEnvelope(frame, null);
        }
        if (!acknowledged) {
          final acknowledgement = _asMap(frame['result']);
          final streamId = acknowledgement['stream_id']?.toString().trim();
          final generationId = acknowledgement['generation_id']
              ?.toString()
              .trim();
          if (streamId == null ||
              streamId.isEmpty ||
              generationId == null ||
              generationId.isEmpty) {
            throw const FormatException(
              'GensokyoAI v2 stream acknowledgement is incomplete',
            );
          }
          acknowledged = true;
          if (_activeStreamRequestId == id) {
            _activeStreamId = streamId;
          }
          _logger.info(
            'runtime.stream.acknowledged',
            component: 'runtime',
            data: <String, Object?>{
              ...streamLogData,
              'stream_ref': _logger.reference(streamId),
              'generation_ref': _logger.reference(generationId),
            },
          );
          yield RuntimeStreamStarted(
            metadata: <String, dynamic>{
              'request_id': id,
              'stream_id': streamId,
              'generation_id': generationId,
              'idempotency_key': operation.idempotencyKey,
            },
          );
          continue;
        }
        final event = frame['event'];
        if (event is Map) {
          final eventJson = Map<String, dynamic>.from(event);
          final content = eventJson['content'] is String
              ? eventJson['content'] as String
              : '';
          final reasoningContent = eventJson['reasoning_content'] is String
              ? eventJson['reasoning_content'] as String
              : '';
          final type = eventJson['type']?.toString() ?? '';
          if (type == 'reasoning' && reasoningContent.isNotEmpty) {
            reasoning += reasoningContent;
            yield RuntimeStreamReasoningDelta(
              reasoningContent,
              metadata: eventJson,
            );
          }
          final toolInfo = eventJson['tool_info'];
          if (eventJson['is_tool_call'] == true || toolInfo is Map) {
            final info = toolInfo is Map
                ? Map<String, dynamic>.from(toolInfo)
                : const <String, dynamic>{};
            final toolEvent = <String, dynamic>{
              ...eventJson,
              if (info.isNotEmpty) 'tool_info': info,
            };
            toolEvents.add(toolEvent);
            yield RuntimeStreamToolUpdate(info, metadata: toolEvent);
          }
          if (type == 'content' && content.isNotEmpty) {
            partial += content;
            yield RuntimeStreamDelta(content, metadata: eventJson);
          } else if (type == 'cancelled') {
            _unresolvedMessageOperation = null;
            _logger.info(
              'runtime.stream.cancelled',
              component: 'runtime',
              data: <String, Object?>{
                ...streamLogData,
                'duration_ms': streamStopwatch.elapsedMilliseconds,
                'partial_chars': partial.length,
                'reasoning_chars': reasoning.length,
                'tool_event_count': toolEvents.length,
              },
            );
            yield RuntimeStreamCancelled(
              partialContent: partial,
              partialReasoning: reasoning,
              toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
              metadata: eventJson,
            );
            return;
          } else if (type == 'error') {
            throw _exceptionFromEnvelope(eventJson, null);
          }
        }
        if (frame['done'] == true) {
          final result = _asMap(frame['result']);
          _recordResult('agent.send_message_stream', result);
          _unresolvedMessageOperation = null;
          final content = result['content'] is String
              ? result['content'] as String
              : partial;
          _logger.info(
            'runtime.stream.completed',
            component: 'runtime',
            data: <String, Object?>{
              ...streamLogData,
              'duration_ms': streamStopwatch.elapsedMilliseconds,
              'output_chars': content.length,
              'reasoning_chars': reasoning.length,
              'tool_event_count': toolEvents.length,
            },
          );
          yield RuntimeStreamCompleted(
            RuntimeReply(
              content: content,
              reasoningContent: reasoning,
              toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
              metadata: result,
            ),
            metadata: result,
          );
          return;
        }
      }
    } on RuntimeConnectionException catch (error) {
      _logger.error(
        'runtime.stream.failed',
        component: 'runtime',
        data: <String, Object?>{
          ...streamLogData,
          'duration_ms': streamStopwatch.elapsedMilliseconds,
          'request_submitted': requestSubmitted,
          'partial_chars': partial.length,
          if (error.code != null) 'error_code': error.code,
        },
        error: error,
      );
      if (requestSubmitted) {
        yield await _recoverMessageOperation(
          operation,
          error,
          partialContent: partial,
          partialReasoning: reasoning,
          toolEvents: toolEvents,
        );
      } else {
        _unresolvedMessageOperation = null;
        yield RuntimeStreamFailed(
          message: error.kind,
          partialContent: partial,
          partialReasoning: reasoning,
          toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
          metadata: <String, dynamic>{
            if (error.code != null) 'code': error.code,
          },
        );
      }
    } on FormatException catch (error) {
      _logger.error(
        'runtime.stream.invalid_frame',
        component: 'runtime',
        data: <String, Object?>{
          ...streamLogData,
          'duration_ms': streamStopwatch.elapsedMilliseconds,
          'request_submitted': requestSubmitted,
        },
        error: error,
      );
      _unresolvedMessageOperation = null;
      yield RuntimeStreamFailed(
        message: '服务响应格式无效',
        partialContent: partial,
        partialReasoning: reasoning,
        toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
        metadata: <String, dynamic>{
          'code': 'runtime.protocol.invalid_stream_frame',
          'error': error.message,
        },
      );
    } finally {
      if (_activeStreamRequestId == id) {
        _activeStreamRequestId = null;
        _activeStreamId = null;
      }
      final controller = _streamFrames.remove(id) ?? frames;
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    }
  }

  Future<Map<String, dynamic>?> reconcilePendingMessage(
    String sessionId,
  ) async {
    final operation = _unresolvedMessageOperation;
    if (operation == null || operation.sessionId != sessionId) {
      return null;
    }
    final status = _asMap(
      await call('message.status', <String, dynamic>{
        'session_id': operation.sessionId,
        'idempotency_key': operation.idempotencyKey,
      }),
    );
    await call('session.messages', <String, dynamic>{
      'session_id': operation.sessionId,
      'limit': 1,
    });
    if (status['status']?.toString() != 'pending') {
      _unresolvedMessageOperation = null;
    }
    return status;
  }

  Future<void> cancelActiveStream() async {
    final streamId = _activeStreamId;
    if (streamId != null) {
      await cancelStream(streamId);
    }
  }

  Future<void> subscribe({
    Map<String, dynamic> params = const <String, dynamic>{},
  }) {
    if (_subscribed) {
      return Future<void>.value();
    }
    final pending = _subscriptionRequest;
    if (pending != null) {
      return pending;
    }
    late final Future<void> request;
    request = _subscribe(params).whenComplete(() {
      if (identical(_subscriptionRequest, request)) {
        _subscriptionRequest = null;
      }
    });
    _subscriptionRequest = request;
    return request;
  }

  Future<void> _subscribe(Map<String, dynamic> params) async {
    final id = _requestId();
    StreamController<Map<String, dynamic>>? frames;
    try {
      frames = await _openStream(id);
      _webSocket!.add(
        jsonEncode(<String, dynamic>{
          'id': id,
          'method': 'runtime.subscribe',
          'params': <String, dynamic>{
            if (!params.containsKey('after_sequence') &&
                _lastEventSequence != null)
              'after_sequence': _lastEventSequence,
            if (!params.containsKey('replay_limit')) 'replay_limit': 500,
            ...params,
            'agent_id': connection.agentId,
          },
        }),
      );
      final response = await frames.stream.first.timeout(
        const Duration(seconds: 30),
      );
      if (response['ok'] != true) {
        throw _exceptionFromEnvelope(response, null);
      }
      _subscribed = true;
    } finally {
      final controller = _streamFrames.remove(id) ?? frames;
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    }
  }

  Future<void> cancelStream(String streamId) async {
    final id = _requestId();
    StreamController<Map<String, dynamic>>? frames;
    try {
      frames = await _openStream(id);
      _webSocket!.add(
        jsonEncode(<String, dynamic>{
          'id': id,
          'method': 'runtime.cancel_stream',
          'params': <String, dynamic>{'stream_id': streamId},
        }),
      );
      final response = await frames.stream.first.timeout(
        const Duration(seconds: 30),
      );
      if (response['ok'] != true) {
        throw _exceptionFromEnvelope(response, null);
      }
    } finally {
      final controller = _streamFrames.remove(id) ?? frames;
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    }
  }

  Future<void> dispose() => _disposeRequest ??= _dispose();

  Future<void> _dispose() async {
    _logger.info(
      'runtime.dispose.started',
      component: 'runtime',
      data: _connectionLogData,
    );
    _disposed = true;
    final subscription = _webSocketSubscription;
    final socket = _webSocket;
    _webSocketSubscription = null;
    _webSocket = null;
    _connectionRequest = null;
    _subscriptionRequest = null;
    _subscribed = false;
    _activeStreamRequestId = null;
    _activeStreamId = null;
    _failStreams(const RuntimeConnectionException('连接已断开'));
    await subscription?.cancel();
    await socket?.close();
    for (final controller in _streamFrames.values) {
      await controller.close();
    }
    _streamFrames.clear();
    await _events.close();
    await _connectionStates.close();
    _httpClient.close(force: true);
    _logger.info(
      'runtime.dispose.completed',
      component: 'runtime',
      data: _connectionLogData,
    );
  }

  Future<StreamController<Map<String, dynamic>>> _openStream(String id) async {
    await _ensureWebSocket();
    final controller = StreamController<Map<String, dynamic>>();
    _streamFrames[id] = controller;
    return controller;
  }

  Future<void> _ensureWebSocket() async {
    if (_disposed) {
      throw StateError('Runtime client has been disposed');
    }
    if (_webSocket != null) {
      return;
    }
    final pending = _webSocketConnect;
    if (pending != null) {
      return pending;
    }
    late final Future<void> request;
    request = _connectWebSocket().whenComplete(() {
      if (identical(_webSocketConnect, request)) {
        _webSocketConnect = null;
      }
    });
    _webSocketConnect = request;
    return request;
  }

  Future<void> _connectWebSocket() async {
    final endpoint = _endpointPolicy.webSocketUri(connection.baseUrl);
    final stopwatch = Stopwatch()..start();
    final data = <String, Object?>{
      ..._connectionLogData,
      'endpoint': _logger.safeUri(endpoint),
    };
    _logger.info(
      'runtime.websocket.connecting',
      component: 'runtime',
      data: data,
    );
    late final WebSocket socket;
    try {
      socket = await _webSocketConnector(
        endpoint.toString(),
        headers: runtimeAuthorizationHeaders(connection.authToken),
      );
    } catch (error) {
      _logger.error(
        'runtime.websocket.handshake_failed',
        component: 'runtime',
        data: <String, Object?>{
          ...data,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
        error: error,
      );
      rethrow;
    }
    if (_disposed) {
      await socket.close();
      throw StateError('Runtime client has been disposed');
    }
    _webSocket = socket;
    _webSocketSubscription = socket.listen(
      _handleWebSocketFrame,
      onDone: () => _handleWebSocketDisconnect(
        socket,
        const RuntimeConnectionException('连接已断开', recoverable: true),
      ),
      onError: (Object error) {
        _logger.error(
          'runtime.websocket.transport_error',
          component: 'runtime',
          data: data,
          error: error,
        );
        _handleWebSocketDisconnect(
          socket,
          const RuntimeConnectionException('连接失败', recoverable: true),
        );
      },
    );
    _connectionStates.add(true);
    _logger.info(
      'runtime.websocket.connected',
      component: 'runtime',
      data: <String, Object?>{
        ...data,
        'duration_ms': stopwatch.elapsedMilliseconds,
      },
    );
  }

  void _handleWebSocketFrame(dynamic raw) {
    if (raw is! String) {
      return;
    }
    final frame = _decodeMap(raw);
    final event = frame['event'];
    if ((frame['type'] == 'runtime.event' ||
            frame['subscription_id'] != null) &&
        event is Map) {
      final parsed = ExternalRuntimeEvent.fromJson(
        Map<String, dynamic>.from(event),
      );
      final sequence = parsed.sequence;
      if (sequence != null &&
          (_lastEventSequence == null || sequence > _lastEventSequence!)) {
        _lastEventSequence = sequence;
      }
      _events.add(parsed);
      return;
    }
    final id = frame['id']?.toString();
    if (id != null) {
      _streamFrames[id]?.add(frame);
    }
  }

  void _handleWebSocketDisconnect(WebSocket socket, Object error) {
    if (!identical(_webSocket, socket)) {
      return;
    }
    final subscription = _webSocketSubscription;
    _webSocket = null;
    _webSocketSubscription = null;
    _subscribed = false;
    _subscriptionRequest = null;
    _activeStreamRequestId = null;
    _activeStreamId = null;
    _logger.warning(
      'runtime.websocket.disconnected',
      component: 'runtime',
      data: <String, Object?>{
        ..._connectionLogData,
        if (socket.closeCode != null) 'close_code': socket.closeCode,
      },
      error: error,
    );
    _failStreams(error);
    if (!_disposed) {
      _connectionStates.add(false);
    }
    unawaited(subscription?.cancel());
    unawaited(socket.close());
  }

  void _failStreams(Object error) {
    for (final controller in _streamFrames.values) {
      controller.addError(error);
      controller.close();
    }
    _streamFrames.clear();
  }

  void _applyHeaders(HttpClientRequest request) {
    runtimeAuthorizationHeaders(
      connection.authToken,
    ).forEach(request.headers.set);
    request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
  }

  Future<Map<String, dynamic>> _postMultipartFile(
    Uri uri, {
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) async {
    final stopwatch = Stopwatch()..start();
    final logData = <String, Object?>{
      ..._connectionLogData,
      'endpoint': _logger.safeUri(uri),
      'byte_count': bytes.length,
      'content_type': contentType,
    };
    _logger.info('runtime.upload.started', component: 'runtime', data: logData);
    final safeFilename = filename.replaceAll(RegExp(r'[\r\n"]'), '_').trim();
    if (safeFilename.isEmpty) {
      throw ArgumentError.value(filename, 'filename', 'must not be empty');
    }
    final boundary = 'hakurei-${generateRuntimeUuidV4()}';
    final request = await _httpClient.postUrl(uri);
    request.followRedirects = false;
    _applyHeaders(request);
    request.headers.contentType = ContentType(
      'multipart',
      'form-data',
      parameters: <String, String>{'boundary': boundary},
    );
    request.add(
      utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$safeFilename"\r\n'
        'Content-Type: $contentType\r\n\r\n',
      ),
    );
    request.add(bytes);
    request.add(utf8.encode('\r\n--$boundary--\r\n'));
    int? statusCode;
    try {
      final response = await request.close();
      statusCode = response.statusCode;
      final body = await utf8.decoder.bind(response).join();
      Map<String, dynamic> decoded;
      try {
        decoded = _decodeMap(body);
      } on FormatException {
        decoded = <String, dynamic>{'message': body};
      }
      if (statusCode < 200 || statusCode >= 300) {
        throw _exceptionFromEnvelope(decoded, statusCode);
      }
      _logger.info(
        'runtime.upload.succeeded',
        component: 'runtime',
        data: <String, Object?>{
          ...logData,
          'status_code': statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
      );
      return decoded;
    } catch (error) {
      _logger.error(
        'runtime.upload.failed',
        component: 'runtime',
        data: <String, Object?>{
          ...logData,
          'status_code': ?statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
        error: error,
      );
      rethrow;
    }
  }

  Map<String, Object?> get _connectionLogData => <String, Object?>{
    'connection_ref': _logger.reference(connection.id),
    'agent_ref': _logger.reference(connection.agentId),
    'base_url': _logger.safeUri(connection.baseUrl),
  };

  String _requestId() => 'hakurei-${_nextRequestId++}';

  dynamic _resultFromEnvelope(Map<String, dynamic> envelope) {
    if (envelope['ok'] != true) {
      throw _exceptionFromEnvelope(envelope, null);
    }
    return envelope['result'];
  }

  RuntimeConnectionException _exceptionFromEnvelope(
    Map<String, dynamic> envelope,
    int? statusCode,
  ) {
    final error = envelope['error'] is Map
        ? Map<String, dynamic>.from(envelope['error'] as Map)
        : envelope;
    final code = error['code']?.toString() ?? error['error_code']?.toString();
    final message = <Object?>[
      error['message'],
      error['user_message'],
      error['error'],
    ].whereType<String>().join(' ').toLowerCase();
    final missingModelCredentials =
        message.contains('missing credentials') ||
        message.contains('api key is required') ||
        message.contains('api_key is required');
    final kind =
        statusCode == HttpStatus.unauthorized || code == 'authentication_failed'
        ? '认证失败'
        : statusCode == HttpStatus.forbidden ||
              code == 'authorization.forbidden'
        ? '当前身份没有执行此操作的权限'
        : missingModelCredentials
        ? '模型服务缺少凭据，请在 GensokyoAI 配置 Provider Key，或为此连接启用 Provider 委托'
        : code == 'agent.stream.timeout'
        ? 'Runtime 响应超时，必须先确认本次操作状态'
        : code == 'session.revision_conflict'
        ? '会话已被其他客户端更新，请刷新后重试'
        : code == 'session.not_found'
        ? '远程会话不存在或已被删除'
        : code == 'message.idempotency_in_progress'
        ? '消息仍在服务端处理中'
        : code == 'message.operation_outcome_unknown'
        ? '消息结果未知，请刷新会话确认后再发送'
        : code == 'agent.limit_exceeded'
        ? '当前用户创建的 Agent 数量已达到上限'
        : code == 'pagination.invalid_cursor'
        ? '分页期间远端资源已变化，请重新读取'
        : code == 'resource.limit_exceeded'
        ? '服务资源限制'
        : '服务请求失败';
    return RuntimeConnectionException(
      kind,
      statusCode: statusCode,
      code: code,
      recoverable: error['recoverable'] == true,
    );
  }

  Map<String, dynamic> _prepareParams(
    String method,
    Map<String, dynamic> params,
  ) {
    final prepared = <String, dynamic>{...params};
    final isResourceMethod = _resourcePrefixes.any(method.startsWith);
    if (method == 'agent.init' ||
        method.startsWith('world.') ||
        (isResourceMethod && method != 'agent.list')) {
      prepared.putIfAbsent('agent_id', () => connection.agentId);
    }
    if (_sessionMethods.contains(method) ||
        method.startsWith('memory.') ||
        method.startsWith('scene.') ||
        method.startsWith('initiative_timer.')) {
      prepared.putIfAbsent('session_id', () {
        final sessionId = _activeSessionId;
        if (sessionId == null || sessionId.isEmpty) {
          throw StateError('$method requires an explicit session_id');
        }
        return sessionId;
      });
    }
    if (_revisionMethods.contains(method)) {
      prepared.putIfAbsent('expected_revision', () {
        final sessionId = prepared['session_id']?.toString();
        final revision = sessionId == null
            ? null
            : _sessionRevisions[sessionId];
        if (revision == null) {
          throw StateError(
            '$method requires a revision read from session.messages',
          );
        }
        return revision;
      });
    }
    if ((method == 'agent.send_message' ||
            method == 'agent.send_message_stream') &&
        !prepared.containsKey('idempotency_key')) {
      prepared['idempotency_key'] = generateRuntimeUuidV4();
    }
    return prepared;
  }

  void _recordResult(String method, Object? result) {
    if (result is! Map) return;
    if (method.startsWith('world.')) return;
    final mapped = Map<String, dynamic>.from(result);
    final session = mapped['session'];
    if (session is Map) {
      _recordSession(Map<String, dynamic>.from(session));
    }
    if (mapped['session_id'] != null || mapped['revision'] != null) {
      _recordSession(mapped);
    }
    final sessions = mapped['sessions'];
    if (sessions is List) {
      for (final item in sessions.whereType<Map>()) {
        _recordSession(Map<String, dynamic>.from(item), activate: false);
      }
    }
    if (method == 'agent.init' && mapped['agent_id']?.toString() != agentId) {
      throw const FormatException(
        'GensokyoAI initialized a different agent_id than requested',
      );
    }
  }

  void _recordSession(Map<String, dynamic> session, {bool activate = true}) {
    final sessionId = session['session_id']?.toString().trim();
    if (sessionId == null || sessionId.isEmpty) return;
    final revision = int.tryParse(session['revision']?.toString() ?? '');
    if (revision != null && revision >= 0) {
      _sessionRevisions[sessionId] = revision;
    }
    if (activate) {
      _activeSessionId = sessionId;
    }
  }

  void _validateRuntimeInfo(Map<String, dynamic> info) {
    final major = int.tryParse(
      info['protocol_major_version']?.toString() ?? '',
    );
    if (major != 2) {
      throw const RuntimeConnectionException('仅支持 GensokyoAI Agent v2');
    }
    final methods = info['methods'] is List
        ? (info['methods'] as List).map((item) => item.toString()).toSet()
        : const <String>{};
    if (!methods.containsAll(_requiredAgentV2Methods)) {
      throw const RuntimeConnectionException('服务缺少必需的 Agent v2 能力');
    }
    final activeTransport = _asMap(info['active_transport']);
    final disabledMethods = activeTransport['disabled_methods'] is List
        ? (activeTransport['disabled_methods'] as List)
              .map((item) => item.toString())
              .toSet()
        : const <String>{};
    if (_requiredAgentV2Methods.any(disabledMethods.contains)) {
      throw const RuntimeConnectionException('当前传输禁用了必需的 Agent v2 方法');
    }
    final streamProtocol = _asMap(info['stream_protocol']);
    if (streamProtocol['start_acknowledgement'] != true ||
        int.tryParse(streamProtocol['version']?.toString() ?? '') != 2) {
      throw const RuntimeConnectionException('服务不支持 Agent v2 流确认协议');
    }
    final transports = info['transports'];
    final hasWebSocket =
        transports is List &&
        transports.whereType<Map>().any(
          (item) => item['name']?.toString() == 'websocket',
        );
    if (!hasWebSocket) {
      throw const RuntimeConnectionException('服务未声明 WebSocket 传输');
    }
  }

  Future<RuntimeStreamEvent> _recoverMessageOperation(
    _PendingMessageOperation operation,
    RuntimeConnectionException originalError, {
    required String partialContent,
    required String partialReasoning,
    required List<Map<String, dynamic>> toolEvents,
  }) async {
    try {
      final status = _asMap(
        await call('message.status', <String, dynamic>{
          'session_id': operation.sessionId,
          'idempotency_key': operation.idempotencyKey,
        }),
      );
      await call('session.messages', <String, dynamic>{
        'session_id': operation.sessionId,
        'limit': 1,
      });
      final operationStatus = status['status']?.toString();
      if (operationStatus == 'succeeded') {
        final result = _asMap(status['result']);
        _recordResult('agent.send_message_stream', result);
        _unresolvedMessageOperation = null;
        return RuntimeStreamCompleted(
          RuntimeReply(
            content: result['content']?.toString() ?? partialContent,
            reasoningContent:
                result['reasoning_content']?.toString() ?? partialReasoning,
            toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
            metadata: result,
          ),
          metadata: <String, dynamic>{
            ...result,
            'recovered_via': 'message.status',
          },
        );
      }
      if (operationStatus == 'cancelled') {
        _unresolvedMessageOperation = null;
        return RuntimeStreamCancelled(
          partialContent: partialContent,
          partialReasoning: partialReasoning,
          toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
          metadata: status,
        );
      }
      if (operationStatus == 'failed') {
        _unresolvedMessageOperation = null;
        final storedError = _asMap(status['error']);
        return RuntimeStreamFailed(
          message: '消息生成失败，已与服务端状态完成对账',
          partialContent: partialContent,
          partialReasoning: partialReasoning,
          toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
          metadata: <String, dynamic>{
            ...status,
            if (storedError['code'] != null) 'code': storedError['code'],
          },
        );
      }
      return RuntimeStreamFailed(
        message: '消息仍在服务端处理中，请稍后刷新会话',
        partialContent: partialContent,
        partialReasoning: partialReasoning,
        toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
        metadata: <String, dynamic>{
          ...status,
          'code': 'message.operation_pending',
        },
      );
    } on RuntimeConnectionException catch (statusError) {
      try {
        await call('session.messages', <String, dynamic>{
          'session_id': operation.sessionId,
          'limit': 1,
        });
      } on Object {
        // Preserve the unresolved operation until an explicit refresh succeeds.
      }
      if (statusError.code == 'message.operation_not_found' &&
          originalError.code == 'session.revision_conflict') {
        _unresolvedMessageOperation = null;
      }
      return RuntimeStreamFailed(
        message: originalError.kind,
        partialContent: partialContent,
        partialReasoning: partialReasoning,
        toolEvents: List<Map<String, dynamic>>.unmodifiable(toolEvents),
        metadata: <String, dynamic>{
          if (originalError.code != null) 'code': originalError.code,
          if (statusError.code != null) 'status_code': statusError.code,
          'requires_status_confirmation': _unresolvedMessageOperation != null,
        },
      );
    }
  }

  Map<String, dynamic> _profileOverrides(ModelProfile profile) {
    final model = <String, dynamic>{
      'provider': profile.model.provider.trim(),
      'name': profile.model.model.trim(),
      if (profile.model.baseUrl.trim().isNotEmpty)
        'base_url': profile.model.baseUrl.trim(),
      if (profile.model.apiKey.trim().isNotEmpty)
        'api_key': profile.model.apiKey.trim(),
      'stream': profile.model.stream,
    };
    final temperature = double.tryParse(profile.model.temperature.trim());
    final topP = double.tryParse(profile.model.topP.trim());
    final maxTokens = int.tryParse(profile.model.maxTokens.trim());
    if (temperature != null) model['temperature'] = temperature;
    if (topP != null) model['top_p'] = topP;
    if (maxTokens != null) model['max_tokens'] = maxTokens;
    final embedding = <String, dynamic>{
      if (profile.embedding.provider.trim().isNotEmpty)
        'provider': profile.embedding.provider.trim(),
      if (profile.embedding.model.trim().isNotEmpty)
        'name': profile.embedding.model.trim(),
      if (profile.embedding.baseUrl.trim().isNotEmpty)
        'base_url': profile.embedding.baseUrl.trim(),
      if (profile.embedding.apiKey.trim().isNotEmpty)
        'api_key': profile.embedding.apiKey.trim(),
    };
    return <String, dynamic>{
      'model_overrides': model,
      'embedding_overrides': embedding,
    };
  }
}

Map<String, dynamic> _decodeMap(String input) {
  final decoded = jsonDecode(input);
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  throw const FormatException('Runtime response is not an object');
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

const Set<String> _requiredAgentV2Methods = <String>{
  'runtime.info',
  'runtime.health',
  'agent.init',
  'agent.list',
  'agent.delete',
  'agent.send_message',
  'agent.send_message_stream',
  'message.status',
  'character.list',
  'session.create',
  'session.list',
  'session.messages',
};

const List<String> _resourcePrefixes = <String>[
  'agent.',
  'session.',
  'message.',
  'memory.',
  'scene.',
  'initiative_timer.',
  'model.',
  'media.',
  'world.',
];

const Set<String> _readOnlyWorldMethods = <String>{
  'world.state',
  'world.roster',
  'world.transcript',
  'world.session.list',
};

const Set<String> _sessionMethods = <String>{
  'agent.send_message',
  'agent.send_message_stream',
  'message.status',
  'session.current',
  'session.delete',
  'session.export',
  'session.rename',
  'session.messages',
  'session.replace_messages',
  'session.regenerate_from',
  'session.rollback',
};

const Set<String> _revisionMethods = <String>{
  'agent.send_message',
  'agent.send_message_stream',
  'session.delete',
  'session.rename',
  'session.replace_messages',
  'session.regenerate_from',
  'session.rollback',
};

class _PendingMessageOperation {
  const _PendingMessageOperation({
    required this.sessionId,
    required this.idempotencyKey,
  });

  final String sessionId;
  final String idempotencyKey;
}
