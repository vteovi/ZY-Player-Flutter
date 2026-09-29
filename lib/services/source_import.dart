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

/// TVBox / ZYFun 配置解析。
///
/// 两种格式的差异：
/// - TVBox：`{"sites":[{key,name,api,type,...}]}`，sites 是数组
/// - ZYFun：`{"sites":{"default":1,"data":[{id,key,name,api,type,group,isActive,status}]}}`，
///   sites 是对象，真正的列表在 `data` 里；另外还有 `site` 为数组的变体
///
/// type 约定一致：0 = xml（maccms xml 接口）、1 = json（maccms json 接口）；
/// 其余（spider / drpy / 解析源等，3/4/7/15…）需要额外插件引擎，本应用不支持，跳过。
class SourceImport {
  SourceImport._();

  /// 从 JSON 文本解析，返回可用的源与跳过的源数量。
  /// 无法解析时返回 sites 为空且 message 非空。
  static ImportSummary parse(String content) {
    var text = content.trim();
    if (text.startsWith('\ufeff')) text = text.substring(1); // 去掉 UTF-8 BOM

    Map<String, dynamic>? root;
    try {
      root = _decode(text);
    } catch (_) {
      // 有些配置正文前面带广告文字，尝试截取其中内嵌的 JSON 对象
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          root = _decode(text.substring(start, end + 1));
        } catch (_) {
          return const ImportSummary(
            sites: [],
            skipped: 0,
            format: 'unknown',
            message: '文件不是有效的 JSON',
          );
        }
      } else {
        return const ImportSummary(
          sites: [],
          skipped: 0,
          format: 'unknown',
          message: '文件不是有效的 JSON',
        );
      }
    }
    final rawSites = _extractSites(root);
    if (rawSites.isEmpty) {
      return const ImportSummary(
        sites: [],
        skipped: 0,
        format: 'unknown',
        message: '配置里没有找到 sites 数据',
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

  static Map<String, dynamic> _decode(String text) {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('顶层不是 JSON 对象');
  }

  static List<Map<dynamic, dynamic>> _extractSites(Map<String, dynamic> root) {
    // TVBox：sites 是数组
    final sitesRaw = root['sites'];
    if (sitesRaw is List) {
      return sitesRaw.whereType<Map>().toList();
    }
    // ZYFun：sites 是对象，列表在 data 里
    if (sitesRaw is Map) {
      final data = sitesRaw['data'];
      if (data is List) return data.whereType<Map>().toList();
    }
    // 变体：部分导出把站点放在单数 site 字段
    final siteRaw = root['site'];
    if (siteRaw is List) return siteRaw.whereType<Map>().toList();
    return const [];
  }

  static String _detectFormat(Map<String, dynamic> root) {
    final sitesRaw = root['sites'];
    if (sitesRaw is Map && sitesRaw.containsKey('data')) return 'zyfun';
    if (sitesRaw is List) return 'tvbox';
    return 'unknown';
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
