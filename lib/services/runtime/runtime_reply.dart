import '../../models/runtime_capabilities.dart';

class RuntimeReply {
  const RuntimeReply({
    required this.content,
    this.thoughtSummary = '',
    this.reasoningContent = '',
    this.toolEvents = const <Map<String, dynamic>>[],
    this.memoryPatches = const <Map<String, dynamic>>[],
    this.capabilityLosses = const <CapabilityLoss>[],
    this.metadata = const <String, dynamic>{},
  });

  final String content;
  final String thoughtSummary;
  final String reasoningContent;
  final List<Map<String, dynamic>> toolEvents;
  final List<Map<String, dynamic>> memoryPatches;
  final List<CapabilityLoss> capabilityLosses;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'content': content,
      'thought_summary': thoughtSummary,
      'reasoning_content': reasoningContent,
      'tool_events': toolEvents,
      'memory_patches': memoryPatches,
      'capability_losses': capabilityLosses
          .map((item) => item.toJson())
          .toList(),
      'metadata': metadata,
    }..removeWhere((_, value) => value == null || value == '');
  }

  factory RuntimeReply.fromJson(Map<String, dynamic> json) {
    return RuntimeReply(
      content: json['content']?.toString() ?? '',
      thoughtSummary: json['thought_summary']?.toString() ?? '',
      reasoningContent: json['reasoning_content'] is String
          ? json['reasoning_content'] as String
          : '',
      toolEvents: _mapListFromJson(json['tool_events']),
      memoryPatches: _mapListFromJson(json['memory_patches']),
      capabilityLosses: _capabilityLossesFromJson(json['capability_losses']),
      metadata: _mapFromJson(json['metadata']),
    );
  }
}

Map<String, dynamic> _mapFromJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

List<Map<String, dynamic>> _mapListFromJson(Object? value) {
  if (value is! List) {
    return const <Map<String, dynamic>>[];
  }
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

List<CapabilityLoss> _capabilityLossesFromJson(Object? value) {
  if (value is! List) {
    return const <CapabilityLoss>[];
  }
  return value
      .whereType<Map>()
      .map((item) => CapabilityLoss.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}
