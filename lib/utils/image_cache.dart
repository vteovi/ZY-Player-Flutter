import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 共享的图片磁盘缓存管理器。
///
/// `cached_network_image` 自带的 [DefaultCacheManager] 只保留**最近 100 张**
/// （`maxNrOfCacheObjects: 100`，LRU 淘汰）。视频源站动辄上千部海报，往下翻过
/// 100 张后前面看过的封面就被挤出缓存，滚回去又得重新联网下载——这是「每次打开
/// 都要重新加载图片」真正的根因（首见必走网络无法避免，但翻过的理应秒出）。
///
/// 这里用独立 key 的自定义 [CacheManager] 把容量提到 2000、过期延长到 90 天，
/// 让看过的封面跨启动 / 跨滚动都能直接读本地缓存，网络请求量大幅下降。
///
/// 三处封面加载（列表网格、详情大图、详情背景）都通过 `cacheManager` 指向它。
class AppImageCache {
  AppImageCache._();

  static final CacheManager instance = CacheManager(
    Config(
      'zyPlayerImageCache',
      stalePeriod: const Duration(days: 90),
      maxNrOfCacheObjects: 2000,
    ),
  );
}
