import 'package:flutter/material.dart';

/// 帖子和评论共用的点赞 / 点踩 / 举报互动条。仅前端本地状态，不接后端。
class CommunityInteractionBar extends StatefulWidget {
  const CommunityInteractionBar({
    super.key,
    this.likeCount = 0,
    this.dislikeCount = 0,
    this.compact = false,
  });

  final int likeCount;
  final int dislikeCount;
  final bool compact;

  @override
  State<CommunityInteractionBar> createState() =>
      _CommunityInteractionBarState();
}

class _CommunityInteractionBarState extends State<CommunityInteractionBar> {
  late int _likes = widget.likeCount;
  late int _dislikes = widget.dislikeCount;
  bool _liked = false;
  bool _disliked = false;

  void _toggleLike() {
    setState(() {
      if (_liked) {
        _liked = false;
        _likes -= 1;
      } else {
        _liked = true;
        _likes += 1;
        if (_disliked) {
          _disliked = false;
          _dislikes -= 1;
        }
      }
    });
  }

  void _toggleDislike() {
    setState(() {
      if (_disliked) {
        _disliked = false;
        _dislikes -= 1;
      } else {
        _disliked = true;
        _dislikes += 1;
        if (_liked) {
          _liked = false;
          _likes -= 1;
        }
      }
    });
  }

  Future<void> _report() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('举报内容'),
        content: const Text('确定要举报该内容吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('举报'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已提交举报，感谢你的反馈')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeColor = colorScheme.primary;
    final mutedColor = colorScheme.onSurfaceVariant;

    Widget action({
      required IconData icon,
      required IconData activeIcon,
      required int count,
      required bool active,
      required VoidCallback onTap,
      String? tooltip,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                active ? activeIcon : icon,
                size: widget.compact ? 16 : 18,
                color: active ? activeColor : mutedColor,
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: active ? activeColor : mutedColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        action(
          icon: Icons.thumb_up_outlined,
          activeIcon: Icons.thumb_up,
          count: _likes,
          active: _liked,
          onTap: _toggleLike,
          tooltip: '点赞',
        ),
        action(
          icon: Icons.thumb_down_outlined,
          activeIcon: Icons.thumb_down,
          count: _dislikes,
          active: _disliked,
          onTap: _toggleDislike,
          tooltip: '点踩',
        ),
        IconButton(
          tooltip: '举报',
          onPressed: _report,
          icon: Icon(Icons.flag_outlined, size: widget.compact ? 16 : 18),
          color: mutedColor,
        ),
      ],
    );
  }
}
