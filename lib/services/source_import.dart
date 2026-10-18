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
      // JSONP：`callback({...})` / `var config = {...};`
      final unwrapped = _stripJsonp(text);
      if (unwrapped != null) {
        try {
          decoded = jsonDecode(unwrapped);
        } catch (_) {
          decoded = null;
        }
      }
      // 有些配置正文前面带广告/说明文字，尝试截取其中内嵌的 JSON
      decoded ??= _embeddedJson(unwrapped ?? text);
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
    // TVBox 配置里常见同一个 api 被多个名字重复登记（「备用」等），
    // 按 api + key 去重，避免导入一堆完全一样的源。
    final seenApis = <String>{};
    final seenKeys = <String>{};
    var skipped = 0;
    for (final raw in rawSites) {
      final site = _toSite(raw);
      if (site == null) {
        skipped++;
        continue;
      }
      if (!seenApis.add(_apiSignature(site.api)) ||
          !seenKeys.add(site.key)) {
        skipped++;
        continue;
      }
      sites.add(site);
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
  ///
  /// TVBox 的 `type: 3/4`（spider）本身本应用跑不了，但很多配置把**真实的
  /// maccms 接口地址**放在 `ext` 里（`ext.url` / `ext.api`，`ext` 可能是对象
  /// 也可能是 JSON 字符串）。这种情况按 `ext` 里的接口导入，比整条丢掉更有用。
  static Site? _toSite(Map<dynamic, dynamic> raw) {
    final api = _resolveApi(raw);
    if (api == null) return null;

    // type 能识别就用它；类型标成 spider 但 api 是真实地址时，按地址推断
    // （maccms 的 xml 接口路径通常带 `at/xml`，其余当 json）。
    final type = _mapType(raw['type']) ?? _inferType(api);

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

  /// 找出这条站点真正可用的 maccms 接口地址。
  ///
  /// 优先 `api`（必须是 http 地址），其次是 `url`，最后从 `ext` 里挖
  /// （spider 源的真实接口通常藏在这里）。
  static String? _resolveApi(Map<dynamic, dynamic> raw) {
    for (final key in const <String>['api', 'url']) {
      final value = _str(raw[key]);
      if (value != null && _looksLikeHttp(value)) return value;
    }
    return _extUrl(raw['ext']);
  }

  /// 从 TVBox 的 `ext` 字段里找接口地址。
  ///
  /// `ext` 可能是：
  /// - 对象：`{"url":"http://..."}`
  /// - JSON 字符串：`"{\"url\":\"http://...\"}"`
  /// - 直接就是地址：`"http://..."`
  /// - 数组：逐项递归
  static String? _extUrl(dynamic ext) {
    if (ext == null) return null;
    if (ext is Map) {
      for (final key in const <String>['url', 'api', 'extend', 'siteUrl']) {
        final value = _str(ext[key]);
        if (value != null && _looksLikeHttp(value)) return value;
      }
      for (final value in ext.values) {
        final nested = _extUrl(value);
        if (nested != null) return nested;
      }
      return null;
    }
    if (ext is List) {
      for (final item in ext) {
        final nested = _extUrl(item);
        if (nested != null) return nested;
      }
      return null;
    }
    final text = ext.toString().trim();
    if (text.isEmpty) return null;
    if (_looksLikeHttp(text)) return text;
    if (!text.startsWith('{') && !text.startsWith('[')) {
      // 宽松匹配 ext 字符串里的地址（配置作者偶尔写坏 JSON）
      final m = RegExp(
        r'''["']?(?:url|api|extend|siteUrl)["']?\s*[:=]\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(text);
      final found = m?.group(1);
      return (found != null && _looksLikeHttp(found)) ? found : null;
    }
    try {
      return _extUrl(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeHttp(String value) {
    final v = value.trim().toLowerCase();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  /// 类型字段不可用时，按接口地址猜：maccms 的 xml 接口路径通常带 `at/xml`。
  static String _inferType(String api) {
    final lower = api.toLowerCase();
    if (lower.contains('at/xml') || lower.contains('/xml')) return 'xml';
    return 'json';
  }

  /// 去重用的接口指纹：忽略大小写与末尾斜杠。
  static String _apiSignature(String api) {
    var v = api.trim().toLowerCase();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  /// 去掉 JSONP 外壳，返回里面的 JSON 文本；不像 JSONP 时返回 null。
  static String? _stripJsonp(String text) {
    final t = text.trim();
    if (t.isEmpty || t.startsWith('{') || t.startsWith('[')) return null;
    // callback({...}); / jsonp({...}) / var config = {...};
    final m = RegExp(
      r'^(?:[\w$.]+\s*[=:(]\s*)?([\s\S]*?)\s*\)?\s*;?\s*$',
    ).firstMatch(t);
    if (m == null) return null;
    var inner = m.group(1)?.trim() ?? '';
    while (inner.endsWith(')')) {
      inner = inner.substring(0, inner.length - 1).trim();
    }
    if (inner.endsWith(';')) {
      inner = inner.substring(0, inner.length - 1).trim();
    }
    if (!inner.startsWith('{') && !inner.startsWith('[')) return null;
    return inner;
  }

  /// 多仓配置：`{"urls":[{"url":"...","name":"..."}]}` 里的子配置地址。
  static List<String> repoUrls(String content) {
    var text = content.trim();
    if (text.startsWith('\ufeff')) text = text.substring(1);
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      final unwrapped = _stripJsonp(text);
      decoded = unwrapped == null ? null : jsonDecode(unwrapped);
    }
    if (decoded is! Map) return const [];
    final urls = decoded['urls'];
    if (urls is! List) return const [];
    final out = <String>[];
    for (final item in urls) {
      String? url;
      if (item is Map) {
        url = _str(item['url']) ?? _str(item['api']) ?? _str(item['ext']);
      } else if (item is String) {
        url = _str(item);
      }
      if (url != null && url.isNotEmpty) out.add(url);
    }
    return out;
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
