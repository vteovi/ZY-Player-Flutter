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

  /// 缓存结构版本号。
  ///
  /// v1 的分页方向是反的（从源站末页=最老的内容开始取），导致每个分类永远
  /// 显示同一批老片。v2 改为从 `pg=1`（最新）开始递增。旧缓存的 key 语义已经
  /// 不对了，升级后整体丢弃一次，避免首页继续拿老数据「秒出」。
  static const int _cacheVersion = 2;

  /// 版本校验只做一次；用 Future 缓存而不是 bool 标记，是为了让首页好几个分栏
  /// 同时初始化时都**等同一个清理动作完成**再读缓存 —— 否则先到的那个刚把标记
  /// 置真、清理还没跑完，后面的就直接读到即将被删掉的旧缓存了。
  static Future<void>? _versionReady;

  /// 首次访问时校验缓存版本，不一致就清空整个片单缓存库
  static Future<void> _ensureVersion() =>
      _versionReady ??= _doEnsureVersion();

  static Future<void> _doEnsureVersion() async {
    final item = await ZyDatabase.instance.get(DbNames.listcache, '__ver');
    final ver = item == null ? 0 : _toInt(item['v'], 0);
    if (ver == _cacheVersion) return;
    await ZyDatabase.instance.removeAll(DbNames.listcache);
    await ZyDatabase.instance.put(DbNames.listcache, <String, dynamic>{
      'key': '__ver',
      'v': _cacheVersion,
    });
  }

  /// 读取某 (源, 分类) 的元信息；没有或 pagecount 非法时返回 null
  static Future<CachedMeta?> getMeta(String siteKey, String tid) async {
    await _ensureVersion();
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
    await _ensureVersion();
    await ZyDatabase.instance.put(DbNames.listcache, <String, dynamic>{
      'key': 'meta:$siteKey:$tid',
      'pagecount': pagecount,
      'recordcount': recordcount,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 读取某 (源, 分类, 页码) 的片单；没有或解析失败返回 null
  static Future<List<Video>?> getPage(String siteKey, String tid, int pg) async {
    await _ensureVersion();
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
    await _ensureVersion();
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
