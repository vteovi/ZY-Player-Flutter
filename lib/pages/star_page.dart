import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/toast.dart';
import '../widgets/record_grid.dart';
import 'detail_page.dart';

/// 收藏页：卡片网格，点开详情，长按取消收藏。
///
/// 只在「收藏与历史合并」关闭（默认）时出现 —— 此时导航栏是
/// 「首页 / 收藏 / 历史 / 设置」，条数显示在标题右边的 [RecordCountTag] 里。
/// 打开合并开关后改由 `RecordsPage`（「我的」）承载，收藏与历史分两个 Tab。
class StarPage extends StatefulWidget {
  const StarPage({super.key});

  @override
  State<StarPage> createState() => _StarPageState();
}

class _StarPageState extends State<StarPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().loadStars();
    });
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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('收藏'),
            const SizedBox(width: 8),
            RecordCountTag(count: app.stars.length),
          ],
        ),
      ),
      body: RecordGrid(
        items: app.stars,
        isHistory: false,
        emptyMessage: '还没有收藏任何影片',
        emptyIcon: Icons.star_border,
        onTap: _openDetail,
        onLongPress: _removeStar,
      ),
    );
  }
}
