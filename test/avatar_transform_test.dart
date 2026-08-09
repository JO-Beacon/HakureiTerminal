import 'package:flutter_test/flutter_test.dart';

import 'package:hakurei_terminal/models/avatar_transform.dart';
import 'package:hakurei_terminal/models/chat_session.dart';

void main() {
  test('avatar transform clamps persisted crop state', () {
    final transform = AvatarTransform(
      scale: 8,
      offsetX: 4,
      offsetY: -4,
      rotationQuarterTurns: -1,
    ).normalized();

    expect(transform.scale, 3);
    expect(transform.offsetX, 1);
    expect(transform.offsetY, -1);
    expect(transform.rotationQuarterTurns, 3);
  });

  test('chat sessions persist avatar transform and keep legacy defaults', () {
    const session = ChatSession(
      sessionId: 'avatar_session',
      avatarImagePath: 'media/original-avatar',
      avatarTransform: AvatarTransform(
        scale: 1.8,
        offsetX: 0.2,
        offsetY: -0.1,
        rotationQuarterTurns: 1,
      ),
    );

    final restored = ChatSession.fromJson(session.toJson());
    expect(restored.avatarImagePath, session.avatarImagePath);
    expect(restored.avatarTransform.scale, 1.8);
    expect(restored.avatarTransform.offsetX, 0.2);
    expect(restored.avatarTransform.offsetY, -0.1);
    expect(restored.avatarTransform.rotationQuarterTurns, 1);

    final legacy = ChatSession.fromJson(const <String, dynamic>{
      'session_id': 'legacy_avatar_session',
      'avatar_image_path': 'media/legacy-avatar',
    });
    expect(legacy.avatarTransform, const AvatarTransform());
  });
}
