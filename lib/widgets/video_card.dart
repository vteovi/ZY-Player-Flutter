import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/video.dart';

/// 首页瀑布流卡片：封面 + 片名 + 分类/备注/年份
class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;

  const VideoCard({super.key, required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(6),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: SizedBox(
                width: double.infinity,
                child: _buildCover(),
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      video.type.isEmpty ? '其他' : video.type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: const Color(0xFF909399)),
                    ),
                  ),
                  if (video.note.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF1F0),
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
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: const Color(0xFF909399)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover() {
    if (video.pic.isEmpty) {
      return const ColoredBox(
        color: Color(0xFFEDEDED),
        child: Center(child: Icon(Icons.movie, color: Color(0xFFC0C4CC))),
      );
    }
    return CachedNetworkImage(
      imageUrl: video.pic,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      placeholder: (_, __) => const ColoredBox(
        color: Color(0xFFEDEDED),
        child: Center(child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )),
      ),
      errorWidget: (_, __, ___) => const ColoredBox(
        color: Color(0xFFEDEDED),
        child: Center(child: Icon(Icons.broken_image, color: Color(0xFFC0C4CC))),
      ),
    );
  }
}
