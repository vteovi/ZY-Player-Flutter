import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/video.dart';

/// 首页卡片：封面 + 片名 + 分类/备注/年份（图上文下）。
///
/// 卡片布局在横 / 竖模式下相同，区别只在于网格给的宽高比：
/// 竖向 = 竖版海报比例；横向 = 横版（约 16:9）海报比例。
class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;

  const VideoCard({super.key, required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(6),
      color: isDark ? const Color(0xFF1E1E20) : null,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: _buildCover(isDark),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(
                video.name.isEmpty ? '未知' : video.name,
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
      ),
    );
  }

  /// 分类 + 备注 + 年份
  Widget _buildMetaRow(ThemeData theme, bool isDark) {
    final subColor = isDark ? const Color(0xFF9CA0A6) : const Color(0xFF909399);
    return Row(
      children: [
        Expanded(
          child: Text(
            video.type.isEmpty ? '其他' : video.type,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: subColor),
          ),
        ),
        if (video.note.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(left: 4),
            padding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF3A2A2C) : const Color(0xFFFFF1F0),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              video.note,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: const Color(0xFFFF4445)),
            ),
          ),
        const SizedBox(width: 4),
        Text(
          video.year,
          style: theme.textTheme.bodySmall?.copyWith(color: subColor),
        ),
      ],
    );
  }

  Widget _buildCover(bool isDark) {
    final bgColor =
        isDark ? const Color(0xFF2C2C2E) : const Color(0xFFEDEDED);
    final iconColor =
        isDark ? const Color(0xFF5A5A5E) : const Color(0xFFC0C4CC);
    if (video.pic.isEmpty) {
      return ColoredBox(
        color: bgColor,
        child: Center(child: Icon(Icons.movie, color: iconColor)),
      );
    }
    return CachedNetworkImage(
      imageUrl: video.pic,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      placeholder: (_, __) => ColoredBox(
        color: bgColor,
        child: Center(child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )),
      ),
      errorWidget: (_, __, ___) => ColoredBox(
        color: bgColor,
        child: Center(child: Icon(Icons.broken_image, color: iconColor)),
      ),
    );
  }
}
