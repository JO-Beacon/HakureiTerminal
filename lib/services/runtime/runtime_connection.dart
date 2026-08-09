import 'dart:io';

class RuntimeEndpointPolicy {
  const RuntimeEndpointPolicy();

  Uri normalize(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('Runtime URL is invalid');
    }
    if (uri.userInfo.isNotEmpty || uri.queryParameters.isNotEmpty) {
      throw const FormatException(
        'Runtime URL must not contain credentials or a query',
      );
    }
    if (uri.scheme != 'https' && !_isAllowedLocalHttp(uri)) {
      throw const FormatException('Runtime URL must use HTTPS');
    }
    return uri.replace(path: _normalizedBasePath(uri.path));
  }

  Uri rpcUri(String baseUrl) => _endpoint(baseUrl, 'rpc');
  Uri healthUri(String baseUrl) => _endpoint(baseUrl, 'health');
  Uri readinessUri(String baseUrl) => _endpoint(baseUrl, 'ready');
  Uri infoUri(String baseUrl) => _endpoint(baseUrl, 'info');

  Uri mediaUploadUri(String baseUrl, String agentId) => _endpoint(
    baseUrl,
    'media',
  ).replace(queryParameters: <String, String>{'agent_id': agentId});

  Uri mediaDownloadUri(String baseUrl, String agentId, String mediaId) {
    final base = normalize(baseUrl);
    final prefix = base.path.isEmpty ? '' : base.path;
    return base.replace(
      path:
          '$prefix/media/${Uri.encodeComponent(agentId)}/${Uri.encodeComponent(mediaId)}',
    );
  }

  Uri characterPackagesUri(
    String baseUrl, {
    String? locale,
    bool overwrite = false,
    bool allowUntrusted = false,
  }) => _endpoint(baseUrl, 'character-packages').replace(
    queryParameters: <String, String>{
      if (locale != null && locale.trim().isNotEmpty) 'locale': locale.trim(),
      if (overwrite) 'overwrite': 'true',
      if (allowUntrusted) 'allow_untrusted': 'true',
    },
  );

  Uri webSocketUri(String baseUrl) {
    final endpoint = _endpoint(baseUrl, 'ws');
    return endpoint.replace(scheme: endpoint.scheme == 'https' ? 'wss' : 'ws');
  }

  Uri _endpoint(String baseUrl, String segment) {
    final base = normalize(baseUrl);
    final path = base.path.isEmpty ? '/$segment' : '${base.path}/$segment';
    return base.replace(path: path);
  }

  bool _isAllowedLocalHttp(Uri uri) {
    if (uri.scheme != 'http') {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  String _normalizedBasePath(String path) {
    if (path.isEmpty || path == '/') {
      return '';
    }
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }
}

class RuntimeConnectionException implements Exception {
  const RuntimeConnectionException(
    this.kind, {
    this.statusCode,
    this.code,
    this.recoverable = false,
  });

  final String kind;
  final int? statusCode;
  final String? code;
  final bool recoverable;

  @override
  String toString() => kind;
}

Map<String, String> runtimeAuthorizationHeaders(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) {
    return const <String, String>{};
  }
  return <String, String>{HttpHeaders.authorizationHeader: 'Bearer $trimmed'};
}
