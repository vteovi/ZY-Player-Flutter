import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../utils/app_colors.dart';
import 'common_widgets.dart';
import 'video_card.dart';
import 'waterfall_grid.dart';

/// 横版封面的宽高比：16:10（比 16:9 略微高一点，横版海报上下不容易被裁）。
const double _landscapeCoverRatio = 16 / 10;

/// 卡片封面**下方**两行文字占的固定高度，与 [VideoCard] / [RecordCard] 对齐：
/// 片名行 8+20，元信息行 4+16+8。
///
/// ⚠️ 网格给的是**整张卡片**的宽高比，封面只是卡片的一部分。想让封面是某个
/// 比例，必须把这几十像素的文字高度从卡片高度里扣掉再换算，否则横屏大屏上
/// 封面会明显偏扁（列越宽偏得越多）。
const double _cardCaptionHeight = 56;

/// 横版卡片网格：封面按 16:10 排布。
///
/// [availableWidth] 是网格**实际可用宽度**（已扣掉外层 padding / 侧栏），
/// 卡宽由它推出来，保证任何屏幕宽度下封面都接近 16:10。
SliverGridDelegateWithMaxCrossAxisExtent landscapeGridDelegate(
  double availableWidth,
) {
  const double maxExtent = 420; // 单列上限：再宽就多排一列
  const double cardMargin = 12; // Card 左右各 6
  final width = availableWidth > 0 ? availableWidth : 360.0;
  // 与 SliverGridDelegateWithMaxCrossAxisExtent 的列数算法保持一致
  final columns = (width / maxExtent).ceil().clamp(1, 12);
  final tile = width / columns;
  // 格子高度 = 封面 + 上下 margin(12) + 两行文字(56)；封面高度由**卡宽**定
  final coverHeight = (tile - cardMargin) / _landscapeCoverRatio;
  final cardHeight = coverHeight + cardMargin + _cardCaptionHeight;
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: maxExtent,
    childAspectRatio: tile / cardHeight,
    crossAxisSpacing: 0,
    mainAxisSpacing: 0,
  );
}

