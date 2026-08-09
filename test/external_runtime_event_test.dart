import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/services/runtime/external_runtime_event.dart';

void main() {
  group('ExternalRuntimeEvent', () {
    test('parses the declared initiative timer triggered payload', () {
      final event = ExternalRuntimeEvent.fromJson(<String, dynamic>{
        'type': 'initiative_timer.triggered',
        'id': 'event-1',
        'source': 'initiative_timer',
        'timestamp': '2026-07-14T12:30:00Z',
        'data': <String, dynamic>{
          'timer_id': 'timer-1',
          'generation': 4,
          'status': 'triggered',
          'pending_summary': 'Follow up',
          'source': 'timer',
        },
      });

      expect(event.requestsConversationReconciliation, isTrue);
      expect(event.timerId, 'timer-1');
      expect(event.timerGeneration, 4);
      expect(event.timerStatus, 'triggered');
      expect(event.timestamp, DateTime.utc(2026, 7, 14, 12, 30));
    });

    test('parses stable event store fields with legacy fallbacks', () {
      final event = ExternalRuntimeEvent.fromJson(<String, dynamic>{
        'type': 'message.sent',
        'id': 'legacy-id',
        'event_id': 'stable-id',
        'sequence': '42',
        'timestamp': '2026-08-08T01:00:00Z',
        'recorded_at': '2026-08-08T01:00:01Z',
      });

      expect(event.id, 'legacy-id');
      expect(event.eventId, 'stable-id');
      expect(event.sequence, 42);
      expect(event.recordedAt, DateTime.utc(2026, 8, 8, 1, 0, 1));

      final legacy = ExternalRuntimeEvent.fromJson(<String, dynamic>{
        'id': 'legacy-only',
        'timestamp': '2026-08-08T02:00:00Z',
      });
      expect(legacy.eventId, 'legacy-only');
      expect(legacy.recordedAt, legacy.timestamp);
    });

    test(
      'does not treat undeclared message.sent as an initiative contract',
      () {
        final event = ExternalRuntimeEvent.fromJson(<String, dynamic>{
          'type': 'message.sent',
          'id': 'event-2',
          'source': 'initiative_timer',
          'data': <String, dynamic>{'content': 'Hello', 'initiative': true},
        });

        expect(event.requestsConversationReconciliation, isFalse);
      },
    );

    test('requires the declared triggered payload fields', () {
      final event = ExternalRuntimeEvent.fromJson(<String, dynamic>{
        'type': 'initiative_timer.triggered',
        'id': 'event-3',
        'data': <String, dynamic>{'timer_id': 'timer-1'},
      });

      expect(event.requestsConversationReconciliation, isFalse);
    });

    test('requires the triggered timer status', () {
      final event = ExternalRuntimeEvent.fromJson(<String, dynamic>{
        'type': 'initiative_timer.triggered',
        'id': 'event-4',
        'data': <String, dynamic>{
          'timer_id': 'timer-1',
          'generation': 4,
          'status': 'scheduled',
        },
      });

      expect(event.requestsConversationReconciliation, isFalse);
    });
  });

  group('ExternalRuntimeEventDeduplicator', () {
    const first = ExternalRuntimeEvent(
      type: 'initiative_timer.triggered',
      id: 'first',
      source: 'initiative_timer',
      timestamp: null,
    );
    const second = ExternalRuntimeEvent(
      type: 'initiative_timer.triggered',
      id: 'second',
      source: 'initiative_timer',
      timestamp: null,
    );

    test('does not mark an event handled before commit', () {
      final deduplicator = ExternalRuntimeEventDeduplicator();

      expect(deduplicator.wasHandled(first, 1), isFalse);
      expect(deduplicator.wasHandled(first, 1), isFalse);
      deduplicator.commit(first, 1);
      expect(deduplicator.wasHandled(first, 1), isTrue);
    });

    test('scopes ids to a connection generation', () {
      final deduplicator = ExternalRuntimeEventDeduplicator();

      deduplicator.commit(first, 1);
      expect(deduplicator.wasHandled(first, 1), isTrue);
      expect(deduplicator.wasHandled(first, 2), isFalse);
    });

    test('bounds committed ids and evicts the oldest', () {
      final deduplicator = ExternalRuntimeEventDeduplicator(maxEntries: 1);

      deduplicator.commit(first, 1);
      deduplicator.commit(second, 1);

      expect(deduplicator.length, 1);
      expect(deduplicator.wasHandled(first, 1), isFalse);
      expect(deduplicator.wasHandled(second, 1), isTrue);
    });
  });
}
