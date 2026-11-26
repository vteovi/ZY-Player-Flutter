import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/toast.dart';
import '../widgets/record_detail_dialog.dart';
import '../widgets/record_grid.dart';
import 'detail_page.dart';
import 'play_page.dart';
import 'search_page.dart';

/// 收藏与历史合并页 —— 顶部 TabBar 两个分栏，对应设置页里的
/// 「收藏与历史合并」开关开启时的老布局（导航栏那一项显示为「我的」）。
///
/// - 收藏：卡片网格，点开详情，长按弹出「搜索 / 复制片名 / 删除」菜单
/// - 历史记录：卡片网格（封面下方带进度条），点开续播，长按同样的三项菜单
///
/// 条数放在 Tab 文字里（`收藏 12` / `历史记录 34`），顶部一眼看得到。
/// 关闭开关后导航栏会变成「收藏」「历史」两个独立页（StarPage / HistoryPage），
/// 那个形态下条数显示在各自标题右侧的胶囊里。
class RecordsPage extends StatefulWidget {
  /// 初始分栏：0 = 收藏（默认），1 = 历史记录。
  /// 设置页「播放记录」入口在合并模式下传 1，直接落到历史分栏。
  final int initialTab;

  const RecordsPage({super.key, this.initialTab = 0});

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage>
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
      if (!mounted) return;
      final app = context.read<AppState>();
      app.loadStars();
      app.loadHistories();
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
    // 同收藏：站点 key 是 UUID，不能用第一个连字符切
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

  /// 长按收藏卡片：在手指位置弹出五项操作菜单。
  Future<void> _showStarActions(RecordItem item, Offset position) async {
    final screen = MediaQuery.of(context).size;
    final x = position.dx.clamp(0.0, math.max(0.0, screen.width - 210));
    final y = position.dy.clamp(0.0, math.max(0.0, screen.height - 250));
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        x.toDouble(),
        y.toDouble(),
        x.toDouble(),
        y.toDouble(),
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'search',
          child: Row(
            children: [
              Icon(Icons.search, size: 20),
              SizedBox(width: 12),
              Text('搜索该影片'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy_all_outlined, size: 20),
              SizedBox(width: 12),
              Text('复制影片名称'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'detail',
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 20),
              SizedBox(width: 12),
              Text('查看详情'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'external',
          child: Row(
            children: [
              Icon(Icons.open_in_new, size: 20),
              SizedBox(width: 12),
              Text('外部播放'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 20),
              SizedBox(width: 12),
              Text('删除'),
            ],
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'search') {
      _searchOnline(item);
    } else if (action == 'copy') {
      await _copyName(item);
    } else if (action == 'detail') {
      showRecordDetailDialog(
        context: context,
        item: item,
        onExternalPlay: () => openRecordExternally(context, item),
        onOpenDetail: () => openRecordDetail(context, item),
      );
    } else if (action == 'external') {
      await openRecordExternally(context, item);
    } else if (action == 'delete') {
      await _removeStar(item);
    }
  }

  /// 拿片名去全网搜：打开搜索页并自动搜，范围默认「全部站点」。
  void _searchOnline(RecordItem item) {
    final keyword = item.name.trim();
    if (keyword.isEmpty) {
      showToast(context, '这条收藏没有片名，无法搜索', success: false);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(initialKeyword: keyword),
      ),
    );
  }

  /// 长按历史卡片：同样弹出「搜索 / 复制片名 / 删除」三项菜单。
  Future<void> _showHistoryActions(RecordItem item, Offset position) async {
    final screen = MediaQuery.of(context).size;
    final x = position.dx.clamp(0.0, math.max(0.0, screen.width - 210));
    final y = position.dy.clamp(0.0, math.max(0.0, screen.height - 170));
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        x.toDouble(),
        y.toDouble(),
        x.toDouble(),
        y.toDouble(),
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'search',
          child: Row(
            children: [
              Icon(Icons.search, size: 20),
              SizedBox(width: 12),
              Text('搜索该影片'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy_all_outlined, size: 20),
              SizedBox(width: 12),
              Text('复制影片名称'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'detail',
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 20),
              SizedBox(width: 12),
              Text('查看详情'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'external',
          child: Row(
            children: [
              Icon(Icons.open_in_new, size: 20),
              SizedBox(width: 12),
              Text('外部播放'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 20),
              SizedBox(width: 12),
              Text('删除'),
            ],
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'search') {
      _searchOnline(item);
    } else if (action == 'copy') {
      await _copyName(item);
    } else if (action == 'detail') {
      showRecordDetailDialog(
        context: context,
        item: item,
        onExternalPlay: () => openRecordExternally(context, item),
        onOpenDetail: () => openRecordDetail(context, item),
      );
    } else if (action == 'external') {
      await openRecordExternally(context, item);
    } else if (action == 'delete') {
      await _removeHistory(item);
    }
  }

  /// 复制片名到剪贴板。长按没有点击那样明确的按下反馈，补一次震动。
  Future<void> _copyName(RecordItem item) async {
    final name = item.name.trim();
    if (name.isEmpty) {
      showToast(context, '这条影片没有片名', success: false);
      return;
    }
    await Clipboard.setData(ClipboardData(text: name));
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    showToast(context, '已复制影片名称：$name');
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
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: '收藏 ${app.stars.length}'),
            Tab(text: '历史记录 ${app.histories.length}'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          RecordGrid(
            items: app.stars,
            isHistory: false,
            emptyMessage: '还没有收藏任何影片',
            emptyIcon: Icons.star_border,
            onTap: _openDetail,
            onLongPress: _showStarActions,
          ),
          RecordGrid(
            items: app.histories,
            isHistory: true,
            emptyMessage: '还没有播放记录',
            emptyIcon: Icons.history,
            onTap: _play,
            onLongPress: _showHistoryActions,
          ),
        ],
      ),
    );
  }
}
