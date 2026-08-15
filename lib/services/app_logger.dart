import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';

enum AppLogLevel { debug, info, warning, error }

class AppLogClearResult {
  const AppLogClearResult({required this.deleted, required this.failed});

  final int deleted;
  final int failed;
}

class AppLogger {
  AppLogger({
    int maxFileBytes = 2 * 1024 * 1024,
    int maxFiles = 5,
    DateTime Function()? clock,
  }) : assert(maxFileBytes > 0),
       assert(maxFiles > 0),
       _maxFileBytes = maxFileBytes,
       _maxFiles = maxFiles,
       _clock = clock ?? DateTime.now;

  static final AppLogger instance = AppLogger();

  final int _maxFileBytes;
  final int _maxFiles;
  final DateTime Function() _clock;
  final String _logSession =
      '${DateTime.now().toUtc().microsecondsSinceEpoch}-$pid';
  Directory? _directory;
  Future<void> _writeQueue = Future<void>.value();
  int _sequence = 0;

  bool get isInitialized => _directory != null;
  int get maxFileBytes => _maxFileBytes;
  int get maxFiles => _maxFiles;
  File? get activeFile {
    final directory = _directory;
    return directory == null
        ? null
        : File(
            '${directory.path}${Platform.pathSeparator}hakurei-terminal.log',
          );
  }

  Future<void> initialize(Directory directory) async {
    await _schedule(() async {
      await directory.create(recursive: true);
      _directory = directory;
    });
    info(
      'logger.initialized',
      component: 'logging',
      data: <String, Object?>{
        'max_file_bytes': _maxFileBytes,
        'max_files': _maxFiles,
      },
    );
    await flush();
  }

  void debug(
    String event, {
    required String component,
    Map<String, Object?> data = const <String, Object?>{},
  }) => _record(AppLogLevel.debug, event, component: component, data: data);

  void info(
    String event, {
    required String component,
    Map<String, Object?> data = const <String, Object?>{},
  }) => _record(AppLogLevel.info, event, component: component, data: data);

  void warning(
    String event, {
    required String component,
    Map<String, Object?> data = const <String, Object?>{},
    Object? error,
  }) => _record(
    AppLogLevel.warning,
    event,
    component: component,
    data: data,
    error: error,
  );

  void error(
    String event, {
    required String component,
    Map<String, Object?> data = const <String, Object?>{},
    Object? error,
  }) => _record(
    AppLogLevel.error,
    event,
    component: component,
    data: data,
    error: error,
  );

  Future<T> trace<T>(
    String event, {
    required String component,
    Map<String, Object?> data = const <String, Object?>{},
    required Future<T> Function() operation,
  }) async {
    final stopwatch = Stopwatch()..start();
    debug('$event.started', component: component, data: data);
    try {
      final result = await operation();
      info(
        '$event.succeeded',
        component: component,
        data: <String, Object?>{
          ...data,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
      );
      return result;
    } catch (exception) {
      error(
        '$event.failed',
        component: component,
        data: <String, Object?>{
          ...data,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
        error: exception,
      );
      rethrow;
    }
  }

  Future<void> flush() => _writeQueue;

  Future<AppLogClearResult> clearLogs({Directory? directory}) async {
    await flush();
    var deleted = 0;
    var failed = 0;
    await _schedule(() async {
      final targetDirectory = directory ?? _directory;
      if (targetDirectory == null || !await targetDirectory.exists()) return;
      await for (final entity in targetDirectory.list(recursive: true)) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.log')) {
          continue;
        }
        try {
          await entity.delete();
          deleted++;
        } on FileSystemException {
          failed++;
        }
      }
    });
    info(
      'logs.cleared',
      component: 'logging',
      data: <String, Object?>{'deleted': deleted, 'failed': failed},
    );
    await flush();
    return AppLogClearResult(deleted: deleted, failed: failed);
  }

