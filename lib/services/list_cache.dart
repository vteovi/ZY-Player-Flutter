import '../models/video.dart';
import 'zy_database.dart';

/// 视频列表（分类片单）本地缓存。
///
/// 痛点：首页 / 分类页每次打开都重新向源站拉取片单（这是**数据层**，与封面图片缓存
/// 是两回事），源站慢时整个网格要干等网络。这里把每个 (源, 分类) 的分页结果与
/// 元信息按页缓存到本地，做到：
///  1) 打开时先秒出上一次的片单（封面再走封面缓存，所以图文都秒出）；
///  2) 随后后台静默刷新，更新为最新内容。
///
/// 存储复用 [ZyDatabase]（shared_preferences），落在新增的 [DbNames.listcache] 库：
///  - 元信息 `meta:{siteKey}:{tid}` -> `{pagecount, recordcount, ts}`
///  - 分页结果 `page:{siteKey}:{tid}:{pg}` -> `{videos:[...]}`
///
/// 「重置软件」会 `clearDB()` 清空整个 shared_preferences，缓存一并清掉，无需单独处理。
class ListCache {
  ListCache._();

  /// 读取某 (源, 分类) 的元信息；没有或 pagecount 非法时返回 null
  static Future<CachedMeta?> getMeta(String siteKey, String tid) async {
    final item =
        await ZyDatabase.instance.get(DbNames.listcache, 'meta:$siteKey:$tid');
    if (item == null) return null;
    final pagecount = _toInt(item['pagecount'], 0);
    final recordcount = _toInt(item['recordcount'], 0);
    final ts = _toInt(item['ts'], 0);
    if (pagecount <= 0) return null;
    return CachedMeta(
      pagecount: pagecount,
      recordcount: recordcount,
      ts: ts,
    );
  }

  /// 写入元信息（含时间戳，便于将来做过期策略）
  static Future<void> putMeta(
    String siteKey,
    String tid,
    int pagecount,
    int recordcount,
  ) async {
    await ZyDatabase.instance.put(DbNames.listcache, <String, dynamic>{
      'key': 'meta:$siteKey:$tid',
      'pagecount': pagecount,
      'recordcount': recordcount,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 读取某 (源, 分类, 页码) 的片单；没有或解析失败返回 null
  static Future<List<Video>?> getPage(String siteKey, String tid, int pg) async {
    final item = await ZyDatabase.instance
        .get(DbNames.listcache, 'page:$siteKey:$tid:$pg');
    if (item == null) return null;
    final raw = item['videos'];
    if (raw is! List) return null;
    try {
      return raw
          .map((e) => Video.fromJson(e as Map<dynamic, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// 写入某 (源, 分类, 页码) 的片单
  static Future<void> putPage(
    String siteKey,
    String tid,
    int pg,
    List<Video> list,
  ) async {
    await ZyDatabase.instance.put(DbNames.listcache, <String, dynamic>{
      'key': 'page:$siteKey:$tid:$pg',
      'videos': list.map((v) => v.toJson()).toList(),
    });
  }

  /// 清空全部列表缓存（「重置软件」走 clearDB 已覆盖，这里保留以便将来单独清理）
  static Future<void> clearAll() async {
    await ZyDatabase.instance.removeAll(DbNames.listcache);
  }

  static int _toInt(dynamic v, int def) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }
}

/// 缓存的元信息：分页总数、片单总数、写入时间戳
class CachedMeta {
  final int pagecount;
  final int recordcount;
  final int ts;

  const CachedMeta({
    required this.pagecount,
    required this.recordcount,
    required this.ts,
  });
}
