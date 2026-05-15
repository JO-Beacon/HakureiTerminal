import 'dart:async';
import 'dart:convert';
import 'dart:io';

class PythonBridgeException implements Exception {
  const PythonBridgeException(
    this.message, {
    this.type,
    this.code,
    this.details,
    this.recoverable = false,
  });

  final String message;
  final String? type;
  final String? code;
  final Map<String, dynamic>? details;
  final bool recoverable;

  @override
  String toString() {
    if (type == null || type!.isEmpty) {
      return 'PythonBridgeException: $message';
    }
    return 'PythonBridgeException($type): $message';
  }
}

class _PendingRequest {
  _PendingRequest(this.completer, this.timer);

  final Completer<dynamic> completer;
  final Timer timer;
}

class PythonBridge {
  PythonBridge({
    String? pythonExecutable,
    String? bridgeRoot,
    Duration requestTimeout = const Duration(seconds: 90),
  }) : _pythonExecutable = pythonExecutable,
       _bridgeRoot = bridgeRoot,
       _requestTimeout = requestTimeout;

  final String? _pythonExecutable;
  final String? _bridgeRoot;
  final Duration _requestTimeout;

  Process? _process;
  int _nextRequestId = 1;
  final Map<int, _PendingRequest> _pending = <int, _PendingRequest>{};
  final StreamController<String> _stderrController =
      StreamController<String>.broadcast();

  Stream<String> get stderr => _stderrController.stream;

  bool get isRunning => _process != null;

