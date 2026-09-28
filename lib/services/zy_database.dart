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
}
