import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/toast.dart';
import '../widgets/common_widgets.dart';
import '../widgets/record_card.dart';
import '../widgets/video_grid.dart';
import 'detail_page.dart';
import 'play_page.dart';

/// 收藏与历史：顶部 TabBar 两个分栏
/// - 收藏：卡片网格，点开详情，可删除
/// - 历史记录：卡片网格（带进度条），点开续播，可删除
class StarPage extends StatefulWidget {
  /// 初始分栏：0 = 收藏（默认），1 = 历史记录。
  /// 设置页「播放记录」入口可传 1 直接落到历史分栏。
  final int initialTab;

  const StarPage({super.key, this.initialTab = 0});

  @override
  State<StarPage> createState() => _StarPageState();
}

class _StarPageState extends State<StarPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 1),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().loadStars();
        context.read<AppState>().loadHistories();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _openDetail(RecordItem item) {
    // 站点 key 是 UUID（自带连字符），必须交给 AppState 去精确拆，
    // 否则切出的 siteKey 找不到对应源，详情页会报「获取详情失败」
    final parts = context.read<AppState>().resolveRecordKey(item.key);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(siteKey: parts[0], videoId: parts[1]),
      ),
    );
  }

  void _play(RecordItem item) {
    if (item.url.isEmpty) return;
    // 同收藏页：站点 key 是 UUID，不能用第一个连字符切
    final parts = context.read<AppState>().resolveRecordKey(item.key);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayPage(
          siteKey: parts[0],
          videoId: parts[1],
          title: item.label.isEmpty ? item.name : item.label,
          url: item.url,
          initialTime: item.currentTime,
        ),
      ),
    );
  }

  Future<void> _removeStar(RecordItem item) async {
    final ok = await context.read<AppState>().removeStar(item.key);
    if (!mounted) return;
    showToast(context, ok ? '已移除收藏' : '移除失败', success: ok);
  }

  Future<void> _removeHistory(RecordItem item) async {
    final ok = await context.read<AppState>().removeHistory(item.key);
    if (!mounted) return;
    showToast(context, ok ? '已删除记录' : '删除失败', success: ok);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏与历史'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '收藏'),
            Tab(text: '历史记录'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPane(
            items: app.stars,
            isHistory: false,
            emptyMessage: '还没有收藏任何影片',
            emptyIcon: Icons.star_border,
            onTap: _openDetail,
            onRemove: _removeStar,
          ),
          _buildPane(
            items: app.histories,
            isHistory: true,
            emptyMessage: '还没有播放记录',
            emptyIcon: Icons.history,
            onTap: _play,
            onRemove: _removeHistory,
          ),
        ],
      ),
    );
  }

  Widget _buildPane({
    required List<RecordItem> items,
    required bool isHistory,
    required String emptyMessage,
    required IconData emptyIcon,
    required void Function(RecordItem) onTap,
    required void Function(RecordItem) onRemove,
  }) {
    if (items.isEmpty) {
      return EmptyHint(message: emptyMessage, icon: emptyIcon);
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
      itemCount: items.length,
      // 与首页共用同一套网格列数/卡片比例策略
      gridDelegate: videoGridDelegate(context),
      itemBuilder: (context, index) {
        final item = items[index];
        return RecordCard(
          key: ValueKey(item.key),
          item: item,
          isHistory: isHistory,
          onTap: () => onTap(item),
          onRemove: () => onRemove(item),
        );
      },
    );
  }
}
