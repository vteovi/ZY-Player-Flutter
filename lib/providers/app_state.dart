import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../services/http_service.dart';
import '../services/source_import.dart';
import '../services/system_control.dart';
import '../services/zy_database.dart';
import '../utils/constants.dart';

/// 全应用共享状态：视频源、收藏、历史、配置
class AppState extends ChangeNotifier {
  bool _ready = false;
  bool get ready => _ready;

  List<Site> _sites = <Site>[];
  List<Site> get sites => List.unmodifiable(_sites);

  /// 启用的视频源，首页站点下拉只用这些
  List<Site> get activeSites =>
      _sites.where((s) => s.isActive).toList(growable: false);

  AppConfig _config = const AppConfig();
  AppConfig get config => _config;

  List<RecordItem> _stars = <RecordItem>[];
  List<RecordItem> get stars => List.unmodifiable(_stars);

  List<RecordItem> _histories = <RecordItem>[];
  List<RecordItem> get histories => List.unmodifiable(_histories);

  /// 应用启动：初始化数据库 + 载入全部数据
  Future<void> bootstrap() async {
    await ZyDatabase.instance.initDb(
      DbNames.site,
      defaults: _defaultSiteData,
    );
    await ZyDatabase.instance.initDb(
      DbNames.setting,
      defaults: _defaultSettingData,
    );
    await refresh();
    _ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    await Future.wait([loadSites(), loadSetting(), loadStars(), loadHistories()]);
    notifyListeners();
  }

