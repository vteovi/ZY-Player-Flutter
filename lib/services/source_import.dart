import 'dart:convert';

import '../models/site.dart';

/// 导入结果摘要：解析出的可用源、跳过的源（需插件）、新增/更新数量、识别到的格式。
class ImportSummary {
  final List<Site> sites;
  final int skipped;
  /// 'tvbox' / 'zyfun' / 'unknown'
  final String format;
  /// 出错时非空，描述失败原因
  final String message;
  final int added;
  final int updated;

  const ImportSummary({
    required this.sites,
    required this.skipped,
    required this.format,
    this.message = '',
    this.added = 0,
    this.updated = 0,
  });

  bool get ok => sites.isNotEmpty;
}

/// ZYFun / TVBox 配置解析。
///
/// 实际遇到过的几种形态（都能认）：
/// - **zyfun 桌面版（新版，Tauri）**：`{"tbl_site":[{id,key,name,api,type,group,
///   isActive,...}]}` —— 直接拿数据库表名当键，`id`/`key` 是 UUID 字符串。
///   这是「设置 → 数据管理 → 配置导出」的 `zyfun_config_*.json`。
/// - **zyfun 源管理 → 导出**：顶层**裸数组** `[{id,key,name,api,download,...}]`。
/// - **zyfun 桌面版（旧版 Electron）**：`{"sites":{"default":1,"data":[{...}]}}`，
///   列表在 `data` 里；同类变体还有 `site` 为数组的写法。
/// - **TVBox / catvod**：`{"sites":[{key,name,api,type,...}]}`，sites 是数组。
///
/// type 约定一致：0 = xml（maccms xml 接口）、1 = json（maccms json 接口）；
/// 其余（spider / drpy / 解析源等，3/4/7/15…）需要额外插件引擎，本应用不支持，跳过。
///
/// ⚠️ zyfun 的 `api` 字段常自带查询串（如 `.../api.php/provide/vod/?ac=list`），
/// 这里**原样保留**；拼接接口地址时由 `HttpService._apiUrl` 做参数合并，
/// 不要在这里裁剪，否则用户看不出源站原始地址。
class SourceImport {
  SourceImport._();

  /// 从 JSON 文本解析，返回可用的源与跳过的源数量。
  /// 无法解析时返回 sites 为空且 message 非空。
  static ImportSummary parse(String content) {
    var text = content.trim();
    if (text.startsWith('\ufeff')) text = text.substring(1); // 去掉 UTF-8 BOM

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // 有些配置正文前面带广告/说明文字，尝试截取其中内嵌的 JSON
      decoded = _embeddedJson(text);
      if (decoded == null) {
        return const ImportSummary(
          sites: [],
          skipped: 0,
          format: 'unknown',
          message: '文件不是有效的 JSON',
        );
      }
    }

    // 顶层裸数组：zyfun「源管理 → 导出」就是这个形态，包一层统一处理
    final Map<String, dynamic> root;
    if (decoded is List) {
      root = <String, dynamic>{'tbl_site': decoded};
    } else if (decoded is Map) {
      root = Map<String, dynamic>.from(decoded);
    } else {
      return const ImportSummary(
        sites: [],
        skipped: 0,
        format: 'unknown',
        message: '文件不是有效的 JSON 对象或数组',
      );
    }

    final rawSites = _extractSites(root);
    if (rawSites.isEmpty) {
      return ImportSummary(
        sites: const [],
        skipped: 0,
        format: 'unknown',
        message: '配置里没有找到视频源数据（顶层字段：${_topKeys(root)}）',
      );
    }