  Future<void> start() async {
    if (_process != null) {
      return;
    }

    final bridgeRoot = _resolveBridgeRoot();
    final executable = _resolvePythonExecutable(bridgeRoot);
    final bridgeMain = _resolveBridgeMain(bridgeRoot);

    final backendDir = _resolveBackendDir(bridgeRoot);

    final process = await Process.start(
      executable,
      <String>[
        bridgeMain.path,
        '--root', bridgeRoot.path,
        '--backend-dir', backendDir.path,
      ],
      workingDirectory: bridgeRoot.path,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );

    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleStdoutLine,
          onError: _handleProcessError,
          onDone: _handleProcessExit,
        );
    process.stderr
        .transform(utf8.decoder)
        .listen(_stderrController.add, onError: _stderrController.addError);
    process.exitCode.then((code) {
      _failAll(PythonBridgeException('Python bridge exited with code $code'));
      _process = null;
    });
  }

  Future<dynamic> call(
    String method, {
    Map<String, dynamic> params = const <String, dynamic>{},
  }) async {
    await start();
    final process = _process;
    if (process == null) {
      throw const PythonBridgeException('Python bridge is not running');
    }

    final id = _nextRequestId++;
    final completer = Completer<dynamic>();
    final timer = Timer(_requestTimeout, () {
      final pending = _pending.remove(id);
      pending?.completer.completeError(
        PythonBridgeException('Request timed out: $method'),
      );
    });
    _pending[id] = _PendingRequest(completer, timer);

    final request = <String, dynamic>{
      'id': id,
      'method': method,
      'params': params,
    };
    process.stdin.writeln(jsonEncode(request));
    await process.stdin.flush();
    return completer.future;
  }

  Future<void> stop() async {
    if (_process == null) {
      return;
    }
    try {
      await call('shutdown').timeout(const Duration(seconds: 5));
    } catch (_) {
      _process?.kill();
    } finally {
      _process = null;
      _failAll(const PythonBridgeException('Python bridge stopped'));
    }
  }

  void dispose() {
    unawaited(stop());
    unawaited(_stderrController.close());
  }

  void _handleStdoutLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Bridge response is not an object');
      }
      final id = decoded['id'];
      if (id is! int) {
        throw const FormatException('Bridge response id is not an int');
      }
      final pending = _pending.remove(id);
      if (pending == null) {
        return;
      }
      pending.timer.cancel();

      if (decoded['ok'] == true) {
        pending.completer.complete(decoded['result']);
      } else {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          pending.completer.completeError(
            PythonBridgeException(
              error['message']?.toString() ?? 'Unknown bridge error',
              type: error['type']?.toString(),
              code: error['code']?.toString(),
              details: error['details'] is Map
                  ? Map<String, dynamic>.from(error['details'] as Map)
                  : null,
              recoverable: error['recoverable'] == true,
            ),
          );
        } else {
          pending.completer.completeError(
            const PythonBridgeException('Unknown bridge error'),
          );
        }
      }
    } catch (error) {
      _stderrController.add('Invalid bridge stdout: $line\n$error');
    }
  }

  void _handleProcessError(Object error) {
    _failAll(PythonBridgeException(error.toString()));
  }

  void _handleProcessExit() {
    _failAll(const PythonBridgeException('Python bridge stdout closed'));
  }

  void _failAll(Object error) {
    final pending = Map<int, _PendingRequest>.from(_pending);
    _pending.clear();
    for (final request in pending.values) {
      request.timer.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
  }

  Directory _resolveBridgeRoot() {
    final configuredBridgeRoot = _bridgeRoot;
    if (configuredBridgeRoot != null && configuredBridgeRoot.isNotEmpty) {
      return Directory(configuredBridgeRoot).absolute;
    }

    final fromDefine = const String.fromEnvironment('HAKUREI_PYTHON_ROOT');
    if (fromDefine.isNotEmpty) {
      return Directory(fromDefine).absolute;
    }

    if (Platform.environment['HAKUREI_PYTHON_ROOT'] case final envRoot?) {
      if (envRoot.isNotEmpty) {
        return Directory(envRoot).absolute;
      }
    }

    if (Platform.resolvedExecutable.isNotEmpty) {
      final executableDir = File(Platform.resolvedExecutable).parent;
      final bundled = Directory(
        '${executableDir.path}${Platform.pathSeparator}python',
      );
      if (bundled.existsSync()) {
        return bundled.absolute;
      }
    }

    final current = Directory.current;
    final devRoot = Directory(
      '${current.parent.path}${Platform.pathSeparator}',
    );
    if (File(
      '${devRoot.path}${Platform.pathSeparator}bridge_main.py',
    ).existsSync()) {
      return devRoot.absolute;
    }
    if (File(
      '${current.path}${Platform.pathSeparator}bridge_main.py',
    ).existsSync()) {
      return current.absolute;
    }

    throw const PythonBridgeException(
      'Cannot locate Python bridge root. Set HAKUREI_PYTHON_ROOT for development.',
    );
  }

  String _resolvePythonExecutable(Directory bridgeRoot) {
    final configuredPythonExecutable = _pythonExecutable;
    if (configuredPythonExecutable != null &&
        configuredPythonExecutable.isNotEmpty) {
      return configuredPythonExecutable;
    }

    final fromDefine = const String.fromEnvironment(
      'HAKUREI_PYTHON_EXECUTABLE',
    );
    if (fromDefine.isNotEmpty) {
      return fromDefine;
    }

    if (Platform.environment['HAKUREI_PYTHON_EXECUTABLE']
        case final envPython?) {
      if (envPython.isNotEmpty) {
        return envPython;
      }
    }

    final bundledCandidates = <File>[
      if (Platform.isWindows)
        File(
          '${bridgeRoot.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}python.exe',
        ),
      if (!Platform.isWindows)
        File(
          '${bridgeRoot.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}bin${Platform.pathSeparator}python3',
        ),
      if (!Platform.isWindows)
        File(
          '${bridgeRoot.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}bin${Platform.pathSeparator}python',
        ),
    ];
    for (final candidate in bundledCandidates) {
      if (candidate.existsSync()) {
        return candidate.path;
      }
    }

    assert(() {
      return true;
    }());

    // Development fallback only. Release packaging must provide a bundled runtime
    // or an explicit HAKUREI_PYTHON_EXECUTABLE path.
    return Platform.isWindows ? 'python' : 'python3';
  }

  File _resolveBridgeMain(Directory bridgeRoot) {
    final bridgeMain = File(
      '${bridgeRoot.path}${Platform.pathSeparator}bridge_main.py',
    );
    if (!bridgeMain.existsSync()) {
      throw PythonBridgeException(
        'Cannot find bridge_main.py at ${bridgeMain.path}',
      );
    }
    return bridgeMain;
  }

  Directory _resolveBackendDir(Directory bridgeRoot) {
    final bundledBackend = Directory(
      '${bridgeRoot.path}${Platform.pathSeparator}GensokyoAI',
    );
    if (bundledBackend.existsSync()) {
      return bridgeRoot;
    }

    final sourceBackend = Directory(
      '${bridgeRoot.path}${Platform.pathSeparator}backend',
    );
    if (sourceBackend.existsSync()) {
      return sourceBackend;
    }

    throw PythonBridgeException(
      'Cannot locate embedded GensokyoAI backend under ${bridgeRoot.path}',
    );
  }
}
