import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/toast.dart';
import '../widgets/record_grid.dart';
import 'play_page.dart';

/// 历史记录页：卡片网格（封面下方带进度条），点开从上次位置续播，
/// 长按删除该条记录。
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
        onLongPress: (item, _) => _removeHistory(item),
      ),
    );
  }
}
