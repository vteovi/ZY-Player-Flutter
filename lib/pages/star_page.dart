import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/toast.dart';
import '../widgets/record_actions.dart';
import '../widgets/record_grid.dart';
import 'detail_page.dart';
import 'search_page.dart';

/// 收藏页：卡片网格，点开详情，长按弹出「搜索该影片 / 复制片名 / 外部播放 / 删除」菜单。
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

  /// 长按收藏卡片：在手指位置弹出四项操作菜单。
  Future<void> _showActions(RecordItem item, Offset position) async {
    final screen = MediaQuery.of(context).size;
    // 菜单约 200 宽、四项约 200 高，贴边时往里收，别弹出屏幕外
    final x = position.dx.clamp(0.0, math.max(0.0, screen.width - 210));
    final y = position.dy.clamp(0.0, math.max(0.0, screen.height - 210));
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
    } else if (action == 'external') {
      await openRecordExternally(context, item);
    } else if (action == 'delete') {
      await _removeStar(item);
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
    showToast(context, '已复制片名：$name');
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
        onLongPress: _showActions,
      ),
    );
  }
}
