import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../services/http_service.dart';
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
      {'id': 0, 'key': 'config', 'R18': true},
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

  /// 导入视频源（json 地址），导入成功后覆盖原有源
  Future<bool> importSites(String url) async {
    final list = await HttpService.instance.importSites(url);
    if (list.isEmpty) return false;
    await ZyDatabase.instance.removeAll(DbNames.site);
    for (final s in list) {
      await ZyDatabase.instance.add(DbNames.site, s.toJson());
    }
    await loadSites();
    return true;
  }

  // --------------------------------------------------------------------------
  // 配置
  // --------------------------------------------------------------------------

  Future<void> loadSetting() async {
    final data = await ZyDatabase.instance.get(DbNames.setting, 'config');
    _config = data == null ? const AppConfig() : AppConfig.fromJson(data);
    notifyListeners();
  }

  Future<void> setR18(bool value) async {
    _config = _config.copyWith(r18: value);
    await ZyDatabase.instance.put(DbNames.setting, _config.toJson());
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

  // --------------------------------------------------------------------------
  // 收藏
  // --------------------------------------------------------------------------

  Future<void> loadStars() async {
    final list = await ZyDatabase.instance.getAll(DbNames.star);
    _stars = list.map(RecordItem.fromJson).toList();
    notifyListeners();
  }

  bool isStarred(String key) => _stars.any((s) => s.key == key);

  Future<bool> addStar(RecordItem item) async {
    final ok = await ZyDatabase.instance.add(DbNames.star, item.toJson());
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
    _histories = list.map(RecordItem.fromJson).toList();
    notifyListeners();
  }

  RecordItem? historyOf(String key) {
    for (final h in _histories) {
      if (h.key == key) return h;
    }
    return null;
  }

  Future<bool> addHistory(RecordItem item) async {
    final ok = await ZyDatabase.instance.add(DbNames.history, item.toJson());
    await loadHistories();
    return ok;
  }

  /// 更新播放进度（播放页每 10 秒写一次）
  Future<void> updateHistory(RecordItem item) async {
    await ZyDatabase.instance.update(DbNames.history, item.toJson());
    final index = _histories.indexWhere((h) => h.key == item.key);
    if (index >= 0) {
      _histories[index] = item;
      notifyListeners();
    }
  }

  Future<bool> clearHistories() async {
    final ok = await ZyDatabase.instance.removeAll(DbNames.history);
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
