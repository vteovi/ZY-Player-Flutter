import 'dart:async';

import 'cover_cache.dart';
import 'image_cache.dart';
import 'poster_ratio.dart';

/// 后台预取封面图，缩短「片单秒出」到「封面也秒出」的距离。
///
/// 片单数据层已有本地缓存（ListCache），打开瞬间就能画出标题网格；但封面是图片，
/// 必须下载过一次才会进磁盘缓存。这里在片单数据就绪后**抢先**把封面拉进磁盘缓存，
/// 于是：① 本次打开后滚动、以及下次打开时这些封面直接读本地、不再转圈；② 下载在
/// 后台跑，与用户浏览视线错位，不打断操作。
///
/// 限制并发（[maxConcurrent]）避免一次性对源站发起几十条请求把连接挤爆、反而更慢。
/// 首页十几个分栏同时起来时会各发一次预取，所以还加了一条**全局队列**：
/// 同一时刻只跑一批，否则 6 张 × N 栏 = 几十条并发，接口请求全被挤慢。
class ImagePrefetch {
  ImagePrefetch._();

  /// 全局同时在下的图张数（跨分栏共享，见 [_queue]）
  static const int maxConcurrent = 6;

  /// 已在途的 URL（去重，避免同一张图被重复拉取）
  static final Set<String> _inflight = {};

  /// 串行队列：本次预取排在上一次后面，保证全局并发不炸
  static Future<void> _queue = Future<void>.value();

  /// 队列里还有几个任务（用来判断「是不是冷启动的第一批」）
  static int _queued = 0;

  /// 抢先下载一批封面。本方法是“尽力而为”的后台任务：失败静默忽略，
  /// 调用方用 [unawaited] 触发即可，无需 await。
  ///
  /// [delay] 给一个起跑延迟：冷启动时首页十几个分类的**接口请求**才是关键路径，
  /// 一上来就并发拉二三十张封面会跟它们抢带宽 / 抢源站连接，接口更容易超时，
  /// 表现就是「打开先空白、然后弹重试」。让接口先走，图片晚几百毫秒再追。
  /// 只有队列空闲时的第一批才等这个延迟 —— 不然每栏都等一遍，后面的封面会越拖越晚。
  ///
  /// 每张图落盘后都会把「URL → 真实文件路径」记进 [CoverCache]：下次冷启动
  /// 卡片就能同步拿到文件、第一帧直接出海报，不用再走异步查缓存的流程。
  /// 已在磁盘上的图走 [CacheManager.getSingleFile] 是零网络的，等于顺手补齐索引。
  static Future<void> prefetch(List<String> urls, {Duration? delay}) {
    final wait = (delay != null && _queued == 0) ? delay : null;
    _queued++;
    final task = _queue.then((_) => _run(urls, wait));
    // 队列本身不能被一次失败打断：吞掉错误，只把结果交给调用方
    _queue = task
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _queued--);
    return task;
  }

  static Future<void> _run(List<String> urls, Duration? delay) async {
    final cm = AppImageCache.instance;
    // 已经有本地文件、能在第一帧直接画出来的，就不用再碰一次缓存查询 ——
    // 冷启动时这一步能把绝大多数「其实早就存过」的图直接排除掉。
    final todo = urls
        .where((u) =>
            u.isNotEmpty &&
            !_inflight.contains(u) &&
            CoverCache.pathOf(u) == null)
        .toList();
    if (todo.isEmpty) return;
    _inflight.addAll(todo);
    try {
      if (delay != null && delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      for (var i = 0; i < todo.length; i += maxConcurrent) {
        final batch = todo.skip(i).take(maxConcurrent).toList();
        await Future.wait(
          batch.map((u) async {
            try {
              final file = await cm.getSingleFile(u);
              CoverCache.remember(u, file.path);
              // 顺手量一次海报原始比例（只读前 64KB 文件头，不解码、零网络），
              // 供瀑布流按真实比例排卡片；量不到的等下次有文件再补。
              unawaited(PosterRatio.measureFromFile(u, file.path));
            } catch (_) {
              // 单张失败不影响这一批
            }
          }),
        );
      }
    } finally {
      for (final u in todo) {
        _inflight.remove(u);
      }
    }
  }
}