    final format = _detectFormat(root);
    final sites = <Site>[];
    var skipped = 0;
    for (final raw in rawSites) {
      final site = _toSite(raw);
      if (site == null) {
        skipped++;
      } else {
        sites.add(site);
      }
    }
    if (sites.isEmpty) {
      return ImportSummary(
        sites: const [],
        skipped: skipped,
        format: format,
        message: '没有可用的 json/xml 源（全部是需要插件的 spider 源）',
      );
    }
    return ImportSummary(
      sites: sites,
      skipped: skipped,
      format: format,
      message: '',
    );
  }

  /// 从文本里截出内嵌的 JSON（正文前后可能夹着说明文字）。
  /// 先按对象截，再按数组截 —— zyfun 的裸数组导出靠后者。
  static dynamic _embeddedJson(String text) {
    final pairs = <List<int>>[
      <int>[text.indexOf('{'), text.lastIndexOf('}')],
      <int>[text.indexOf('['), text.lastIndexOf(']')],
    ];
    for (final pair in pairs) {
      final start = pair[0];
      final end = pair[1];
      if (start < 0 || end <= start) continue;
      try {
        return jsonDecode(text.substring(start, end + 1));
      } catch (_) {
        // 换下一种括号再试
      }
    }
    return null;
  }

  /// 解析失败时把顶层字段名回显给用户，便于判断是哪种导出格式
  static String _topKeys(Map<String, dynamic> root) {
    if (root.isEmpty) return '（空对象）';
    return root.keys.take(8).map((k) => k.toString()).join('、');
  }

  /// 从配置根对象里找出站点数组。
  ///
  /// 键名大小写不敏感，依次匹配 `tbl_site`（zyfun 新版）→ `sites`（TVBox /
  /// zyfun 旧版）→ `site`（变体）。键名都对不上时，兜底扫一遍顶层数组，
  /// 要求元素带 `api` 字段 —— IPTV / 解析源用的是 `url`，这样能避开误选。
  static List<Map<dynamic, dynamic>> _extractSites(Map<String, dynamic> root) {
    for (final want in const <String>['tbl_site', 'sites', 'site']) {
      for (final entry in root.entries) {
        if (entry.key.toString().toLowerCase() != want) continue;
        final found = _listFromValue(entry.value);
        if (found.isNotEmpty) return found;
      }
    }
    for (final value in root.values) {
      if (value is! List) continue;
      final list = value.whereType<Map>().toList();
      if (list.isEmpty) continue;
      if (list.every((e) => e.containsKey('api'))) return list;
    }
    return const [];
  }

  /// 值可能是数组本身，也可能是 `{"default":1,"data":[...]}` 这类包装
  static List<Map<dynamic, dynamic>> _listFromValue(dynamic value) {
    if (value is List) return value.whereType<Map>().toList();
    if (value is Map) {
      for (final k in const <String>['data', 'list', 'sites', 'site']) {
        final inner = value[k];
        if (inner is List) {
          final list = inner.whereType<Map>().toList();
          if (list.isNotEmpty) return list;
        }
      }
    }
    return const [];
  }

  static String _detectFormat(Map<String, dynamic> root) {
    if (root.keys.any((k) => k.toString().toLowerCase() == 'tbl_site')) {
      return 'zyfun';
    }
    final sitesRaw = root['sites'];
    if (sitesRaw is Map && sitesRaw.containsKey('data')) return 'zyfun';
    if (root.containsKey('site')) return 'zyfun';
    if (sitesRaw is List) return 'tvbox';
    return 'zyfun';
  }

  /// 把一条原始站点映射成 Site；接口地址缺失或类型不支持（spider 等）时返回 null。
  static Site? _toSite(Map<dynamic, dynamic> raw) {
    var api = _str(raw['api']);
    if (api == null || api.isEmpty) api = _str(raw['url']);
    if (api == null || api.isEmpty) return null;

    final type = _mapType(raw['type']);
    if (type == null) return null; // spider / drpy / 其他需要插件，跳过

    var key = _str(raw['key']) ?? '';
    final name = _str(raw['name']) ?? '';
    if (key.isEmpty) {
      key = name.isNotEmpty ? name : _hostOf(api);
    }
    if (key.isEmpty) return null;

    final group = _str(raw['group']) ?? '导入';
    final isActive = _bool(raw['isActive'], dflt: true);
    final statusRaw = _str(raw['status']) ?? '可用';
    // ZYFun 的 status 是布尔，转成中文状态串
    final status = (statusRaw == 'true' || statusRaw == 'false')
        ? (statusRaw == 'true' ? '可用' : '失效')
        : statusRaw;

    return Site(
      id: _toInt(raw['id']),
      key: key,
      name: name.isNotEmpty ? name : key,
      api: api,
      type: type,
      download: _str(raw['download']) ?? '',
      group: group,
      isActive: isActive,
      status: status,
    );
  }

  /// type → 本应用支持的 'xml' / 'json'；不支持的类型返回 null。
  static String? _mapType(dynamic t) {
    if (t == null) return 'xml'; // 缺省按 xml 处理，尽量可用
    if (t is num) {
      if (t == 0) return 'xml';
      if (t == 1) return 'json';
      return null; // 2/3/4/7/15… 多为 spider / drpy，需插件，跳过
    }
    final s = t.toString().toLowerCase().trim();
    if (s == '0' || s == 'xml') return 'xml';
    if (s == '1' || s == 'json') return 'json';
    return null;
  }

  static String? _str(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static bool _bool(dynamic v, {required bool dflt}) {
    if (v == null) return dflt;
    if (v is bool) return v;
    if (v is num) return v != 0;
    return v.toString().toLowerCase() == 'true';
  }

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _hostOf(String api) {
    try {
      final uri = Uri.parse(api);
      return uri.host.isNotEmpty ? uri.host : api;
    } catch (_) {
      return api;
    }
  }
}
