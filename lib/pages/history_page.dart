import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/toast.dart';
import '../widgets/record_actions.dart';
import '../widgets/record_grid.dart';
import 'play_page.dart';
import 'search_page.dart';

/// 历史记录页：卡片网格（封面下方带进度条），点开从上次位置续播，
/// 长按弹出五项菜单：「搜索该影片 / 复制片名 / 复制播放地址 / 外部播放 / 删除」。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().loadHistories();
    });
  }

  void _play(RecordItem item) {
    if (item.url.isEmpty) return;
    // 站点 key 是 UUID，不能用第一个连字符切，交给 AppState 精确拆
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

  /// 长按历史卡片：在手指位置弹出五项操作菜单。
  Future<void> _showActions(RecordItem item, Offset position) async {
    final screen = MediaQuery.of(context).size;
    // 菜单约 200 宽、五项约 240 高，贴边时往里收，别弹出屏幕外
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
              Text('复制片名'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copyurl',
          child: Row(
            children: [
              Icon(Icons.link, size: 20),
              SizedBox(width: 12),
              Text('复制播放地址'),
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
    } else if (action == 'copyurl') {
      await _copyUrl(item);
    } else if (action == 'external') {
      await openRecordExternally(context, item);
    } else if (action == 'delete') {
      await _removeHistory(item);
    }
  }

  /// 拿片名去全网搜：打开搜索页并自动搜，范围默认「全部站点」。
  void _searchOnline(RecordItem item) {
    final keyword = item.name.trim();
    if (keyword.isEmpty) {
      showToast(context, '这条记录没有片名，无法搜索', success: false);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(initialKeyword: keyword),
      ),
    );
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
    showToast(context, '已复制片名：$name');
  }

  /// 复制这一条记录的播放地址（点开续播用的那个地址）。
  Future<void> _copyUrl(RecordItem item) async {
    final url = item.url.trim();
    if (url.isEmpty) {
      showToast(context, '这条记录没有保存播放地址', success: false);
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    showToast(context, '已复制播放地址');
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
        title: Row(
          children: [
            const Text('历史记录'),
            const SizedBox(width: 8),
            RecordCountTag(count: app.histories.length),
          ],
        ),
      ),
      body: RecordGrid(
        items: app.histories,
        isHistory: true,
        emptyMessage: '还没有播放记录',
        emptyIcon: Icons.history,
        onTap: _play,
        onLongPress: _showActions,
      ),
    );
  }
}
