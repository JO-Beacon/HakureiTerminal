import 'dart:typed_data';

/// 社区模块的本地数据模型。当前仅用于前端布局演示，
/// 字段对齐未来 litestar 后端的 JSON 返回，方便后续替换为真实数据源。

class CommunityImage {
  const CommunityImage({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class CommunityFileAttachment {
  const CommunityFileAttachment({required this.name, required this.size});

  final String name;
  final int size;
}

class CommunityPost {
  const CommunityPost({
    required this.id,
    required this.title,
    required this.excerpt,
    required this.authorName,
    required this.replyCount,
    required this.createdAt,
    this.lastReplyAt,
    this.pinned = false,
    this.images = const <CommunityImage>[],
    this.files = const <CommunityFileAttachment>[],
    this.likeCount = 0,
    this.dislikeCount = 0,
  });

  final String id;
  final String title;
  final String excerpt;
  final String authorName;
  final int replyCount;
  final DateTime createdAt;
  final DateTime? lastReplyAt;
  final bool pinned;
  final List<CommunityImage> images;
  final List<CommunityFileAttachment> files;
  final int likeCount;
  final int dislikeCount;

  CommunityPost copyWith({
    String? id,
    String? title,
    String? excerpt,
    String? authorName,
    int? replyCount,
    DateTime? createdAt,
    DateTime? lastReplyAt,
    bool? pinned,
    List<CommunityImage>? images,
    List<CommunityFileAttachment>? files,
    int? likeCount,
    int? dislikeCount,
  }) {
    return CommunityPost(
      id: id ?? this.id,
      title: title ?? this.title,
      excerpt: excerpt ?? this.excerpt,
      authorName: authorName ?? this.authorName,
      replyCount: replyCount ?? this.replyCount,
      createdAt: createdAt ?? this.createdAt,
      lastReplyAt: lastReplyAt ?? this.lastReplyAt,
      pinned: pinned ?? this.pinned,
      images: images ?? this.images,
      files: files ?? this.files,
      likeCount: likeCount ?? this.likeCount,
      dislikeCount: dislikeCount ?? this.dislikeCount,
    );
  }
}

class CommunityReply {
  const CommunityReply({
    required this.id,
    required this.postId,
    required this.floor,
    required this.authorName,
    required this.content,
    required this.createdAt,
    this.images = const <CommunityImage>[],
    this.files = const <CommunityFileAttachment>[],
    this.likeCount = 0,
    this.dislikeCount = 0,
  });

  final String id;
  final String postId;
  final int floor;
  final String authorName;
  final String content;
  final DateTime createdAt;
  final List<CommunityImage> images;
  final List<CommunityFileAttachment> files;
  final int likeCount;
  final int dislikeCount;
}

/// 社区列表页的占位示例数据。接入后端后由接口返回替代。
List<CommunityPost> sampleCommunityPosts() {
  final base = DateTime.now().subtract(const Duration(hours: 3));
  return <CommunityPost>[
    CommunityPost(
      id: 'post_1',
      title: '新人报道，请多指教',
      excerpt: '第一次来社区，简单介绍一下自己，希望认识更多朋友。',
      authorName: '雾雨魔理沙',
      replyCount: 42,
      createdAt: base,
      lastReplyAt: DateTime.now().subtract(const Duration(minutes: 4)),
      pinned: true,
      likeCount: 128,
      dislikeCount: 3,
    ),
    CommunityPost(
      id: 'post_2',
      title: '分享一张最近拍的照片',
      excerpt: '周末出去走走，随手拍了几张，和大家分享一下。',
      authorName: '博丽灵梦',
      replyCount: 18,
      createdAt: base.subtract(const Duration(hours: 1)),
      lastReplyAt: DateTime.now().subtract(const Duration(minutes: 22)),
      likeCount: 64,
      dislikeCount: 1,
    ),
    CommunityPost(
      id: 'post_3',
      title: '求推荐几款好用的工具',
      excerpt: '最近想换一批工具，有没有用起来顺手的推荐？',
      authorName: '十六夜咲夜',
      replyCount: 7,
      createdAt: base.subtract(const Duration(hours: 2)),
      lastReplyAt: DateTime.now().subtract(const Duration(hours: 1)),
      likeCount: 21,
    ),
    CommunityPost(
      id: 'post_4',
      title: '今天的心情记录',
      excerpt: '天气不错，心情也跟着变好了。',
      authorName: '红美铃',
      replyCount: 3,
      createdAt: base.subtract(const Duration(hours: 5)),
      lastReplyAt: DateTime.now().subtract(const Duration(hours: 2)),
      likeCount: 9,
    ),
  ];
}

/// 帖子详情页的占位楼层回复。接入后端后由接口返回替代。
List<CommunityReply> sampleCommunityReplies(String postId) {
  final base = DateTime.now().subtract(const Duration(hours: 2));
  return <CommunityReply>[
    CommunityReply(
      id: '${postId}_reply_1',
      postId: postId,
      floor: 2,
      authorName: '射命丸文',
      content: '欢迎欢迎，这里氛围很好的。',
      createdAt: base,
      likeCount: 12,
      dislikeCount: 1,
    ),
    CommunityReply(
      id: '${postId}_reply_2',
      postId: postId,
      floor: 3,
      authorName: '帕秋莉·诺蕾姬',
      content: '顶一个，顺便看看有没有新帖子。',
      createdAt: base.subtract(const Duration(minutes: 30)),
      likeCount: 5,
    ),
  ];
}

/// 将时间格式化为贴吧风格的相对时间（“刚刚 / x 分钟前 / x 小时前 / 昨天”）。
String formatCommunityRelativeTime(DateTime value) {
  final local = value.toLocal();
  final difference = DateTime.now().difference(local);
  if (difference.inMinutes < 1) {
    return '刚刚';
  }
  if (difference.inMinutes < 60) {
    return '${difference.inMinutes} 分钟前';
  }
  if (difference.inHours < 24) {
    return '${difference.inHours} 小时前';
  }
  final today = DateTime.now();
  final yesterday = DateTime(today.year, today.month, today.day - 1);
  final day = DateTime(local.year, local.month, local.day);
  if (day == yesterday) {
    return '昨天';
  }
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.month}-${two(local.day)}';
}

/// 将字节数格式化为可读大小。
String formatCommunityBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
