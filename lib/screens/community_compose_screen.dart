import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/community.dart';

class _PickedImage {
  const _PickedImage({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class _PickedAttachment {
  const _PickedAttachment({required this.name, required this.size});

  final String name;
  final int size;
}

/// 社区发帖界面（仅 UI）。标题、正文、图片与文件附件均为前端占位，
/// 不执行实际上传或持久化。
class CommunityComposeScreen extends StatefulWidget {
  const CommunityComposeScreen({super.key, required this.accountName});

  final String accountName;

  @override
  State<CommunityComposeScreen> createState() => _CommunityComposeScreenState();
}

class _CommunityComposeScreenState extends State<CommunityComposeScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  final List<_PickedImage> _images = <_PickedImage>[];
  final List<_PickedAttachment> _files = <_PickedAttachment>[];
  bool _picking = false;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  bool get _canPublish => _titleController.text.trim().isNotEmpty;

  Future<void> _pickImage() async {
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
        _images.add(_PickedImage(name: picked.name, bytes: bytes));
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await openFile();
      if (picked == null) return;
      final size = await picked.length();
      if (!mounted) return;
      setState(() {
        _files.add(_PickedAttachment(name: picked.name, size: size));
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _publish() {
    if (!_canPublish) return;
    final title = _titleController.text.trim();
    final body = _bodyController.text.trim();
    Navigator.of(context).pop(
      CommunityPost(
        id: 'post_${DateTime.now().microsecondsSinceEpoch}',
        title: title,
        excerpt: body.isEmpty ? '（暂无正文）' : body,
        authorName: widget.accountName,
        replyCount: 0,
        createdAt: DateTime.now(),
        lastReplyAt: DateTime.now(),
        images: _images
            .map(
              (image) => CommunityImage(name: image.name, bytes: image.bytes),
            )
            .toList(growable: false),
        files: _files
            .map(
              (file) => CommunityFileAttachment(name: file.name, size: file.size),
            )
            .toList(growable: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('发布新帖'),
        actions: <Widget>[
          FilledButton.icon(
            key: const ValueKey<String>('communityPublishButton'),
            onPressed: _canPublish ? _publish : null,
            icon: const Icon(Icons.send),
            label: const Text('发布'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        key: const ValueKey<String>('communityComposeList'),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('communityComposeTitleField'),
            controller: _titleController,
            maxLength: 60,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '标题',
              hintText: '一句话说清楚主题',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('communityComposeBodyField'),
            controller: _bodyController,
            minLines: 6,
            maxLines: 14,
            decoration: const InputDecoration(
              labelText: '正文',
              hintText: '分享你的内容……',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 20),
          _ComposeSection(
            title: '图片',
            icon: Icons.image_outlined,
            trailing: OutlinedButton.icon(
              key: const ValueKey<String>('communityAddImageButton'),
              onPressed: _picking ? null : _pickImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('添加图片'),
            ),
            child: _images.isEmpty
                ? const Text('可添加多张图片（仅 UI，暂不上传）')
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (var index = 0; index < _images.length; index += 1)
                        _ImageThumb(
                          image: _images[index],
                          onRemove: () => setState(() => _images.removeAt(index)),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          _ComposeSection(
            title: '文件',
            icon: Icons.attach_file_outlined,
            trailing: OutlinedButton.icon(
              key: const ValueKey<String>('communityAddFileButton'),
              onPressed: _picking ? null : _pickFile,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('添加文件'),
            ),
            child: _files.isEmpty
                ? const Text('可添加附件文件（仅 UI，暂不上传）')
                : Column(
                    children: <Widget>[
                      for (var index = 0; index < _files.length; index += 1)
                        _AttachmentTile(
                          attachment: _files[index],
                          onRemove: () => setState(() => _files.removeAt(index)),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const ValueKey<String>('communityComposeSubmitButton'),
            onPressed: _canPublish ? _publish : null,
            icon: const Icon(Icons.send),
            label: const Text('发布'),
          ),
          const SizedBox(height: 8),
          Text(
            '以「${widget.accountName}」身份发布',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ComposeSection extends StatelessWidget {
  const _ComposeSection({
    required this.title,
    required this.icon,
    required this.trailing,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.image, required this.onRemove});

  final _PickedImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            image.bytes,
            width: 88,
            height: 88,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              width: 88,
              height: 88,
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
                child: Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.attachment, required this.onRemove});

  final _PickedAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(
        attachment.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(formatCommunityBytes(attachment.size)),
      trailing: IconButton(
        tooltip: '移除',
        onPressed: onRemove,
        icon: const Icon(Icons.close),
      ),
    );
  }
}
