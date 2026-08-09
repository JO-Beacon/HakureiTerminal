import '../../models/runtime_capabilities.dart';
import 'runtime_reply.dart';

sealed class RuntimeStreamEvent {
  const RuntimeStreamEvent({this.metadata = const <String, dynamic>{}});

  final Map<String, dynamic> metadata;
}

class RuntimeStreamStarted extends RuntimeStreamEvent {
  const RuntimeStreamStarted({super.metadata});
}

class RuntimeStreamDelta extends RuntimeStreamEvent {
  const RuntimeStreamDelta(this.text, {super.metadata});

  final String text;
}

class RuntimeStreamReasoningDelta extends RuntimeStreamEvent {
  const RuntimeStreamReasoningDelta(this.text, {super.metadata});

  final String text;
}

class RuntimeStreamToolUpdate extends RuntimeStreamEvent {
  const RuntimeStreamToolUpdate(this.info, {super.metadata});

  final Map<String, dynamic> info;
}

class RuntimeStreamCompleted extends RuntimeStreamEvent {
  const RuntimeStreamCompleted(this.reply, {super.metadata});

  final RuntimeReply reply;
}

class RuntimeStreamFailed extends RuntimeStreamEvent {
  const RuntimeStreamFailed({
    required this.message,
    this.partialContent = '',
    this.partialReasoning = '',
    this.toolEvents = const <Map<String, dynamic>>[],
    this.capabilityLosses = const <CapabilityLoss>[],
    super.metadata,
  });

  final String message;
  final String partialContent;
  final String partialReasoning;
  final List<Map<String, dynamic>> toolEvents;
  final List<CapabilityLoss> capabilityLosses;
}

class RuntimeStreamCancelled extends RuntimeStreamEvent {
  const RuntimeStreamCancelled({
    this.partialContent = '',
    this.partialReasoning = '',
    this.toolEvents = const <Map<String, dynamic>>[],
    super.metadata,
  });

  final String partialContent;
  final String partialReasoning;
  final List<Map<String, dynamic>> toolEvents;
}