/// 竖向卡片网格：列数随宽度递增，宽屏多列、窄屏保底 2 列。
SliverGridDelegateWithMaxCrossAxisExtent portraitGridDelegate(double width) {
  final columns = switch (width) {
    >= 1600 => 8,
    >= 1280 => 6,
    >= 960 => 5,
    >= 720 => 4,
    >= 520 => 3,
    _ => 2,
  };
  final maxExtent = (width / columns).clamp(150.0, 300.0);
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
/// 横向模式（设置里开启）：海报横版 **16:10** 图上文下，
/// 手机竖屏每行一个，平板大屏自适应多列（每列上限 420 宽）。
class VideoGridView extends StatelessWidget {
  final List<Video> videos;
  final ScrollController? scrollController;
  final bool loadingMore;
  final void Function(Video) onTap;

  /// 可选：结果来源角标（全站搜索时显示站点名），返回 null 则不显示
  final String? Function(Video)? labelOf;

  /// 底部额外留白。首页右下角有悬浮按钮时会挡住最后一排的右下角，
  /// 传一个按钮高度让内容能滚过去（默认 0，搜索结果等场景不需要）。
  final double bottomInset;

  /// 网格之后的整行底栏（「加载更多」按钮 / 「已全部加载」提示）。
  ///
  /// 必须是**全宽**的：GridView 的每个格子只是一个单元格宽，把按钮塞进格子
  /// 里会被挤成窄条，所以这里改用 CustomScrollView + SliverToBoxAdapter。
  final Widget? footer;

  const VideoGridView({
    super.key,
    required this.videos,
    this.scrollController,
    this.loadingMore = false,
    required this.onTap,
    this.labelOf,
    this.bottomInset = 0,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      return const EmptyHint(message: '该分类下暂无资源', icon: Icons.search_off);
    }
    // 显示模式在 build 阶段读一次；布局阶段（LayoutBuilder 内）不能再读
    // InheritedWidget，否则会触发「依赖注册发生在 layout」的断言。
    final mode = context.select<AppState, ViewMode>((s) => s.config.viewMode);
    final screenWidth = MediaQuery.of(context).size.width;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 用**真实可用宽度**算卡片比例：大屏带侧栏时 MediaQuery 会偏大，
        // 按它算会让封面比设定值更扁。
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth -
                  12 // GridView 左右各 6
            : screenWidth - 12;
        // 底栏：显式传入的 footer 优先，否则用内建的「加载中」转圈
        final tail =
            footer ??
            (loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : null);
        if (mode == ViewMode.waterfall) {
          final columns = waterfallColumnCount(available);
          final colWidth = available / columns;
          final memW = (colWidth * 2).round().clamp(300, 480);
          return WaterfallGrid(
            columns: columns,
            itemCount: videos.length,
            scrollController: scrollController,
            bottomInset: bottomInset,
            footer: tail,
            itemBuilder: (context, index) {
              final video = videos[index];
              return VideoCard(
                key: ValueKey(video.id),
                video: video,
                sourceLabel: labelOf?.call(video),
                memCacheWidth: memW,
                // 按海报实测比例定高：比例准了 BoxFit.cover 就不裁切
                coverRatio: waterfallCoverRatio(video.pic),
                onTap: () => onTap(video),
              );
            },
          );
        }
        final delegate = mode == ViewMode.landscape
            ? landscapeGridDelegate(available)
            : portraitGridDelegate(available);
        // 列宽决定封面解码尺寸：屏幕越宽单列越宽，但解码像素按显示尺寸的 ~2 倍即可，
        // 平板大屏不盲目用高位图，能省下大量 GPU 纹理内存、滚动更跟手。
        final memW = (delegate.maxCrossAxisExtent * 2).round().clamp(300, 480);
        return CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                6,
                4,
                6,
                tail == null ? 16 + bottomInset : 0,
              ),
              sliver: SliverGrid(
                gridDelegate: delegate,
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final video = videos[index];
                    return VideoCard(
                      key: ValueKey(video.id),
                      video: video,
                      sourceLabel: labelOf?.call(video),
                      memCacheWidth: memW,
                      onTap: () => onTap(video),
                    );
                  },
                  childCount: videos.length,
                  // 关键性能项：关掉「自动保留滚出屏幕的元素」。列表一长，保留的元素
                  // 会无限膨胀元素树（平板 8 列时膨胀速度是手机的 8 倍），导致滑动越远
                  // 越卡甚至滑不动。单元格是无状态、重建极轻的，关掉反而更顺。
                  addAutomaticKeepAlives: false,
                ),
              ),
            ),
            if (tail != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 8 + bottomInset),
                  child: tail,
                ),
              ),
          ],
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
  double bottomInset = 0,
  Widget? footer,
}) => VideoGridView(
  videos: videos,
  scrollController: scrollController,
  loadingMore: loadingMore,
  onTap: onTap,
  labelOf: labelOf,
  bottomInset: bottomInset,
  footer: footer,
);

/// 网格骨架屏：加载中用与真实卡片同形的占位块，形状跟着
/// [landscapeGridDelegate] / [portraitGridDelegate] 走。
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
    // 骨架屏要靠色块可见来表达"正在加载"，所以深色下也不能纯黑
    final Color base = isDark
        ? AppColors.darkSkeletonLow
        : AppColors.lightSkeletonLow;
    final Color highlight = isDark
        ? AppColors.darkSkeletonHigh
        : AppColors.lightSkeletonHigh;
    // 在 build 期取一次（含 select 依赖），别放进 AnimatedBuilder / LayoutBuilder
    // 里反复读 —— 布局阶段注册依赖会触发断言。
    final mode = context.select<AppState, ViewMode>((s) => s.config.viewMode);
    final screenWidth = MediaQuery.of(context).size.width;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth - 12
            : screenWidth - 12;
        final delegate = mode == ViewMode.landscape
            ? landscapeGridDelegate(available)
            : portraitGridDelegate(available);
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(_controller.value);
            final color = Color.lerp(base, highlight, t)!;
            if (mode == ViewMode.waterfall) {
              // 瀑布流骨架：占位块按默认海报比例排，切换模式时形状不会突然变
              return WaterfallGrid(
                columns: waterfallColumnCount(available),
                itemCount: widget.itemCount,
                itemBuilder: (context, _) => Card(
                  clipBehavior: Clip.antiAlias,
                  margin: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 2 / 3,
                        child: ColoredBox(color: color),
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
            }
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.itemCount,
              gridDelegate: delegate,
              itemBuilder: (context, _) => Card(
                clipBehavior: Clip.antiAlias,
                margin: const EdgeInsets.all(6),
                // 底色交给 CardTheme（深色下是纯黑）
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
      },
    );
  }

  /// 文字条占位（片名行 / 分类年份行）
  Widget _bar(
    Color color, {
    required double height,
    required double widthFactor,
  }) {
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
