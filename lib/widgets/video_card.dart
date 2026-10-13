import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/video.dart';
import '../utils/app_colors.dart';
import '../utils/image_cache.dart';

/// 首页卡片：封面 + 片名 + 分类/备注/年份（图上文下）。
///
/// 卡片布局在横 / 竖模式下相同，区别只在于网格给的宽高比：
/// 竖向 = 竖版海报比例；横向 = 横版（约 16:9）海报比例。
class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;

  /// 来源角标（全站搜索时显示站点名），null 则不显示
  final String? sourceLabel;

  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.sourceLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(6),
      // 底色交给 CardTheme（深色下是纯黑），这里不再写死
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
    final subColor = isDark ? AppColors.darkSubText : AppColors.lightSubText;
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
              color: isDark ? const Color(0xFF2A1416) : const Color(0xFFFFF1F0),
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
        isDark ? AppColors.darkSurface : const Color(0xFFEDEDED);
    final iconColor =
        isDark ? AppColors.darkCoverIcon : const Color(0xFFC0C4CC);
    final Widget image;
    if (video.pic.isEmpty) {
      image = ColoredBox(
        color: bgColor,
        child: Center(child: Icon(Icons.movie, color: iconColor)),
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: video.pic,
        cacheManager: AppImageCache.instance,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        // 限制内存解码尺寸：海报原图往往 600×900+，卡片只显示 ~150dp 宽，
        // 解码到 480px 宽足够清晰，能大幅降低内存占用与首屏解码耗时，滚动更跟手。
        memCacheWidth: 480,
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
    final label = sourceLabel;
    if (label == null || label.isEmpty) return image;
    // 来源角标：贴在海报左上角
    return Stack(
      children: [
        Positioned.fill(child: image),
        Positioned(
          left: 0,
          top: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            color: Colors.black45,
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                height: 1.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
