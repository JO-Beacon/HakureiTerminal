import 'dart:collection';

class ExternalRuntimeEvent {
  const ExternalRuntimeEvent({
    required this.type,
    required this.id,
    required this.source,
    required this.timestamp,
    this.eventId = '',
    this.sequence,
    this.recordedAt,
    this.data = const <String, dynamic>{},
    this.metadata = const <String, dynamic>{},
  });

  final String type;
  final String id;
  final String source;
  final DateTime? timestamp;
  final String eventId;
  final int? sequence;
  final DateTime? recordedAt;
  final Map<String, dynamic> data;
  final Map<String, dynamic> metadata;

  String get stableId => eventId.isNotEmpty ? eventId : id;

  bool get isBackpressureDrop => type == 'runtime.backpressure.dropped';

  bool get requestsConversationReconciliation =>
      type == 'initiative_timer.triggered' &&
      timerId.isNotEmpty &&
      timerGeneration != null &&
      timerStatus == 'triggered';

  String get timerId => data['timer_id']?.toString() ?? '';

  int? get timerGeneration => switch (data['generation']) {
    final int value => value,
    final String value => int.tryParse(value),
    _ => null,
  };

  String get timerStatus => data['status']?.toString() ?? '';

  factory ExternalRuntimeEvent.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final timestamp = DateTime.tryParse(json['timestamp']?.toString() ?? '');
    return ExternalRuntimeEvent(
      type: json['type']?.toString() ?? '',
      id: id,
      source: json['source']?.toString() ?? '',
      timestamp: timestamp,
      eventId: json['event_id']?.toString() ?? id,
      sequence: switch (json['sequence']) {
        final int value => value,
        final String value => int.tryParse(value),
        _ => null,
      },
      recordedAt:
          DateTime.tryParse(json['recorded_at']?.toString() ?? '') ?? timestamp,
      data: _eventMapFromJson(json['data']),
      metadata: _eventMapFromJson(json['metadata']),
    );
  }
}

class ExternalRuntimeEventDeduplicator {
  ExternalRuntimeEventDeduplicator({this.maxEntries = 256})
    : assert(maxEntries > 0);

  final int maxEntries;
  final LinkedHashSet<String> _handledIds = LinkedHashSet<String>();
  int? _connectionGeneration;

  int get length => _handledIds.length;

  bool wasHandled(ExternalRuntimeEvent event, int connectionGeneration) {
    _useGeneration(connectionGeneration);
    return event.stableId.isNotEmpty && _handledIds.contains(event.stableId);
  }

  void commit(ExternalRuntimeEvent event, int connectionGeneration) {
    _useGeneration(connectionGeneration);
    if (event.stableId.isEmpty || !_handledIds.add(event.stableId)) {
      return;
    }
    while (_handledIds.length > maxEntries) {
      _handledIds.remove(_handledIds.first);
    }
  }

  void reset() {
    _connectionGeneration = null;
    _handledIds.clear();
  }

  void _useGeneration(int connectionGeneration) {
    if (_connectionGeneration == connectionGeneration) {
      return;
    }
    _connectionGeneration = connectionGeneration;
    _handledIds.clear();
  }
}

Map<String, dynamic> _eventMapFromJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}
