import 'dart:async';

import 'image_cache.dart';

/// 后台预取封面图，缩短「片单秒出」到「封面也秒出」的距离。
///
/// 片单数据层已有本地缓存（ListCache），打开瞬间就能画出标题网格；但封面是图片，
/// 必须下载过一次才会进磁盘缓存。这里在片单数据就绪后**抢先**把封面拉进磁盘缓存，
/// 于是：① 本次打开后滚动、以及下次打开时这些封面直接读本地、不再转圈；② 下载在
/// 后台跑，与用户浏览视线错位，不打断操作。
///
/// 限制并发（[maxConcurrent]）避免一次性对源站发起几十条请求把连接挤爆、反而更慢。
class ImagePrefetch {
  ImagePrefetch._();

  static const int maxConcurrent = 6;

  /// 已在途的 URL（去重，避免同一张图被重复拉取）
  static final Set<String> _inflight = {};

  /// 抢先下载一批封面。本方法是“尽力而为”的后台任务：失败静默忽略，
  /// 调用方用 [unawaited] 触发即可，无需 await。
  static Future<void> prefetch(List<String> urls) async {
    final cm = AppImageCache.instance;
    final todo = urls
        .where((u) => u.isNotEmpty && !_inflight.contains(u))
        .toList();
    if (todo.isEmpty) return;
    _inflight.addAll(todo);
    try {
      for (var i = 0; i < todo.length; i += maxConcurrent) {
        final batch = todo.skip(i).take(maxConcurrent).toList();
        await Future.wait(
          batch.map((u) => cm.downloadFile(u).then((_) {}).catchError((_) {})),
        );
      }
    } finally {
      for (final u in todo) {
        _inflight.remove(u);
      }
    }
  }
}
