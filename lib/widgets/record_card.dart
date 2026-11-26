import 'package:flutter/material.dart';

import '../models/video.dart';
import '../utils/app_colors.dart';
import 'video_card.dart';

/// 收藏 / 历史记录卡片：与首页 [VideoCard] 同款的「图上文下」海报卡，
/// 历史模式下在封面下方显示观看进度条 + 进度百分比。
///
/// 交互：
/// - 点击：收藏 → 打开详情，历史 → 从上次位置续播（由外部决定）。
/// - 长按：收藏弹出「搜索该影片 / 删除」菜单，历史弹确认框删除（外部处理）。
class RecordCard extends StatelessWidget {
  final RecordItem item;
  final VoidCallback onTap;

  /// 长按回调带上手指位置，供上层在触点处弹菜单（搜索 / 删除）。
  final void Function(Offset position)? onLongPress;
  final bool isHistory;

  /// 来源角标（站点名）：与搜索结果卡片一致，贴在封面左上角。
  /// 为空表示该记录所属视频源已被删除，此时不显示角标。
  final String? sourceLabel;

  /// 封面「宽 / 高」比例：null = 网格模式（撑满剩余高度），
  /// 非 null = 瀑布流模式（按海报实测比例定高，不裁切）。
  final double? coverRatio;

  const RecordCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.isHistory = false,
    this.sourceLabel,
    this.coverRatio,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final progress = item.progress;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(6),
      child: InkWell(
        onTap: onTap,
        // InkWell 的长按回调不带触点；套一层 GestureDetector 拿手指位置，
        // 上层才能把菜单弹在卡片旁边而不是屏幕固定位置。
        child: GestureDetector(
          onLongPressStart: onLongPress == null
              ? null
              : (details) => onLongPress!(details.globalPosition),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (coverRatio != null)
                    AspectRatio(
                      aspectRatio: coverRatio!,
                      child: SizedBox(
                        width: double.infinity,
                        child: PosterCover(
                          pic: item.pic,
                          isDark: isDark,
                          sourceLabel: sourceLabel,
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: SizedBox(
                        width: double.infinity,
                        child: PosterCover(
                          pic: item.pic,
                          isDark: isDark,
                          sourceLabel: sourceLabel,
                        ),
                      ),
                    ),
                  if (isHistory && progress > 0)
                    LinearProgressIndicator(
                      value: progress / 100,
                      minHeight: 3,
                      backgroundColor:
                          isDark ? AppColors.darkDivider : const Color(0xFFEDEDED),
                      valueColor: const AlwaysStoppedAnimation(AppColors.brand),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Text(
                      item.name.isEmpty ? '未知' : item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: _buildMetaRow(theme, isDark),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetaRow(ThemeData theme, bool isDark) {
    final subColor = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    // 历史记录：优先显示「集名 + 进度%」，没有集名则退化为分类
    if (isHistory) {
      final label = item.label.isNotEmpty ? item.label : item.type;
      return Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: subColor),
            ),
          ),
          if (item.progress > 0) ...[
            const SizedBox(width: 6),
            Text(
              '${item.progress}%',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.brand,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      );
    }
    // 收藏：分类 + 备注 + 年份（与首页卡片一致）
    return Row(
      children: [
        Expanded(
          child: Text(
            item.type.isEmpty ? '其他' : item.type,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: subColor),
          ),
        ),
        if (item.note.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2A1416) : const Color(0xFFFFF1F0),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              item.note,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: const Color(0xFFFF4445)),
            ),
          ),
        const SizedBox(width: 4),
        Text(
          item.year,
          style: theme.textTheme.bodySmall?.copyWith(color: subColor),
        ),
      ],
    );
  }
}
