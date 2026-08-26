import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/community.dart';
import '../widgets/community_interaction_bar.dart';

/// 帖子详情页（贴吧风格，楼主 + 楼层回复）。仅前端布局。
class CommunityThreadScreen extends StatefulWidget {
  const CommunityThreadScreen({
    super.key,
    required this.post,
    required this.accountName,
  });

  final CommunityPost post;
  final String accountName;

  @override
  State<CommunityThreadScreen> createState() => _CommunityThreadScreenState();
}

class _CommunityThreadScreenState extends State<CommunityThreadScreen> {
  late List<CommunityReply> _replies;
  final TextEditingController _replyController = TextEditingController();
  final List<CommunityImage> _replyImages = <CommunityImage>[];
  final List<CommunityFileAttachment> _replyFiles = <CommunityFileAttachment>[];
  final ScrollController _scrollController = ScrollController();
  bool _submitting = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _replies = sampleCommunityReplies(widget.post.id);
  }

  @override
  void dispose() {
    _replyController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickReplyImage() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: '图片',
            extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'gif'],
          ),
        ],
      );
      if (picked == null) return;
      final bytes = Uint8List.fromList(await picked.readAsBytes());
      if (!mounted) return;
      setState(() {
        _replyImages.add(CommunityImage(name: picked.name, bytes: bytes));
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickReplyFile() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await openFile();
      if (picked == null) return;
      final size = await picked.length();
      if (!mounted) return;
      setState(() {
        _replyFiles.add(CommunityFileAttachment(name: picked.name, size: size));
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submitReply() async {
    final content = _replyController.text.trim();
    if (content.isEmpty || _submitting) {
      return;
    }
    setState(() => _submitting = true);
    _replyController.clear();
    final images = List<CommunityImage>.of(_replyImages);
    final files = List<CommunityFileAttachment>.of(_replyFiles);
    setState(() {
      _replies = <CommunityReply>[
        ..._replies,
        CommunityReply(
          id: '${widget.post.id}_reply_${DateTime.now().microsecondsSinceEpoch}',
          postId: widget.post.id,
          floor: 2 + _replies.length,
          authorName: widget.accountName,
          content: content,
          createdAt: DateTime.now(),
          images: images,
          files: files,
        ),
      ];
      _replyImages.clear();
      _replyFiles.clear();
    });
    setState(() => _submitting = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final post = widget.post;
    return Scaffold(
      appBar: AppBar(title: const Text('帖子详情')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              key: const ValueKey<String>('communityThreadList'),
              controller: _scrollController,
              padding: const EdgeInsets.all(10),
              children: <Widget>[
                _FloorTile(
                  floorLabel: '楼主',
                  authorName: post.authorName,
                  createdAt: post.createdAt,
                  highlighted: true,
                  likeCount: post.likeCount,
                  dislikeCount: post.dislikeCount,
                  images: post.images,
                  files: post.files,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        post.title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        post.excerpt,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                for (final reply in _replies)
                  _FloorTile(
                    key: ValueKey<String>('communityReply_${reply.id}'),
                    floorLabel: '${reply.floor} 楼',
                    authorName: reply.authorName,
                    createdAt: reply.createdAt,
                    likeCount: reply.likeCount,
                    dislikeCount: reply.dislikeCount,
                    images: reply.images,
                    files: reply.files,
                    child: Text(reply.content),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: _buildReplyComposer(context, colorScheme, post),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyComposer(
    BuildContext context,
    ColorScheme colorScheme,
    CommunityPost post,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_replyImages.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (var index = 0; index < _replyImages.length; index += 1)
                  _ComposerImageThumb(
                    image: _replyImages[index],
                    onRemove: () =>
                        setState(() => _replyImages.removeAt(index)),
                  ),
              ],
            ),
          if (_replyFiles.isNotEmpty)
            Column(
              children: <Widget>[
                for (var index = 0; index < _replyFiles.length; index += 1)
                  _ComposerFileRow(
                    file: _replyFiles[index],
                    onRemove: () =>
                        setState(() => _replyFiles.removeAt(index)),
                  ),
              ],
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('communityReplyField'),
                  controller: _replyController,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: '回复：${post.title}',
                    isDense: true,
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const ValueKey<String>('communityReplyImageButton'),
                tooltip: '插入图片',
                onPressed: _picking ? null : _pickReplyImage,
                icon: const Icon(Icons.image_outlined),
              ),
              IconButton(
                key: const ValueKey<String>('communityReplyFileButton'),
                tooltip: '添加附件',
                onPressed: _picking ? null : _pickReplyFile,
                icon: const Icon(Icons.attach_file_outlined),
              ),
              IconButton.filled(
                key: const ValueKey<String>('communityReplySendButton'),
                onPressed: _submitReply,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComposerImageThumb extends StatelessWidget {
  const _ComposerImageThumb({required this.image, required this.onRemove});

  final CommunityImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            image.bytes,
            width: 72,
            height: 72,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              width: 72,
              height: 72,
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: Material(
            color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.6),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ComposerFileRow extends StatelessWidget {
  const _ComposerFileRow({required this.file, required this.onRemove});

  final CommunityFileAttachment file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(formatCommunityBytes(file.size)),
      trailing: IconButton(
        tooltip: '移除',
        onPressed: onRemove,
        icon: const Icon(Icons.close),
      ),
    );
  }
}

class _FloorTile extends StatelessWidget {
  const _FloorTile({
    super.key,
    required this.floorLabel,
    required this.authorName,
    required this.createdAt,
    required this.child,
    this.highlighted = false,
    this.images = const <CommunityImage>[],
    this.files = const <CommunityFileAttachment>[],
    this.likeCount = 0,
    this.dislikeCount = 0,
  });

  final String floorLabel;
  final String authorName;
  final DateTime createdAt;
  final Widget child;
  final bool highlighted;
  final List<CommunityImage> images;
  final List<CommunityFileAttachment> files;
  final int likeCount;
  final int dislikeCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 20,
            backgroundColor: highlighted
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest,
            child: Icon(Icons.person, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      authorName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: highlighted
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        floorLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                child,
                if (images.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final image in images)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.memory(
                            image.bytes,
                            width: 96,
                            height: 96,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              width: 96,
                              height: 96,
                              color: colorScheme.surfaceContainer,
                              child: const Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                if (files.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  for (final file in files)
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.insert_drive_file_outlined,
                          size: 16,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${file.name}（${formatCommunityBytes(file.size)}）',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Text(
                      formatCommunityRelativeTime(createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: CommunityInteractionBar(
                          likeCount: likeCount,
                          dislikeCount: dislikeCount,
                          compact: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
