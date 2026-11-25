import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../utils/cover_cache.dart';
import '../utils/poster_ratio.dart';

/// 瀑布流列数：手机（不到 600 宽）固定 2 列，一眼能看清两张海报；
/// 平板 / 桌面按实际可用宽度铺，每列约 190dp，最多 8 列。
///
/// 用 floor 而不是 round：宽屏宁可列多一点、卡小一点，也不要出现一张特别胖的
/// 海报把整行撑歪（瀑布流靠列宽一致才好看）。
int waterfallColumnCount(double width) {
  if (width < 600) return 2;
  return (width / 190).floor().clamp(2, 8);
}

/// 取某张海报的封面比例，必要时顺手触发一次「读本地文件头」测量。
///
/// 量不出来时先用 [PosterRatio.fallback]（2:3）占位，量到后通过
/// [PosterRatio.revision] 通知瀑布流重排一次，卡片高度随之贴合真实海报。
double waterfallCoverRatio(String pic) {
  if (pic.isEmpty) return PosterRatio.fallback;
  final known = PosterRatio.of(pic);
  if (known != null) return known;
  // 本地已有封面文件（含预取落盘的）就能零成本量出比例；
  // 没文件说明这张图还没下载过，等预取下载完会再通知。
  final path = CoverCache.pathOf(pic);
  if (path != null) {
    unawaited(PosterRatio.measureFromFile(pic, path));
  }
  return PosterRatio.fallback;
}

/// 瀑布流容器：按海报实际比例不等高排布（不裁切）。
///
/// 用 [CustomScrollView] + [SliverMasonryGrid] 而不是 `MasonryGridView`，
/// 这样能：
/// ① 关掉 `addAutomaticKeepAlives`（与网格模式一致：长列表滚远后元素树不膨胀）；
/// ② 在末尾挂一条**横跨整行**的加载更多指示器（`MasonryGridView` 只能占一格）。
class WaterfallGrid extends StatefulWidget {
  final int columns;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? scrollController;

  /// 底部额外留白（首页右下角悬浮按钮会挡住最后一排）
  final double bottomInset;

  /// 列表末尾的附加行（加载更多指示器 / 到底提示），null 则没有
  final Widget? footer;

  const WaterfallGrid({
    super.key,
    required this.columns,
    required this.itemCount,
    required this.itemBuilder,
    this.scrollController,
    this.bottomInset = 0,
    this.footer,
  });

  @override
  State<WaterfallGrid> createState() => _WaterfallGridState();
}

class _WaterfallGridState extends State<WaterfallGrid> {
  @override
  void initState() {
    super.initState();
    // 图片量出真实比例后会 +1，这里重排一次让卡片高度贴合海报
    PosterRatio.revision.addListener(_onRatioChanged);
  }

  @override
  void dispose() {
    PosterRatio.revision.removeListener(_onRatioChanged);
    super.dispose();
  }

  void _onRatioChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: widget.scrollController,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            6,
            4,
            6,
            widget.footer == null ? 16 + widget.bottomInset : 8,
          ),
          sliver: SliverMasonryGrid(
            // 与网格模式同样的性能取舍：不保留滚出屏幕的元素
            delegate: SliverChildBuilderDelegate(
              widget.itemBuilder,
              childCount: widget.itemCount,
              addAutomaticKeepAlives: false,
            ),
            gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: widget.columns,
            ),
          ),
        ),
        if (widget.footer != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(0, 0, 0, 16 + widget.bottomInset),
              child: widget.footer,
            ),
          ),
      ],
    );
  }
}
