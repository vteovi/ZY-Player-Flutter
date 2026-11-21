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

  /// 收藏与历史。
  /// - 收藏：卡片网格，点开详情，长按取消收藏
  /// - 历史记录：卡片网格（带进度条），点开续播，长按清除记录
  ///
  /// 两种形态：[only] 为空时是带顶部 TabBar 的双分栏（设置页「播放记录」
  /// 入口仍走这形态）；给了 0 / 1 就只渲染单栏，供底部导航的「收藏」「历史」
  /// 两个独立页面使用 —— 单栏没有再套 TabBarView，横向滑动才能交给外层
  /// 的 PageView。
class StarPage extends StatefulWidget {
  /// 初始分栏：0 = 收藏（默认），1 = 历史记录。
  final int initialTab;

  /// 只显示某一栏：0 = 收藏，1 = 历史，null = 双分栏。
  final int? only;

  const StarPage({super.key, this.initialTab = 0, this.only});

  @override
  State<StarPage> createState() => _StarPageState();
}

class _StarPageState extends State<StarPage>
    with SingleTickerProviderStateMixin {
  /// 只有双分栏模式才需要，单栏模式保持 null
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    if (widget.only == null) {
      _tabController = TabController(
        length: 2,
        vsync: this,
        initialIndex: widget.initialTab.clamp(0, 1),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().loadStars();
        context.read<AppState>().loadHistories();
      }
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除收藏'),
        content: Text('确定要将《${item.name}》从收藏中移除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) return;
    final ok = await context.read<AppState>().removeStar(item.key);
    if (!mounted) return;
    showToast(context, ok ? '已移除收藏' : '移除失败', success: ok);
  }

  Future<void> _removeHistory(RecordItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除播放记录'),
        content: Text('确定要删除《${item.name}》的播放记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) return;
    final ok = await context.read<AppState>().removeHistory(item.key);
    if (!mounted) return;
    showToast(context, ok ? '已删除记录' : '删除失败', success: ok);
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅自己真正需要的那份列表，不用 `watch<AppState>()`。
    // 播放页每 10 秒写一次播放进度都会 notifyListeners，watch 整个 AppState
    // 会让这整页网格（含 AppBar）跟着重建 —— 哪怕当前根本不在这一页，
    // 每次 notify 也要白跑一遍 build，滑动时抢帧预算。
    // select 按列表实例比较：loadStars/loadHistories 会换新 List，变更照常触发；
    // 其它字段（站点、配置）变化则不再牵连本页。
    final only = widget.only;
    // 单栏模式：底部导航的「收藏」「历史」两个独立页面
    if (only != null) {
      final history = only == 1;
      final items = context.select(
        (AppState s) => history ? s.histories : s.stars,
      );
      return Scaffold(
        appBar: AppBar(title: Text(history ? '历史记录' : '我的收藏')),
        body: _buildPane(
          items: items,
          isHistory: history,
          emptyMessage: history ? '还没有播放记录' : '还没有收藏任何影片',
          emptyIcon: history ? Icons.history : Icons.star_border,
          onTap: history ? _play : _openDetail,
          onLongPress: history ? _removeHistory : _removeStar,
        ),
      );
    }
    final stars = context.select((AppState s) => s.stars);
    final histories = context.select((AppState s) => s.histories);
    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏与历史'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: '收藏 ${stars.length}'),
            Tab(text: '历史记录 ${histories.length}'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPane(
            items: stars,
            isHistory: false,
            emptyMessage: '还没有收藏任何影片',
            emptyIcon: Icons.star_border,
            onTap: _openDetail,
            onLongPress: _removeStar,
          ),
          _buildPane(
            items: histories,
            isHistory: true,
            emptyMessage: '还没有播放记录',
            emptyIcon: Icons.history,
            onTap: _play,
            onLongPress: _removeHistory,
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
    required void Function(RecordItem) onLongPress,
  }) {
    if (items.isEmpty) {
      return EmptyHint(message: emptyMessage, icon: emptyIcon);
    }
    // 记录 key 是 `{siteKey}-{videoId}`，反解出所属站点名做封面角标
    // （与搜索结果的来源角标一致）。站点被删除后 siteOf 返回 null，则不出角标。
    final app = context.read<AppState>();
    final labels = <String, String>{};
    for (final item in items) {
      final siteKey = app.resolveRecordKey(item.key).first;
      final name = app.siteOf(siteKey)?.name ?? '';
      if (name.isNotEmpty) labels[item.key] = name;
    }
    // 与首页共用同一套网格列数/卡片比例策略。横竖开关在 build 期读一次，
    // 布局阶段（LayoutBuilder 内）不能再读 InheritedWidget。
    final landscape =
        context.select<AppState, bool>((s) => s.config.landscapeCard);
    final screenWidth = MediaQuery.of(context).size.width;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth - 12
                : screenWidth - 12;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
          itemCount: items.length,
          gridDelegate: landscape
              ? landscapeGridDelegate(available)
              : portraitGridDelegate(available),
          itemBuilder: (context, index) {
            final item = items[index];
            return RecordCard(
              key: ValueKey(item.key),
              item: item,
              isHistory: isHistory,
              sourceLabel: labels[item.key],
              onTap: () => onTap(item),
              onLongPress: () => onLongPress(item),
            );
          },
        );
      },
    );
  }
}
