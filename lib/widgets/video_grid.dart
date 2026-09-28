import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import 'common_widgets.dart';
import 'video_card.dart';

/// 视频网格（首页分类页、搜索结果共用）。
///
/// 竖向模式：竖版海报，列数随屏幕宽度自适应（2~8 列）。
/// 横向模式（设置里开启）：海报横版（约 16:9）图上文下，
/// 手机竖屏每行一个，平板大屏自适应多列（每列上限 420 宽）。
class VideoGridView extends StatelessWidget {
  final List<Video> videos;
  final ScrollController? scrollController;
  final bool loadingMore;
  final void Function(Video) onTap;

  /// 可选：结果来源角标（全站搜索时显示站点名），返回 null 则不显示
  final String? Function(Video)? labelOf;

  const VideoGridView({
    super.key,
    required this.videos,
    this.scrollController,
    this.loadingMore = false,
    required this.onTap,
    this.labelOf,
  });

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      return const EmptyHint(
        message: '该分类下暂无资源',
        icon: Icons.search_off,
      );
    }
    final landscape =
        context.watch<AppState>().config.landscapeCard;
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
      itemCount: videos.length + (loadingMore ? 1 : 0),
      gridDelegate: landscape
          ? const SliverGridDelegateWithMaxCrossAxisExtent(
              // 横版海报卡片：手机竖屏（<420）1 列，平板 2 列，更宽屏幕 3+ 列
              maxCrossAxisExtent: 420,
              childAspectRatio: 1.38,
              crossAxisSpacing: 0,
              mainAxisSpacing: 0,
            )
          : _portraitDelegate(context),
      itemBuilder: (context, index) {
        if (index >= videos.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final video = videos[index];
        return VideoCard(
          video: video,
          sourceLabel: labelOf?.call(video),
          onTap: () => onTap(video),
        );
      },
    );
  }

  /// 竖向卡片：列数随宽度递增，宽屏多列、窄屏保底 2 列
  SliverGridDelegateWithMaxCrossAxisExtent _portraitDelegate(
    BuildContext context,
  ) {
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
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxExtent,
      childAspectRatio: 0.62,
      crossAxisSpacing: 0,
      mainAxisSpacing: 0,
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
  String? Function(Video)? labelOf,
}) =>
    VideoGridView(
      videos: videos,
      scrollController: scrollController,
      loadingMore: loadingMore,
      onTap: onTap,
      labelOf: labelOf,
    );
