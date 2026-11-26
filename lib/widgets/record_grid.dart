import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import 'common_widgets.dart';
import 'record_card.dart';
import 'video_grid.dart';
import 'waterfall_grid.dart';

/// 收藏 / 历史记录共用的记录网格。
///
/// 两个页面各自只负责「点开干什么、长按删什么」，空态、列数策略、
/// 封面来源角标这些都一样，放在这里避免两边各抄一份走偏。
class RecordGrid extends StatelessWidget {
  final List<RecordItem> items;
  final bool isHistory;
  final String emptyMessage;
  final IconData emptyIcon;
  final void Function(RecordItem) onTap;
  final void Function(RecordItem, Offset position) onLongPress;

  const RecordGrid({
    super.key,
    required this.items,
    required this.isHistory,
    required this.emptyMessage,
    required this.emptyIcon,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
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
    // 与首页共用同一套网格列数/卡片比例策略。显示模式在 build 期读一次，
    // 布局阶段（LayoutBuilder 内）不能再读 InheritedWidget。
    final mode = context.select<AppState, ViewMode>((s) => s.config.viewMode);
    final screenWidth = MediaQuery.of(context).size.width;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth - 12
                : screenWidth - 12;
        if (mode == ViewMode.waterfall) {
          final columns = waterfallColumnCount(available);
          return WaterfallGrid(
            columns: columns,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return RecordCard(
                key: ValueKey(item.key),
                item: item,
                isHistory: isHistory,
                sourceLabel: labels[item.key],
                coverRatio: waterfallCoverRatio(item.pic),
                onTap: () => onTap(item),
                onLongPress: (position) => onLongPress(item, position),
              );
            },
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
          itemCount: items.length,
          gridDelegate: mode == ViewMode.landscape
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
              onLongPress: (position) => onLongPress(item, position),
            );
          },
        );
      },
    );
  }
}

/// 记录条数角标：贴在收藏页 / 历史页标题右边。
///
/// 拆成独立页面后原 TabBar 上的「收藏 12 / 历史记录 34」没了，条数改成
/// 标题旁这个小胶囊，顶部照样一眼看到。
class RecordCountTag extends StatelessWidget {
  final int count;

  const RecordCountTag({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white60 : const Color(0xFF606266),
        ),
      ),
    );
  }
}
