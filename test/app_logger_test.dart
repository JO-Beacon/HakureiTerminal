import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/services/app_logger.dart';
import 'package:archive/archive.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hakurei_logger_test_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('writes valid ordered JSONL while redacting sensitive data', () async {
    final logger = AppLogger(clock: () => DateTime.utc(2026, 8, 15, 1, 2, 3));
    await logger.initialize(directory);

    for (var index = 0; index < 20; index++) {
      logger.info(
        'runtime.rpc.succeeded',
        component: 'runtime',
        data: <String, Object?>{
          'index': index,
          'url': Uri.parse(
            'https://user:password@example.com/rpc?token=runtime-secret',
          ),
          'authorization': 'Bearer runtime-secret',
          'api_key': 'sk-super-secret-key',
          'content': 'private conversation',
        },
      );
    }
    logger.error(
      'runtime.websocket.failed',
      component: 'runtime',
      error: 'Handshake failed with Bearer runtime-secret',
    );
    logger.error(
      'runtime.invalid_json',
      component: 'runtime',
      error: const FormatException(
        'Invalid JSON',
        'api-key-hidden-in-source',
        0,
      ),
    );
    await logger.flush();

    final lines = await logger.activeFile!.readAsLines();
    final entries = lines
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList(growable: false);
    expect(entries, hasLength(23));
    expect(
      entries.map((entry) => entry['sequence']),
      orderedEquals(List<int>.generate(23, (index) => index + 1)),
    );
    final serialized = lines.join('\n');
    expect(serialized, isNot(contains('runtime-secret')));
    expect(serialized, isNot(contains('super-secret')));
    expect(serialized, isNot(contains('private conversation')));
    expect(serialized, isNot(contains('hidden-in-source')));
    expect(serialized, isNot(contains('user:password')));
    expect(serialized, isNot(contains('?token=')));
    expect(serialized, contains('[REDACTED]'));
  });

  test('rotates logs and enforces the configured file limit', () async {
    final logger = AppLogger(maxFileBytes: 320, maxFiles: 3);
    await logger.initialize(directory);

    for (var index = 0; index < 30; index++) {
      logger.info(
        'rotation.event',
        component: 'test',
        data: <String, Object?>{'index': index, 'detail': 'x' * 80},
      );
    }
    await logger.flush();

    final files = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.log'))
        .toList(growable: false);
    expect(files.length, 3);
    expect(
      files.map((file) => file.uri.pathSegments.last),
      containsAll(<String>[
        'hakurei-terminal.log',
        'hakurei-terminal.1.log',
        'hakurei-terminal.2.log',
      ]),
    );
  });

  test('clears existing logs and resumes with a clear audit event', () async {
    final logger = AppLogger();
    await logger.initialize(directory);
    logger.info('before.clear', component: 'test');
    await logger.flush();

    final result = await logger.clearLogs();

    expect(result.deleted, 1);
    expect(result.failed, 0);
    final entries = await logger.activeFile!.readAsLines();
    expect(entries, hasLength(1));
    expect(entries.single, contains('logs.cleared'));
  });

  test('exports only logs and a diagnostics manifest', () async {
    final logger = AppLogger();
    await logger.initialize(directory);
    logger.info('export.fixture', component: 'test');
    await logger.flush();
    final output = File(
      '${directory.path}${Platform.pathSeparator}diagnostics.zip',
    );

    await logger.exportLogsToFile(output);

    final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
    expect(
      archive.files.map((file) => file.name),
      containsAll(<String>['manifest.json', 'logs/hakurei-terminal.log']),
    );
    expect(
      archive.files.every(
        (file) =>
            file.name == 'manifest.json' ||
            (file.name.startsWith('logs/') && file.name.endsWith('.log')),
      ),
      isTrue,
    );
  });

  test('isolates log file write failures from callers', () async {
    final logger = AppLogger();
    await logger.initialize(directory);
    final activeFile = logger.activeFile!;
    await activeFile.delete();
    await Directory(activeFile.path).create();

    logger.info('write.failure.fixture', component: 'test');

    await expectLater(logger.flush(), completes);
  });
}
