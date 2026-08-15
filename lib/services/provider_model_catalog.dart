import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';

class ProviderModelCatalogEntry {
  const ProviderModelCatalogEntry({
    required this.id,
    required this.name,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final Map<String, dynamic> metadata;
}

class ProviderModelCatalogException implements Exception {
  const ProviderModelCatalogException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract interface class ProviderModelCatalog {
  Future<List<ProviderModelCatalogEntry>> listModels({
    required String provider,
    required String baseUrl,
    required String apiKey,
    Duration timeout,
    bool useProxy,
  });
}

class HttpProviderModelCatalog implements ProviderModelCatalog {
  HttpProviderModelCatalog({
    HttpClient Function()? httpClientFactory,
    AppLogger? logger,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _logger = logger ?? AppLogger.instance;

  static const int _maxResponseBytes = 10 * 1024 * 1024;
  static const int _maxPages = 100;

  final HttpClient Function() _httpClientFactory;
  final AppLogger _logger;

  @override
  Future<List<ProviderModelCatalogEntry>> listModels({
    required String provider,
    required String baseUrl,
    required String apiKey,
    Duration timeout = const Duration(seconds: 30),
    bool useProxy = false,
  }) => _logger.trace<List<ProviderModelCatalogEntry>>(
    'provider.models.list',
    component: 'provider_catalog',
    data: <String, Object?>{
      'provider': provider,
      'base_url': _logger.safeUri(baseUrl),
      'timeout_ms': timeout.inMilliseconds,
      'use_proxy': useProxy,
      'credential_configured': apiKey.trim().isNotEmpty,
    },
    operation: () => _listModels(
      provider: provider,
      baseUrl: baseUrl,
      apiKey: apiKey,
      timeout: timeout,
      useProxy: useProxy,
    ),
  );

  Future<List<ProviderModelCatalogEntry>> _listModels({
    required String provider,
    required String baseUrl,
    required String apiKey,
    required Duration timeout,
    required bool useProxy,
  }) async {
    final normalizedProvider = _normalizeProvider(provider);
    final base = _normalizeBaseUrl(baseUrl);
    final client = _httpClientFactory()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    if (useProxy) {
      client.findProxy = HttpClient.findProxyFromEnvironment;
    } else {
      client.findProxy = (_) => 'DIRECT';
    }
    try {
      final models = switch (normalizedProvider) {
        'ollama' => await _listOllama(client, base, apiKey, timeout),
        'claude' => await _listAnthropic(client, base, apiKey, timeout),
        'gemini' => await _listGemini(client, base, apiKey, timeout),
        'openai' || 'openai_responses' || 'openrouter' || 'deepseek' =>
          await _listOpenAiCompatible(client, base, apiKey, timeout),
        _ => throw ProviderModelCatalogException(
          '暂不支持从 Provider“$provider”获取模型列表',
        ),
      };
      final deduplicated = <String, ProviderModelCatalogEntry>{};
      for (final model in models) {
        deduplicated.putIfAbsent(model.id, () => model);
      }
      final result = deduplicated.values.toList(growable: false)
        ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
      if (result.isEmpty) {
        throw const ProviderModelCatalogException('Provider 返回了空模型列表');
      }
      return result;
    } on ProviderModelCatalogException {
      rethrow;
    } on TimeoutException {
      throw const ProviderModelCatalogException('获取模型列表超时');
    } on SocketException catch (error) {
      throw ProviderModelCatalogException('无法连接 Provider：${error.message}');
    } on HttpException catch (error) {
      throw ProviderModelCatalogException(
        'Provider HTTP 请求失败：${error.message}',
      );
    } on HandshakeException {
      throw const ProviderModelCatalogException('Provider TLS 连接失败');
    } on FormatException catch (error) {
      throw ProviderModelCatalogException(error.message);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<ProviderModelCatalogEntry>> _listOpenAiCompatible(
    HttpClient client,
    Uri base,
    String apiKey,
    Duration timeout,
  ) async {
    final endpoint = _openAiModelsUri(base);
    final payload = await _getJson(
      client,
      endpoint,
      headers: _bearerHeaders(apiKey),
      timeout: timeout,
    );
    return _modelsFromList(payload['data'], idFields: const <String>['id']);
  }

  Future<List<ProviderModelCatalogEntry>> _listOllama(
    HttpClient client,
    Uri base,
    String apiKey,
    Duration timeout,
  ) async {
    final payload = await _getJson(
      client,
      _ollamaModelsUri(base),
      headers: _bearerHeaders(apiKey),
      timeout: timeout,
    );
    return _modelsFromList(
      payload['models'],
      idFields: const <String>['model', 'name'],
    );
  }

  Future<List<ProviderModelCatalogEntry>> _listAnthropic(
    HttpClient client,
    Uri base,
    String apiKey,
    Duration timeout,
  ) async {
    final models = <ProviderModelCatalogEntry>[];
    final endpoint = _anthropicModelsUri(base);
    String? afterId;
    final seenCursors = <String>{};
    for (var page = 0; page < _maxPages; page++) {
      final uri = endpoint.replace(
        queryParameters: <String, String>{
          'limit': '1000',
          'after_id': ?afterId,
        },
      );
      final payload = await _getJson(
        client,
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'application/json',
          if (apiKey.trim().isNotEmpty) 'x-api-key': apiKey.trim(),
          'anthropic-version': '2023-06-01',
        },
        timeout: timeout,
      );
      models.addAll(
        _modelsFromList(
          payload['data'],
          idFields: const <String>['id'],
          nameFields: const <String>['display_name', 'name'],
        ),
      );
      if (payload['has_more'] != true) {
        return models;
      }
      final next = payload['last_id']?.toString().trim() ?? '';
      if (next.isEmpty || !seenCursors.add(next)) {
        throw const ProviderModelCatalogException('Provider 模型列表分页游标无效');
      }
      afterId = next;
    }
    throw const ProviderModelCatalogException('Provider 模型列表分页超过安全上限');
  }

  Future<List<ProviderModelCatalogEntry>> _listGemini(
    HttpClient client,
    Uri base,
    String apiKey,
    Duration timeout,
  ) async {
    final models = <ProviderModelCatalogEntry>[];
    final endpoint = _geminiModelsUri(base);
    String? pageToken;
    final seenTokens = <String>{};
    for (var page = 0; page < _maxPages; page++) {
      final uri = endpoint.replace(
        queryParameters: <String, String>{
          'pageSize': '1000',
          'pageToken': ?pageToken,
        },
      );
      final payload = await _getJson(
        client,
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'application/json',
          if (apiKey.trim().isNotEmpty) 'x-goog-api-key': apiKey.trim(),
        },
        timeout: timeout,
      );
      models.addAll(
        _modelsFromList(
          payload['models'],
          idFields: const <String>['name', 'id'],
          nameFields: const <String>['displayName', 'display_name'],
        ),
      );
      final next = payload['nextPageToken']?.toString().trim() ?? '';
      if (next.isEmpty) {
        return models;
      }
      if (!seenTokens.add(next)) {
        throw const ProviderModelCatalogException('Provider 模型列表分页游标无效');
      }
      pageToken = next;
    }
    throw const ProviderModelCatalogException('Provider 模型列表分页超过安全上限');
  }

  Future<Map<String, dynamic>> _getJson(
    HttpClient client,
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxResponseBytes) {
        throw const ProviderModelCatalogException('Provider 模型列表响应过大');
      }
    }
    if (response.isRedirect) {
      throw const ProviderModelCatalogException('Provider 模型列表接口不允许重定向');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProviderModelCatalogException(
        _statusMessage(response.statusCode),
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Provider 模型列表响应格式无效');
    }
    return Map<String, dynamic>.from(decoded);
  }

  List<ProviderModelCatalogEntry> _modelsFromList(
    Object? raw, {
    required List<String> idFields,
    List<String> nameFields = const <String>['name', 'display_name'],
  }) {
    if (raw is! List) {
      throw const FormatException('Provider 模型列表响应缺少模型数组');
    }
    final models = <ProviderModelCatalogEntry>[];
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final metadata = Map<String, dynamic>.from(item);
      final id = _firstValue(metadata, idFields);
      if (id.isEmpty) {
        continue;
      }
      final name = _firstValue(metadata, nameFields);
      models.add(
        ProviderModelCatalogEntry(
          id: id,
          name: name.isEmpty ? id : name,
          metadata: metadata,
        ),
      );
    }
    return models;
  }

  String _firstValue(Map<String, dynamic> item, List<String> fields) {
    for (final field in fields) {
      final value = item[field]?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _normalizeProvider(String provider) {
    final normalized = provider.trim().toLowerCase();
    return normalized == 'anthropic' ? 'claude' : normalized;
  }

  Uri _normalizeBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const ProviderModelCatalogException('请填写有效的 Provider Base URL');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.fragment.isNotEmpty) {
      throw const ProviderModelCatalogException(
        'Provider Base URL 不能包含凭据、查询或片段',
      );
    }
    if (uri.scheme != 'https' && !_isLoopbackHttp(uri)) {
      throw const ProviderModelCatalogException(
        'Provider Base URL 必须使用 HTTPS；仅 localhost 可使用 HTTP',
      );
    }
    final path = uri.path == '/'
        ? ''
        : uri.path.replaceFirst(RegExp(r'/$'), '');
    return uri.replace(path: path);
  }

  bool _isLoopbackHttp(Uri uri) {
    if (uri.scheme != 'http') {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  Uri _openAiModelsUri(Uri base) {
    var segments = List<String>.of(base.pathSegments);
    if (_endsWith(segments, const <String>['chat', 'completions'])) {
      segments = segments.sublist(0, segments.length - 2);
    } else if (segments.isNotEmpty &&
        (segments.last == 'responses' || segments.last == 'models')) {
      if (segments.last == 'models') {
        return base;
      }
      segments = segments.sublist(0, segments.length - 1);
    }
    return base.replace(pathSegments: <String>[...segments, 'models']);
  }

  Uri _ollamaModelsUri(Uri base) {
    final segments = List<String>.of(base.pathSegments);
    if (_endsWith(segments, const <String>['api', 'tags'])) {
      return base;
    }
    if (segments.isNotEmpty && segments.last == 'api') {
      return base.replace(pathSegments: <String>[...segments, 'tags']);
    }
    return base.replace(pathSegments: <String>[...segments, 'api', 'tags']);
  }

  Uri _anthropicModelsUri(Uri base) {
    final segments = List<String>.of(base.pathSegments);
    if (_endsWith(segments, const <String>['v1', 'models'])) {
      return base;
    }
    if (segments.isNotEmpty && segments.last == 'v1') {
      return base.replace(pathSegments: <String>[...segments, 'models']);
    }
    return base.replace(pathSegments: <String>[...segments, 'v1', 'models']);
  }

  Uri _geminiModelsUri(Uri base) {
    final segments = List<String>.of(base.pathSegments);
    if (segments.isNotEmpty && segments.last == 'models') {
      return base;
    }
    if (segments.isNotEmpty &&
        (segments.last == 'v1' || segments.last == 'v1beta')) {
      return base.replace(pathSegments: <String>[...segments, 'models']);
    }
    return base.replace(
      pathSegments: <String>[...segments, 'v1beta', 'models'],
    );
  }

  bool _endsWith(List<String> value, List<String> suffix) {
    if (suffix.length > value.length) {
      return false;
    }
    final offset = value.length - suffix.length;
    for (var index = 0; index < suffix.length; index++) {
      if (value[offset + index] != suffix[index]) {
        return false;
      }
    }
    return true;
  }

  Map<String, String> _bearerHeaders(String apiKey) => <String, String>{
    HttpHeaders.acceptHeader: 'application/json',
    if (apiKey.trim().isNotEmpty)
      HttpHeaders.authorizationHeader: 'Bearer ${apiKey.trim()}',
  };

  String _statusMessage(int statusCode) => switch (statusCode) {
    401 || 403 => 'Provider 认证失败（HTTP $statusCode）',
    404 => 'Provider 不提供该模型列表接口（HTTP 404）',
    429 => 'Provider 模型列表请求过于频繁（HTTP 429）',
    _ => 'Provider 模型列表请求失败（HTTP $statusCode）',
  };
}
