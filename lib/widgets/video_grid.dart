import 'package:flutter/material.dart';

import '../models/video.dart';
import 'common_widgets.dart';
import 'video_card.dart';

/// 视频网格（首页分类页、搜索结果共用）。根据屏幕宽度自适应列数，
/// 大屏宽屏多出几列、卡片更大，但不会无限变宽（限制每行列数上限）。
class VideoGridView extends StatelessWidget {
  final List<Video> videos;
  final ScrollController? scrollController;
  final bool loadingMore;
  final void Function(Video) onTap;

  const VideoGridView({
    super.key,
    required this.videos,
    this.scrollController,
    this.loadingMore = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      return const EmptyHint(
        message: '该分类下暂无资源',
        icon: Icons.search_off,
      );
    }
    // 列数随宽度递增，宽屏多列、窄屏保底 2 列
    final w = MediaQuery.of(context).size.width;
    final columns = switch (w) {
      >= 1600 => 8,
      >= 1280 => 6,
      >= 960 => 5,
      >= 720 => 4,
      >= 520 => 3,
      _ => 2,
    };
    final maxExtent = (w / columns).clamp(150.0, 300.0);
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
      itemCount: videos.length + (loadingMore ? 1 : 0),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: 0.62,
        crossAxisSpacing: 0,
        mainAxisSpacing: 0,
      ),
      itemBuilder: (context, index) {
        if (index >= videos.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final video = videos[index];
        return VideoCard(video: video, onTap: () => onTap(video));
      },
    );
  }
}

/// 视频网格的便捷构造（无滚动控制器、不加载更多），用于一次性结果展示。
Widget buildVideoGrid({
  required BuildContext context,
  required List<Video> videos,
  ScrollController? scrollController,
  bool loadingMore = false,
  required void Function(Video) onTap,
}) =>
    VideoGridView(
      videos: videos,
      scrollController: scrollController,
      loadingMore: loadingMore,
      onTap: onTap,
    );