  /// 重新从存储加载全部数据并刷新内存（备份恢复后调用）。
  Future<void> reloadAll() async {
    await Future.wait([loadSites(), loadSetting(), loadStars(), loadHistories()]);
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // 默认数据（来自 assets）
  // --------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _defaultSiteData() async {
    final raw = await rootBundle.loadString(AppConstants.defaultSiteAsset);
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  Future<List<Map<String, dynamic>>> _defaultSettingData() async {
    final raw = await rootBundle.loadString(AppConstants.defaultSettingAsset);
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return <Map<String, dynamic>>[
      {'id': 0, 'key': 'config'},
    ];
  }

  // --------------------------------------------------------------------------
  // 视频源
  // --------------------------------------------------------------------------

  Future<void> loadSites() async {
    final list = await ZyDatabase.instance.getAll(DbNames.site);
    _sites = list.map(Site.fromJson).toList();
    notifyListeners();
  }

  Site? siteOf(String key) {
    for (final s in _sites) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// 把收藏 / 历史记录的 `{siteKey}-{videoId}` 拆成 (siteKey, videoId)。
  ///
  /// ⚠️ 站点 key 是 **UUID**（自带 4 个连字符），按第一个连字符切会切出一个不存在的
  /// 站点 —— 收藏页点进去就报「获取详情失败」。
  /// 这里从右往左找**第一个能在源列表里匹配上**的前缀，
  /// 即使 videoId 里含连字符也能正确拆开；都匹配不上时退回按最后一个连字符切。
  List<String> resolveRecordKey(String key) {
    const dash = 0x2D; // '-'
    for (var i = key.length - 1; i > 0; i--) {
      if (key.codeUnitAt(i) != dash) continue;
      final siteKey = key.substring(0, i);
      if (siteOf(siteKey) != null) return [siteKey, key.substring(i + 1)];
    }
    return RecordItem.splitKey(key);
  }

  /// 启用 / 停用某个源
  Future<void> toggleSite(Site site, bool value) async {
    await ZyDatabase.instance.remove(DbNames.site, site.key);
    await ZyDatabase.instance.add(DbNames.site, site.copyWith(isActive: value).toJson());
    await loadSites();
  }

  /// 置顶某个源（重写整库以保证顺序）
  Future<void> pinSite(Site site) async {
    final list = List<Site>.from(_sites);
    final index = list.indexWhere((s) => s.key == site.key);
    if (index <= 0) return;
    final target = list.removeAt(index);
    list.insert(0, target);
    await ZyDatabase.instance.removeAll(DbNames.site);
    for (final s in list) {
      await ZyDatabase.instance.add(DbNames.site, s.toJson());
    }
    await loadSites();
  }

  /// 批量启停源（源可用性检测后自动停用失效源用）。
  ///
  /// 用 `put`（upsert）逐条写，比 [toggleSite] 的 remove + add 少一半 IO；
  /// 状态本来就一致的条目直接跳过。
  Future<void> setSitesActive(Iterable<Site> targets, bool active) async {
    var changed = false;
    for (final s in targets) {
      if (s.isActive == active) continue;
      await ZyDatabase.instance.put(
        DbNames.site,
        s.copyWith(isActive: active).toJson(),
      );
      changed = true;
    }
    if (changed) await loadSites();
  }

  /// 按给定顺序重写源库（只调顺序，不改启用状态）。
  /// 「检测全部」结束后把可用源排前、不可用排后用。
  Future<void> reorderSites(List<Site> ordered) async {
    await ZyDatabase.instance.removeAll(DbNames.site);
    for (final s in ordered) {
      await ZyDatabase.instance.add(DbNames.site, s.toJson());
    }
    await loadSites();
  }

  /// 批量删除源（源管理页「清除死站」用），返回实际删除数量。
  ///
  /// 走 [ZyDatabase.removeMany]，key 列表只重写一次；
  /// 剩下的源保持原有顺序（含置顶）。
  Future<int> removeSites(Iterable<Site> targets) async {
    final removed = await ZyDatabase.instance.removeMany(
      DbNames.site,
      targets.map((s) => s.key),
    );
    if (removed > 0) await loadSites();
    return removed;
  }

  /// 导入视频源（配置地址），与现有源**合并**（按 key 更新/追加，不清空已有源）。
  ///
  /// 区别于早期的「覆盖」导入：同名 key 的源被新数据更新，其余追加到现有源之后；
  /// 需要插件的 spider 源在 [SourceImport.parse] 中已被跳过。
  ///
  /// 返回导入摘要（新增 / 更新 / 跳过数量、识别到的格式、失败原因），
  /// 供源管理页给出准确反馈。
  Future<ImportSummary> importSites(String url) async {
    final parsed = await HttpService.instance.importSites(url);
    if (parsed.sites.isEmpty) return parsed;

    var added = 0;
    var updated = 0;
    for (final site in parsed.sites) {
      final existed =
          await ZyDatabase.instance.containsKey(DbNames.site, site.key);
      await ZyDatabase.instance.put(DbNames.site, site.toJson());
      if (existed) {
        updated++;
      } else {
        added++;
      }
    }
    await loadSites();
    return ImportSummary(
      sites: parsed.sites,
      skipped: parsed.skipped,
      format: parsed.format,
      message: parsed.message,
      added: added,
      updated: updated,
    );
  }

  /// 从 TVBox / ZYFun 的 JSON 文本导入视频源（合并导入，保留现有源）。
  ///
  /// 同名 key 的源会被更新，其余追加；需要插件的 spider 源自动跳过。
  /// 返回导入结果摘要（新增 / 更新 / 跳过数量、识别到的格式）。
  Future<ImportSummary> importSitesFromContent(String content) async {
    final parsed = SourceImport.parse(content);
    if (parsed.sites.isEmpty) return parsed; // 携带 message 说明失败原因
    var added = 0;
    var updated = 0;
    for (final site in parsed.sites) {
      final existed =
          await ZyDatabase.instance.containsKey(DbNames.site, site.key);
      await ZyDatabase.instance.put(DbNames.site, site.toJson());
      if (existed) {
        updated++;
      } else {
        added++;
      }
    }
    await loadSites();
    return ImportSummary(
      sites: parsed.sites,
      skipped: parsed.skipped,
      format: parsed.format,
      added: added,
      updated: updated,
    );
  }

  // --------------------------------------------------------------------------
  // 配置
  // --------------------------------------------------------------------------

  Future<void> loadSetting() async {
    final data = await ZyDatabase.instance.get(DbNames.setting, 'config');
    _config = data == null ? const AppConfig() : AppConfig.fromJson(data);
    // 把「强制软件解码」同步到原生静态开关（Android 专用，其他平台内部直接 return）。
    // 应用启动 / 恢复备份后都会走到这里，保证原生侧与持久化配置一致。
    await SystemControl.setForceSoftwareDecode(_config.forceSoftwareDecode);
    notifyListeners();
  }

  /// 记住播放页选择的画面比例
  Future<void> setPlayerAspect(String key) async {
    if (_config.playerAspect == key) return;
    _config = _config.copyWith(playerAspect: key);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 记住播放页选择的画面大小
  Future<void> setPlayerScale(String key) async {
    if (_config.playerScale == key) return;
    _config = _config.copyWith(playerScale: key);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 手动交换画面宽高（纠正「竖屏视频被当成横屏」的源）
  Future<void> setPlayerFlip(bool value) async {
    if (_config.playerFlip == value) return;
    _config = _config.copyWith(playerFlip: value);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 全屏播放时是否在右上角显示实时下载速度
  Future<void> setShowSpeed(bool value) async {
    if (_config.showSpeed == value) return;
    _config = _config.copyWith(showSpeed: value);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 强制使用软件解码器（仅 Android 生效）。下次播放生效。
  Future<void> setForceSoftwareDecode(bool value) async {
    if (_config.forceSoftwareDecode == value) return;
    _config = _config.copyWith(forceSoftwareDecode: value);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    await SystemControl.setForceSoftwareDecode(value);
    notifyListeners();
  }

  /// 首页卡片横向 / 竖向切换，默认竖向
  Future<void> setLandscapeCard(bool value) async {
    if (_config.landscapeCard == value) return;
    _config = _config.copyWith(landscapeCard: value);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 全屏长按加速倍率（2.0 / 4.0 / 8.0），默认 2.0
  Future<void> setPlayerLongPressRate(double value) async {
    if (_config.playerLongPressRate == value) return;
    _config = _config.copyWith(playerLongPressRate: value);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 显示模式：'system' / 'light' / 'dark'
  Future<void> setThemeMode(String value) async {
    final next = value == 'light' || value == 'dark' ? value : 'system';
    if (_config.themeMode == next) return;
    _config = _config.copyWith(themeMode: next);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 自定义播放器的可执行文件路径（Windows 专属）。
  /// 空字符串表示未设置，外部播放回退到自动查找已安装的播放器。
  Future<void> setExternalPlayerPath(String path) async {
    final next = path.trim();
    if (_config.externalPlayerPath == next) return;
    _config = _config.copyWith(externalPlayerPath: next);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  /// 设置版本更新清单地址（留空则回到内置默认地址）。
  Future<void> setUpdateUrl(String url) async {
    final next = url.trim();
    if (_config.updateUrl == next) return;
    _config = _config.copyWith(updateUrl: next);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // 收藏
  // --------------------------------------------------------------------------

  Future<void> loadStars() async {
    final list = await ZyDatabase.instance.getAll(DbNames.star);
    _stars = list.map(RecordItem.fromJson).toList()
      // 收藏分栏「最新收藏在前」：按写入时间倒序；无 ts 的老数据排在末尾
      ..sort((a, b) => b.ts.compareTo(a.ts));
    notifyListeners();
  }

  bool isStarred(String key) => _stars.any((s) => s.key == key);

  Future<bool> addStar(RecordItem item) async {
    // 兜底写入时间：旧调用方未传 ts（0）时自动补当前时间，保证倒序正确
    final record = item.ts == 0
        ? item.copyWithRecord(ts: DateTime.now().millisecondsSinceEpoch)
        : item;
    // 用 put（upsert）而非 add：即使出现「内存状态短暂过期」导致重复收藏，
    // 也不会因为 key 已存在而静默返回 false，保证收藏一定成功落库。
    final ok = await ZyDatabase.instance.put(DbNames.star, record.toJson());
    await loadStars();
    return ok;
  }

  Future<bool> removeStar(String key) async {
    final ok = await ZyDatabase.instance.remove(DbNames.star, key);
    await loadStars();
    return ok;
  }

  /// 收藏 / 取消收藏
  Future<bool> toggleStar(RecordItem item) async {
    if (isStarred(item.key)) {
      return removeStar(item.key);
    }
    return addStar(item);
  }

  Future<bool> clearStars() async {
    final ok = await ZyDatabase.instance.removeAll(DbNames.star);
    await loadStars();
    return ok;
  }

  // --------------------------------------------------------------------------
  // 播放记录
  // --------------------------------------------------------------------------

  Future<void> loadHistories() async {
    final list = await ZyDatabase.instance.getAll(DbNames.history);
    _histories = list.map(RecordItem.fromJson).toList()
      // 历史分栏「最近观看在前」：按最近更新时间倒序；无 ts 的老数据排在末尾
      ..sort((a, b) => b.ts.compareTo(a.ts));
    notifyListeners();
  }

  RecordItem? historyOf(String key) {
    for (final h in _histories) {
      if (h.key == key) return h;
    }
    return null;
  }

  Future<bool> addHistory(RecordItem item) async {
    // 兜底写入时间：旧调用方未传 ts（0）时自动补当前时间，保证倒序正确
    final record = item.ts == 0
        ? item.copyWithRecord(ts: DateTime.now().millisecondsSinceEpoch)
        : item;
    final ok = await ZyDatabase.instance.add(DbNames.history, record.toJson());
    await loadHistories();
    return ok;
  }

  /// 更新播放进度（播放页每 10 秒写一次）。
  /// 刷新时间戳，使「最近观看」的影片排到历史分栏最前。
  Future<void> updateHistory(RecordItem item) async {
    final record = item.copyWithRecord(ts: DateTime.now().millisecondsSinceEpoch);
    await ZyDatabase.instance.update(DbNames.history, record.toJson());
    final index = _histories.indexWhere((h) => h.key == item.key);
    if (index >= 0) {
      _histories[index] = record;
      // 内存里直接重排，返回历史分栏时不用等下次 load 就能看到置顶效果
      _histories.sort((a, b) => b.ts.compareTo(a.ts));
      notifyListeners();
    }
  }

  /// 开始播放某影片：确保历史中存在该条，并把 ts 刷新为「现在」使其置顶。
  ///
  /// 解决「重播同一部影片却没回到历史最前」的 bug：
  /// 详情页原先在 key 已存在时直接 return、播放页写进度也只更新 currentTime/duration
  /// 不碰 ts，导致重播的影片 ts 停留在最初那次。这里统一在「开始播放」时刷新 ts。
  /// - 从未播放过 → 新建（ts=now）。
  /// - 已存在（重播）→ 保留原播放进度，仅刷新 ts 置顶，并用最新详情更新元信息。
  Future<void> touchHistory(RecordItem item) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final index = _histories.indexWhere((h) => h.key == item.key);
    final RecordItem record;
    if (index >= 0) {
      // 重播：保留原进度，只刷新 ts 置顶
      final old = _histories[index];
      record = item.copyWithRecord(
        ts: now,
        currentTime: old.currentTime,
        duration: old.duration,
      );
    } else {
      record = item.copyWithRecord(ts: now);
    }
    await ZyDatabase.instance.put(DbNames.history, record.toJson());
    if (index >= 0) {
      _histories[index] = record;
    } else {
      _histories.add(record);
    }
    _histories.sort((a, b) => b.ts.compareTo(a.ts));
    notifyListeners();
  }

  Future<bool> clearHistories() async {
    final ok = await ZyDatabase.instance.removeAll(DbNames.history);
    await loadHistories();
    return ok;
  }

  /// 删除单条播放记录（收藏页历史分栏的卡片删除用）
  Future<bool> removeHistory(String key) async {
    final ok = await ZyDatabase.instance.remove(DbNames.history, key);
    await loadHistories();
    return ok;
  }

  // --------------------------------------------------------------------------
  // 搜索历史
  // --------------------------------------------------------------------------

  static const String _searchHistoryKey = 'history';

  /// 读取搜索历史（最近搜索在前）
  Future<List<String>> getSearchHistory() async {
    final item =
        await ZyDatabase.instance.get(DbNames.search, _searchHistoryKey);
    if (item == null) return <String>[];
    final words = item['words'];
    if (words is List) {
      return words.map((e) => e.toString()).toList();
    }
    return <String>[];
  }

  /// 新增一条搜索历史：去重并置顶，最多保留 30 条
  Future<void> addSearchKeyword(String word) async {
    final w = word.trim();
    if (w.isEmpty) return;
    final list = await getSearchHistory();
    list.remove(w);
    list.insert(0, w);
    if (list.length > 30) list.removeRange(30, list.length);
    await ZyDatabase.instance.put(DbNames.search, {
      'key': _searchHistoryKey,
      'words': list,
    });
    notifyListeners();
  }

  /// 删除单条搜索历史
  Future<void> removeSearchKeyword(String word) async {
    final list = await getSearchHistory();
    if (!list.remove(word)) return;
    await ZyDatabase.instance.put(DbNames.search, {
      'key': _searchHistoryKey,
      'words': list,
    });
    notifyListeners();
  }

  /// 清空全部搜索历史
  Future<void> clearSearchHistory() async {
    await ZyDatabase.instance.removeAll(DbNames.search);
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // 局域网设备同步
  // --------------------------------------------------------------------------

  /// 导出指定库（site / setting / star / history 等）的原始数据，用于局域网同步。
  /// 直接读取存储层 JSON，不关心具体模型字段，保证两端格式一致。
  Future<Map<String, List<Map<String, dynamic>>>> exportDbs(
    Iterable<String> dbs,
  ) async {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final db in dbs) {
      result[db] = await ZyDatabase.instance.getAll(db);
    }
    return result;
  }

  /// 把远端拉取的数据合并进本地（按 key upsert）。返回各库写入（新增/更新）条数。
  Future<Map<String, int>> importDbs(
    Map<String, List<Map<String, dynamic>>> data,
  ) async {
    final summary = <String, int>{};
    for (final entry in data.entries) {
      final written = await ZyDatabase.instance.importRaw(entry.key, entry.value);
      summary[entry.key] = written;
    }
    // 同步完后统一刷新内存，让收藏 / 历史 / 源 / 配置实时生效
    await reloadAll();
    return summary;
  }

  // --------------------------------------------------------------------------
  // 重置
  // --------------------------------------------------------------------------

  /// 重置软件：清空全部数据并恢复默认源与默认设置
  Future<void> resetApp() async {
    await ZyDatabase.instance.clearDB();
    await ZyDatabase.instance.reset(DbNames.site, defaults: _defaultSiteData);
    await ZyDatabase.instance.reset(DbNames.setting, defaults: _defaultSettingData);
    await refresh();
  }
}
