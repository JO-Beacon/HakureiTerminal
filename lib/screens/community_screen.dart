import 'package:flutter/material.dart';

import '../models/community.dart';
import '../models/local_account.dart';
import '../widgets/community_interaction_bar.dart';
import 'community_compose_screen.dart';
import 'community_thread_screen.dart';

/// 社区列表页（贴吧风格）。仅前端布局，与本地账户系统挂钩。
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key, this.activeAccount});

  final LocalAccount? activeAccount;

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  late List<CommunityPost> _posts;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  int _sortIndex = 0;

  String get _accountName {
    final name = widget.activeAccount?.displayName.trim() ?? '';
    return name.isEmpty ? '未登录账户' : name;
  }

  @override
  void initState() {
    super.initState();
    _posts = sampleCommunityPosts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<CommunityPost> get _visiblePosts {
    final query = _query.trim();
    var posts = _posts.where((post) {
      if (query.isEmpty) {
        return true;
      }
      return post.title.contains(query) || post.excerpt.contains(query);
    }).toList(growable: false);
    posts.sort((a, b) {
      if (a.pinned != b.pinned) {
        return a.pinned ? -1 : 1;
      }
      final aTime = _sortIndex == 0 ? a.lastReplyAt ?? a.createdAt : a.createdAt;
      final bTime = _sortIndex == 0 ? b.lastReplyAt ?? b.createdAt : b.createdAt;
      return bTime.compareTo(aTime);
    });
    return posts;
  }

  Future<void> _openThread(CommunityPost post) async {
    final replyCount = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (context) => CommunityThreadScreen(
          post: post,
          accountName: _accountName,
        ),
      ),
    );
    if (replyCount != null && mounted) {
      setState(() {
        _posts = _posts
            .map(
              (item) => item.id == post.id
                  ? item.copyWith(replyCount: replyCount)
                  : item,
            )
            .toList(growable: false);
      });
    }
  }

  Future<void> _composePost() async {
    final post = await Navigator.of(context).push<CommunityPost>(
      MaterialPageRoute<CommunityPost>(
        builder: (context) => CommunityComposeScreen(
          accountName: _accountName,
        ),
      ),
    );
    if (post == null || !mounted) {
      return;
    }
    setState(() {
      _posts = <CommunityPost>[post, ..._posts];
    });
  }

  @override
  Widget build(BuildContext context) {
    final posts = _visiblePosts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('社区'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: <Widget>[
                const CircleAvatar(radius: 14, child: Icon(Icons.person, size: 16)),
                const SizedBox(width: 8),
                Text(
                  _accountName,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              key: const ValueKey<String>('communitySearchField'),
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: '搜索帖子',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                for (var index = 0; index < 2; index += 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(index == 0 ? '热门' : '最新'),
                      selected: _sortIndex == index,
                      onSelected: (_) => setState(() => _sortIndex = index),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: posts.isEmpty
                ? const Center(child: Text('没有找到相关帖子'))
                : ListView.separated(
                    key: const ValueKey<String>('communityPostList'),
                    padding: const EdgeInsets.all(8),
                    itemCount: posts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final post = posts[index];
                      return _PostListTile(
                        post: post,
                        onTap: () => _openThread(post),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey<String>('communityComposeButton'),
        onPressed: _composePost,
        icon: const Icon(Icons.edit),
        label: const Text('发帖'),
      ),
    );
  }
}

class _PostListTile extends StatelessWidget {
  const _PostListTile({required this.post, required this.onTap});

  final CommunityPost post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (post.pinned)
                  Container(
                    margin: const EdgeInsets.only(right: 6, top: 2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '置顶',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    post.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (post.excerpt.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                post.excerpt,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Icon(
                  Icons.account_circle_outlined,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  post.authorName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  Icons.chat_bubble_outline,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '${post.replyCount}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  formatCommunityRelativeTime(
                    post.lastReplyAt ?? post.createdAt,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            CommunityInteractionBar(
              likeCount: post.likeCount,
              dislikeCount: post.dislikeCount,
              compact: true,
            ),
          ],
        ),
      ),
    );
  }
}
