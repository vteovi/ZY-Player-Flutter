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
  /// 用于局域网同步把远端数据合并进本地库。
  ///
  /// 返回**实际发生变化**（新增，或内容确实不同）的条数；同一个库反复同步时
  /// 返回 0，因为没有任何一个字节需要落盘。
  ///
  /// 为什么要先比对内容再写：Windows 端的 shared_preferences 是纯 Dart 实现，
  /// **每次 `setString` 都会把整份偏好重新 `json.encode` 一次，再
  /// `writeAsStringSync` 把整个文件重写一遍**（同步阻塞 UI 线程）。逐条 put
  /// 等于「N 次全量序列化 + N 次全量写盘」，几百条历史就能让界面卡住十几秒。
  /// 先比对、只写差异之后，重复同步退化成纯内存比较，一次磁盘写都没有。
  ///
  /// 写完后重排 key 列表，使同步过来的条目按**来源顺序**排在前面、接收端独有的
  /// 条目保持在后面（保留其原有相对顺序）。这样来源的排序（尤其是视频源的手动
  /// 排序 / 置顶 / 检测后重排结果）也能一并同步过来，而不是把新源全堆到末尾。
  /// 顺序没变就不写，key 列表全程只落盘一次。
  /// [isCancelled] 在每条之间检查一次，返回 true 就停止继续写（已写的保留，
  /// 因为是 upsert，中断不会留下坏数据，再同步一次即可补齐）。
  Future<int> importRaw(
    String db,
    List<Map<String, dynamic>> items, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (items.isEmpty) return 0;
    final store = await _store;
    final oldKeys = await getAllKeys(db);

    // key -> 待写入的新内容。内容与本地一致的条目不进表，直接跳过。
    final changed = <String, String>{};
    final sourceOrder = <String>[];
    final seenSource = <String>{};

    for (final item in items) {
      final key = (item['key'] ?? '').toString();
      if (key.isEmpty) continue;
      if (seenSource.add(key)) sourceOrder.add(key);
      final encoded = jsonEncode(item);
      // getString 走的是内存缓存，不产生磁盘 IO
      if (store.getString(_itemKey(db, key)) != encoded) {
        changed[key] = encoded;
      }
    }

    // 目标顺序：来源条目按来源顺序排前，本地独有的按原有相对顺序跟在后
    final next = <String>[];
    final seen = <String>{};
    for (final key in sourceOrder) {
      if (seen.add(key)) next.add(key);
    }
    for (final key in oldKeys) {
      if (seen.add(key)) next.add(key);
    }
    var sameOrder = next.length == oldKeys.length;
    if (sameOrder) {
      for (var i = 0; i < next.length; i++) {
        if (next[i] != oldKeys[i]) {
          sameOrder = false;
          break;
        }
      }
    }

    if (changed.isEmpty && sameOrder) return 0;

    final total = changed.length;
    if (total > 0) onProgress?.call(0, total);
    var done = 0;

    // Windows 端的 setString 内部是 `json.encode(整份偏好)` + `writeAsStringSync`
    // —— 全是**同步**操作，await 它只会排一个 microtask，不会把控制权交还给
    // 事件循环。几百条连着写就是一个长达数十秒的 microtask 链：界面一帧都不刷、
    // 触摸事件排不上队，取消按钮自然也按不动。
    // 所以每写一批就主动让出一次：条数到阈值、或累计耗时超预算都算一批。
    var lastYield = DateTime.now();
    final written = <String>{};
    for (final entry in changed.entries) {
      if (isCancelled?.call() ?? false) break;
      await store.setString(_itemKey(db, entry.key), entry.value);
      written.add(entry.key);
      done++;
      // 每 5 条报一次，界面上的数字能一直在走，不至于看着像死了
      if (done % 5 == 0 || done == total) onProgress?.call(done, total);

      final now = DateTime.now();
      if (done % _yieldEvery == 0 ||
          now.difference(lastYield).inMilliseconds >= _yieldBudgetMs) {
        lastYield = now;
        // 让出到事件循环（timer 是 event，microtask 不是），UI 才能喘口气
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (!sameOrder) {
      // 中途取消时，索引里不能出现「还没真正写进去的新 key」——否则条目和
      // 索引对不上。没取消时 written 已是全部变化项，这个过滤是恒等的。
      final valid = <String>{...written, ...oldKeys};
      await _saveKeys(db, next.where(valid.contains).toList());
    }
    return done;
  }

  /// 单次连续写入的时间预算（毫秒）。超过就先让出一次。
  ///
  /// 取 24ms 是为了压在 16ms 一帧的两倍以内：即使某一条特别大，一帧的卡顿也
  /// 只有一个，用户感觉不到。文件越大单条越贵，这个值会让让出变得更频繁。
  static const int _yieldBudgetMs = 24;

  /// 不管多快，每写这么多条也让出一次（兜底，防止按条数算才让出时批次太大）。
  static const int _yieldEvery = 12;

  /// 只重写 key 列表的顺序，**不动条目本身**。
  ///
  /// 以前"重排"是在上层用 `removeAll` + 逐条 `add` 模拟的，那条路很脆：
  /// `add` 遇到已存在的 key 会静默返回 false，一旦库里有重复 key（并发写入
  /// 留下的脏数据）条目就被永久吃掉 —— 表现就是「检测一下，源少了几条」。
  /// 这里改成只写顺序：条目一条不碰，[ordered] 里没覆盖到的旧 key 自动补到
  /// 末尾，任何情况下都不会丢源。
  Future<void> reorder(String db, List<String> ordered) async {
    final existing = await getAllKeys(db);
    if (existing.isEmpty) return;
    final existingSet = existing.toSet();
    final seen = <String>{};
    final next = <String>[];
    for (final key in ordered) {
      if (key.isEmpty || !existingSet.contains(key)) continue;
      if (seen.add(key)) next.add(key);
    }
    // 兜底：调用方给的列表不完整（检测期间新增/删除过源）时，剩下的原样跟上
    for (final key in existing) {
      if (seen.add(key)) next.add(key);
    }
    if (next.length == existing.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i] != existing[i]) {
          same = false;
          break;
        }
      }
      if (same) return; // 顺序没变，省一次磁盘写
    }
    await _saveKeys(db, next);
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
