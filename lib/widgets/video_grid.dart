import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import 'common_widgets.dart';
import 'video_card.dart';

/// 网格的列数与卡片比例。
///
/// 真实网格（[VideoGridView]）与骨架屏（[VideoGridSkeleton]）**共用这一份策略**，
/// 保证占位卡和真实卡形状完全一致，数据到达时不会跳版。
SliverGridDelegate videoGridDelegate(BuildContext context) {
  final landscape = context.watch<AppState>().config.landscapeCard;
  if (landscape) {
    // 横版海报卡片：手机竖屏（<420）1 列，平板 2 列，更宽屏幕 3+ 列
    return const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 420,
      childAspectRatio: 1.38,
      crossAxisSpacing: 0,
      mainAxisSpacing: 0,
    );
  }
  // 竖向卡片：列数随宽度递增，宽屏多列、窄屏保底 2 列
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
    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
      itemCount: videos.length + (loadingMore ? 1 : 0),
      gridDelegate: videoGridDelegate(context),
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

/// 网格骨架屏：加载中用与真实卡片同形的占位块，形状跟着 [videoGridDelegate] 走。
///
/// 取代原来的「灰黑遮罩 + 居中转圈」——
/// 遮罩会把整块区域压暗，而首次进分栏时底下本来就是空的，
/// 看上去就是「切一下就变灰」，观感很差；骨架屏则让加载感连贯、不闪白也不发灰。
class VideoGridSkeleton extends StatefulWidget {
  /// 占位卡数量，默认 8 个（手机竖屏 2 列即 4 行）
  final int itemCount;

  const VideoGridSkeleton({super.key, this.itemCount = 8});

  @override
  State<VideoGridSkeleton> createState() => _VideoGridSkeletonState();
}

class _VideoGridSkeletonState extends State<VideoGridSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color base = isDark ? const Color(0xFF2A2A2C) : const Color(0xFFE7EAEE);
    final Color highlight =
        isDark ? const Color(0xFF38383D) : const Color(0xFFF3F5F8);
    // 在 build 期取一次（含 watch 依赖），别放进 AnimatedBuilder 里反复读
    final delegate = videoGridDelegate(context);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        final color = Color.lerp(base, highlight, t)!;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.itemCount,
          gridDelegate: delegate,
          itemBuilder: (context, _) => Card(
            clipBehavior: Clip.antiAlias,
            margin: const EdgeInsets.all(6),
            color: isDark ? const Color(0xFF1E1E20) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: ColoredBox(color: color),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: _bar(color, height: 12, widthFactor: 0.82),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: _bar(color, height: 10, widthFactor: 0.5),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 文字条占位（片名行 / 分类年份行）
  Widget _bar(Color color, {required double height, required double widthFactor}) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    );
  }
}
