class ChatCharacter {
  const ChatCharacter({
    required this.id,
    required this.name,
    required this.path,
    this.greeting = '',
  });

  final String id;
  final String name;
  final String path;
  final String greeting;

  factory ChatCharacter.fromJson(Map<String, dynamic> json) {
    return ChatCharacter(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      greeting: json['greeting']?.toString() ?? '',
    );
  }
}