  Future<File> exportLogsToFile(
    File output, {
    Directory? sourceDirectory,
  }) async {
    info('logs.export_requested', component: 'logging');
    await flush();
    try {
      final directory = sourceDirectory ?? _directory;
      if (directory == null || !await directory.exists()) {
        throw const FileSystemException('Log directory is unavailable');
      }
      final files = <File>[];
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.log')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      final archive = Archive();
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final name = file.uri.pathSegments.last;
        archive.addFile(ArchiveFile('logs/$name', bytes.length, bytes));
      }
      final manifestBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'format': 'hakurei-terminal-diagnostics',
          'format_version': 1,
          'redaction':
              'Credentials, message bodies, prompts, and URL queries are excluded.',
        }),
      );
      archive.addFile(
        ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
      );
      final encoded = ZipEncoder().encode(archive);
      await output.parent.create(recursive: true);
      await output.writeAsBytes(encoded, flush: true);
      info(
        'logs.export_succeeded',
        component: 'logging',
        data: <String, Object?>{
          'file_count': files.length,
          'archive_bytes': encoded.length,
        },
      );
      await flush();
      return output;
    } catch (error) {
      this.error('logs.export_failed', component: 'logging', error: error);
      await flush();
      rethrow;
    }
  }

  String reference(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return '';
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 12);
  }

  String safeUri(Object? value) {
    final raw = value?.toString().trim() ?? '';
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return _sanitizeString(raw);
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  void _record(
    AppLogLevel level,
    String event, {
    required String component,
    required Map<String, Object?> data,
    Object? error,
  }) {
    if (_directory == null) return;
    final sequence = ++_sequence;
    final entry = <String, Object?>{
      'schema_version': 1,
      'timestamp': _clock().toUtc().toIso8601String(),
      'level': level.name,
      'component': _sanitizeString(component),
      'event': _sanitizeString(event),
      'log_session': _logSession,
      'sequence': sequence,
      if (data.isNotEmpty) 'data': _sanitizeMap(data),
      if (error != null) 'error_type': error.runtimeType.toString(),
      if (error != null) 'error': _errorDescription(error),
    };
    final line = '${jsonEncode(entry)}\n';
    _schedule(() => _append(line));
  }

  Future<void> _append(String line) async {
    final file = activeFile;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final lineBytes = utf8.encode(line).length;
    if (await file.exists() &&
        await file.length() > 0 &&
        await file.length() + lineBytes > _maxFileBytes) {
      await _rotate(file);
    }
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<void> _rotate(File active) async {
    if (_maxFiles == 1) {
      if (await active.exists()) await active.delete();
      return;
    }
    final directory = active.parent.path;
    File rotated(int index) =>
        File('$directory${Platform.pathSeparator}hakurei-terminal.$index.log');
    final oldest = rotated(_maxFiles - 1);
    if (await oldest.exists()) await oldest.delete();
    for (var index = _maxFiles - 2; index >= 1; index--) {
      final source = rotated(index);
      if (await source.exists()) await source.rename(rotated(index + 1).path);
    }
    if (await active.exists()) await active.rename(rotated(1).path);
  }

  Future<void> _schedule(Future<void> Function() operation) {
    final completed = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await operation();
      } on Object {
        // Logging must never change application behavior.
      } finally {
        if (!completed.isCompleted) completed.complete();
      }
    });
    return completed.future;
  }

  Map<String, Object?> _sanitizeMap(Map<String, Object?> source) =>
      <String, Object?>{
        for (final entry in source.entries)
          entry.key: _isSensitiveKey(entry.key)
              ? '[REDACTED]'
              : _sanitizeValue(entry.value),
      };

  Object? _sanitizeValue(Object? value) => switch (value) {
    null || bool() || num() => value,
    String() => _sanitizeString(value),
    Uri() => safeUri(value),
    Map() => _sanitizeMap(<String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    }),
    Iterable() => value.map(_sanitizeValue).toList(growable: false),
    _ => _sanitizeString(value.toString()),
  };

  bool _isSensitiveKey(String key) {
    final normalized = key.toLowerCase().replaceAll('-', '_');
    return const <String>{
      'authorization',
      'auth_token',
      'runtime_token',
      'token',
      'api_key',
      'apikey',
      'password',
      'secret',
      'cookie',
      'set_cookie',
      'prompt',
      'input',
      'content',
      'message',
      'messages',
      'text',
      'body',
      'payload',
      'request_body',
      'response_body',
    }.contains(normalized);
  }

  String _sanitizeString(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      return safeUri(parsed);
    }
    var sanitized = value.replaceAllMapped(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      (_) => 'Bearer [REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'([?&](?:token|api_key|key|secret|password)=)[^&\s]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b'),
      (_) => '[REDACTED_API_KEY]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@'),
      (match) => '${match.group(1)}[REDACTED]@',
    );
    if (sanitized.length > 2048) {
      sanitized = '${sanitized.substring(0, 2048)}...[TRUNCATED]';
    }
    return sanitized;
  }

  String _errorDescription(Object error) {
    if (error is FormatException) return _sanitizeString(error.message);
    if (error is FileSystemException) {
      return _sanitizeString(
        '${error.message}${error.osError == null ? '' : ' (${error.osError!.errorCode})'}',
      );
    }
    if (error is SocketException) {
      return _sanitizeString(
        '${error.message}${error.osError == null ? '' : ' (${error.osError!.errorCode})'}',
      );
    }
    if (error is HttpException) return _sanitizeString(error.message);
    if (error is HandshakeException) return _sanitizeString(error.message);
    if (error is TlsException) return _sanitizeString(error.message);
    if (error is OSError) {
      return _sanitizeString('${error.message} (${error.errorCode})');
    }
    if (error is String) return _sanitizeString(error);
    if (const <String>{
      'RuntimeConnectionException',
      'ProviderModelCatalogException',
      'TtsServiceException',
    }.contains(error.runtimeType.toString())) {
      return _sanitizeString(error.toString());
    }
    return '[DETAILS_OMITTED]';
  }
}
