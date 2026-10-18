import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地数据库。
///
/// 与 uni-app 版 utils/database.js 一一对应：
/// - `ZY-{db}-DB` 保存该库下所有 item 的 key 列表
/// - `{db}-{key}` 保存单个 item
///
/// uni-app 可以直接把对象塞进 storage，这里统一序列化成 JSON 字符串存储。
class ZyDatabase {
  ZyDatabase._();

  static final ZyDatabase instance = ZyDatabase._();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  String _dbKey(String db) => 'ZY-$db-DB';

  String _itemKey(String db, String key) => '$db-$key';

  /// 获取某个库的全部 key
  Future<List<String>> getAllKeys(String db) async {
    final store = await _store;
    final raw = store.getString(_dbKey(db));
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 数据损坏时当作空库处理
    }
    return <String>[];
  }

  Future<void> _saveKeys(String db, List<String> keys) async {
    final store = await _store;
    await store.setString(_dbKey(db), jsonEncode(keys));
  }

  /// 检查 key 是否已存在
  Future<bool> containsKey(String db, String key) async {
    final keys = await getAllKeys(db);
    return keys.contains(key);
  }

  /// 新增一条记录，已存在则原样返回 false（对应 database.js 的 add）
  Future<bool> add(String db, Map<String, dynamic> item) async {
    final key = (item['key'] ?? '').toString();
    if (key.isEmpty) return false;
    if (await containsKey(db, key)) return false;
    final keys = await getAllKeys(db);
    keys.add(key);
    await _saveKeys(db, keys);
    final store = await _store;
    return store.setString(_itemKey(db, key), jsonEncode(item));
  }

  /// 更新一条记录，不存在则返回 false
  Future<bool> update(String db, Map<String, dynamic> item) async {
    final key = (item['key'] ?? '').toString();
    if (key.isEmpty) return false;
    if (!await containsKey(db, key)) return false;
    final store = await _store;
    return store.setString(_itemKey(db, key), jsonEncode(item));
  }

  /// 新增或更新
  Future<bool> put(String db, Map<String, dynamic> item) async {
    final key = (item['key'] ?? '').toString();
    if (key.isEmpty) return false;
    if (!await containsKey(db, key)) {
      final keys = await getAllKeys(db);
      keys.add(key);
      await _saveKeys(db, keys);
    }
    final store = await _store;
    return store.setString(_itemKey(db, key), jsonEncode(item));
  }

  /// 查询单条记录
  Future<Map<String, dynamic>?> get(String db, String key) async {
    final store = await _store;
    final raw = store.getString(_itemKey(db, key));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // ignore
    }
    return null;
  }

  /// 查询整库，保持 key 列表的插入顺序
  Future<List<Map<String, dynamic>>> getAll(String db) async {
    final keys = await getAllKeys(db);
    if (keys.isEmpty) return <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    for (final key in keys) {
      final item = await get(db, key);
      if (item != null) result.add(item);
    }
    return result;
  }

  /// 批量写入（upsert 合并）：已存在的 key 覆盖、新增的追加。
  /// 用于局域网同步把远端数据合并进本地库。返回成功写入（新增或更新）的条数。
  ///
  /// 写完后重排 key 列表，使同步过来的条目按**来源顺序**排在前面、接收端独有的
  /// 条目保持在后面（保留其原有相对顺序）。这样来源的排序（尤其是视频源的手动
  /// 排序 / 置顶 / 检测后重排结果）也能一并同步过来，而不是把新源全堆到末尾。
  Future<int> importRaw(String db, List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return 0;
    var count = 0;
    for (final item in items) {
      final key = (item['key'] ?? '').toString();
      if (key.isEmpty) continue;
      if (await put(db, item)) count++;
    }
    await _reorderKeysAfterImport(db, items);
    return count;
  }

  /// 导入后重排 key 列表：来源顺序在前、接收端独有在后。
  Future<void> _reorderKeysAfterImport(
    String db,
    List<Map<String, dynamic>> items,
  ) async {
    final sourceOrder = items
        .map((e) => (e['key'] ?? '').toString())
        .where((k) => k.isNotEmpty)
        .toList();
    if (sourceOrder.isEmpty) return;
    final keys = await getAllKeys(db);
    final sourceSet = sourceOrder.toSet();
    final reordered = <String>[];
    final seen = <String>{};
    // 1) 来源条目按来源相对顺序排前（去重）
    for (final k in sourceOrder) {
      if (seen.add(k)) reordered.add(k);
    }
    // 2) 接收端独有的条目排后（保持原有相对顺序）
    for (final k in keys) {
      if (!sourceSet.contains(k) && seen.add(k)) reordered.add(k);
    }
    await _saveKeys(db, reordered);
  }

  /// 移除单条记录
  Future<bool> remove(String db, String key) async {
    final keys = await getAllKeys(db);
    final index = keys.indexOf(key);
    if (index < 0) return false;
    keys.removeAt(index);
    await _saveKeys(db, keys);
    final store = await _store;
    await store.remove(_itemKey(db, key));
    return true;
  }

  /// 批量移除记录，返回**实际删除条数**。
  ///
  /// 与循环调用 [remove] 的区别：key 列表只重写一次（[remove] 每删一条就写一次），
  /// 删几十条死站时少掉大量磁盘写入。顺序不受影响 —— 剩下的 key 原样保留。
  Future<int> removeMany(String db, Iterable<String> targets) async {
    final drop = targets.toSet();
    if (drop.isEmpty) return 0;
    final keys = await getAllKeys(db);
    if (keys.isEmpty) return 0;
    final kept = keys.where((k) => !drop.contains(k)).toList();
    final removed = keys.length - kept.length;
    if (removed == 0) return 0;
    await _saveKeys(db, kept);
    final store = await _store;
    for (final key in keys) {
      if (drop.contains(key)) await store.remove(_itemKey(db, key));
    }
    return removed;
  }

  /// 清空整个库（库为空时返回 false，与 uni-app 版保持一致）
  Future<bool> removeAll(String db) async {
    final keys = await getAllKeys(db);
    if (keys.isEmpty) return false;
    for (final key in keys) {
      await remove(db, key);
    }
    final store = await _store;
    await store.remove(_dbKey(db));
    return true;
  }

  /// 清空全部数据
  Future<bool> clearDB() async {
    final store = await _store;
    return store.clear();
  }

  /// 初始化：库为空时用默认数据填充
  Future<bool> initDb(
    String db, {
    required Future<List<Map<String, dynamic>>> Function() defaults,
  }) async {
    final keys = await getAllKeys(db);
    if (keys.isNotEmpty) return false;
    await reset(db, defaults: defaults);
    return true;
  }

  /// 重置：清空后写回默认数据
  Future<void> reset(
    String db, {
    required Future<List<Map<String, dynamic>>> Function() defaults,
  }) async {
    await removeAll(db);
    final list = await defaults();
    for (final item in list) {
      await add(db, item);
    }
  }
}

/// 各个库的名称，避免散落的魔法字符串
class DbNames {
  static const String site = 'site';
  static const String setting = 'setting';
  static const String star = 'star';
  static const String history = 'history';
  static const String search = 'search';
  /// 分类片单缓存（每个 (源, 分类) 的分页结果与元信息），详见 list_cache.dart
  static const String listcache = 'listcache';
}
