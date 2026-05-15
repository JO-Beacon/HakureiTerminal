class ChatSession {
  const ChatSession({
    required this.sessionId,
    required this.characterId,
    required this.totalTurns,
    this.createdAt,
    this.lastActive,
  });

  final String sessionId;
  final String characterId;
  final int totalTurns;
  final DateTime? createdAt;
  final DateTime? lastActive;

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      sessionId: json['session_id']?.toString() ?? '',
      characterId: json['character_id']?.toString() ?? '',
      totalTurns: int.tryParse(json['total_turns']?.toString() ?? '') ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      lastActive: DateTime.tryParse(json['last_active']?.toString() ?? ''),
    );
  }
}
