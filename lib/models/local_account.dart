class LocalAccount {
  const LocalAccount({
    required this.id,
    required this.displayName,
    this.avatarImagePath = '',
    this.createdAt,
  });

  final String id;
  final String displayName;
  final String avatarImagePath;
  final DateTime? createdAt;

  LocalAccount copyWith({
    String? id,
    String? displayName,
    String? avatarImagePath,
    DateTime? createdAt,
  }) {
    return LocalAccount(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatarImagePath: avatarImagePath ?? this.avatarImagePath,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'display_name': displayName,
      'avatar_image_path': avatarImagePath,
      'created_at': createdAt?.toIso8601String(),
    }..removeWhere((_, value) => value == null || value == '');
  }

  factory LocalAccount.fromJson(Map<String, dynamic> json) {
    return LocalAccount(
      id: json['id']?.toString().trim() ?? '',
      displayName: json['display_name']?.toString().trim() ?? '',
      avatarImagePath: json['avatar_image_path']?.toString().trim() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}
