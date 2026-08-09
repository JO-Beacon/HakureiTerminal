import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/models/app_settings.dart';
import 'package:hakurei_terminal/services/runtime/external_agent_runtime.dart';
import 'package:hakurei_terminal/services/runtime/http_runtime_client.dart';

void main() {
  test('management facade reads every session.list cursor page', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = GensokyoAiHttpRuntimeClient(
      connection: ExternalRuntimeConnectionSettings(
        id: 'runtime',
        agentId: 'agent-runtime',
        displayName: 'Fixture',
        baseUrl: 'http://127.0.0.1:${server.port}',
      ),
    );
    addTearDown(() async {
      await client.dispose();
      await server.close(force: true);
    });
    var requestCount = 0;
    unawaited(() async {
      await for (final request in server) {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['method'], 'session.list');
        expect((body['params'] as Map)['limit'], 200);
        if (requestCount == 0) {
          expect((body['params'] as Map).containsKey('cursor'), isFalse);
        } else {
          expect((body['params'] as Map)['cursor'], 'page-2');
        }
        final result = requestCount++ == 0
            ? <String, dynamic>{
                'sessions': <Map<String, dynamic>>[
                  <String, dynamic>{'session_id': 'wrapped'},
                ],
                'has_more': true,
                'next_cursor': 'page-2',
              }
            : <String, dynamic>{
                'sessions': <Map<String, dynamic>>[
                  <String, dynamic>{'session_id': 'second'},
                ],
                'has_more': false,
              };
        request.response.write(
          jsonEncode(<String, dynamic>{
            'id': body['id'],
            'ok': true,
            'result': result,
          }),
        );
        await request.response.close();
      }
    }());

    final runtime = GensokyoAiHttpRuntimeFacade(client);
    final sessions = await runtime.listSessions();
    expect(sessions.map((session) => session['session_id']), <String>[
      'wrapped',
      'second',
    ]);
    expect(requestCount, 2);
  });

  test(
    'management facade forwards Runtime 2.2 memory and timer fields',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = GensokyoAiHttpRuntimeClient(
        connection: ExternalRuntimeConnectionSettings(
          id: 'runtime',
          agentId: 'agent-runtime',
          displayName: 'Fixture',
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      addTearDown(() async {
        await client.dispose();
        await server.close(force: true);
      });
      final requests = <Map>[];
      unawaited(() async {
        await for (final request in server) {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          requests.add(body);
          final method = body['method'];
          final result = method == 'agent.init'
              ? <String, dynamic>{
                  'agent_id': 'agent-runtime',
                  'session': <String, dynamic>{
                    'session_id': 'session-runtime',
                    'revision': 1,
                  },
                }
              : <String, dynamic>{'ok': true, 'enabled': false};
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': body['id'],
              'ok': true,
              'result': result,
            }),
          );
          await request.response.close();
        }
      }());

      await client.initialize(characterId: 'reimu');
      final runtime = GensokyoAiHttpRuntimeFacade(client);
      await runtime.addMemory(
        'likes tea',
        topicName: 'preferences',
        importance: 0.8,
        emotionalValence: 0.2,
      );
      await runtime.updateInitiativeTimer(enabled: false);

      expect(requests[1]['method'], 'memory.add');
      expect(
        requests[1]['params'],
        containsPair('session_id', 'session-runtime'),
      );
      expect(requests[1]['params'], containsPair('content', 'likes tea'));
      expect(requests[1]['params'], containsPair('topic_name', 'preferences'));
      expect(requests[1]['params'], containsPair('importance', 0.8));
      expect(requests[1]['params'], containsPair('emotional_valence', 0.2));
      expect(requests[2]['method'], 'initiative_timer.update');
      expect(requests[2]['params'], containsPair('enabled', false));
    },
  );
}
