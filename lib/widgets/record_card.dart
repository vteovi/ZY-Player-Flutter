import 'package:flutter/material.dart';

import '../models/video.dart';
import '../utils/app_colors.dart';
import 'video_card.dart';

/// 收藏 / 历史记录卡片：与首页 [VideoCard] 同款的「图上文下」海报卡，
/// 但额外提供两个收藏页专属能力：
/// - 右上角圆形删除按钮（收藏/历史都可直接移除）
/// - 历史模式下在封面下方显示观看进度条 + 进度百分比
///
/// 点击行为由外部决定：收藏 → 打开详情，历史 → 从上次位置续播。
class RecordCard extends StatelessWidget {
  final RecordItem item;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final bool isHistory;

  const RecordCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onRemove,
    this.isHistory = false,
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
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: PosterCover(pic: item.pic, isDark: isDark),
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
            // 右上角圆形删除按钮（覆盖在封面上）
            Positioned(
              top: 4,
              right: 4,
              child: _RemoveButton(onPressed: onRemove),
            ),
          ],
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

/// 封面右上角的半透明圆形删除按钮
class _RemoveButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _RemoveButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.close, color: Colors.white, size: 16),
        ),
      ),
    );
  }
}
