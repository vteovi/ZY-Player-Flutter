import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/site.dart';

/// TVBox 配置导入结果
class TvBoxImport {
  final bool ok;
  /// 解析出的源（TVBox 格式时已过滤掉需要插件的 spider 源）
  final List<Site> sites;
  /// 因需要插件（type 3/4）或接口不合法而被跳过的源数量
  final int skipped;
  /// true = TVBox 配置，与现有源合并；false = ZY 站点列表，覆盖导入
  final bool merged;

  const TvBoxImport({
    required this.ok,
    this.sites = const [],
    this.skipped = 0,
    this.merged = false,
  });
}

/// TVBox 配置解析。
///
/// 支持把 TVBox 类配置（`{"sites": [...]}`）转换成本应用的采集站列表：
/// - type 0（maccms xml 接口）→ xml 源
/// - type 1（maccms json 接口）→ json 源
/// - type 3/4（spider，需要额外 JS 插件引擎）→ 跳过，无法支持
///
/// 链接容错：
/// - `http:box.iqinu.com`（缺斜杠）→ `http://box.iqinu.com`
/// - `box.iqinu.com`（无协议）→ `http://box.iqinu.com`
/// - 中文域名如 `www.饭太硬.com` → 自动转 punycode `www.xn--sss604efuw.com`
/// - `clan://` 前缀 → 剥离后按 http 处理
class TvBoxService {
  TvBoxService._();

  static final TvBoxService instance = TvBoxService._();

  static const Duration _timeout = Duration(seconds: 15);

  static const String _browserUa =
      'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  /// 拉取并解析配置地址，自动识别 ZY 站点列表 / TVBox 配置两种格式
  Future<TvBoxImport> resolve(String input) async {
    final url = normalizeUrl(input);
    if (url == null) return const TvBoxImport(ok: false);
    final raw = await _fetch(url);
    if (raw == null) return const TvBoxImport(ok: false);
    final decoded = _extractJson(raw);
    if (decoded == null) return const TvBoxImport(ok: false);

    // 顶层是数组 → ZY 站点列表（原格式，覆盖导入）
    if (decoded is List) {
      final sites = decoded
          .whereType<Map>()
          .map((e) => Site.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      return TvBoxImport(ok: sites.isNotEmpty, sites: sites);
    }

    // 顶层带 sites → TVBox 配置
    if (decoded is Map && decoded['sites'] is List) {
      final parsed = parseTvBoxSites(
        (decoded['sites'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      return TvBoxImport(ok: parsed.sites.isNotEmpty, merged: true, sites: parsed.sites, skipped: parsed.skipped);
    }
    return const TvBoxImport(ok: false);
  }

  /// 拉取配置正文。TVBox 生态的服务器大多校验 okhttp UA，先用它，失败再换浏览器 UA。
  Future<String?> _fetch(String url) async {
    for (final ua in const <String>['okhttp/3.15', _browserUa]) {
      try {
        final res = await http
            .get(Uri.parse(url), headers: {'User-Agent': ua, 'Accept': '*/*'})
            .timeout(_timeout);
        if (res.statusCode == 200 && res.body.trim().isNotEmpty) {
          return res.body;
        }
      } catch (_) {
        // 换下一个 UA 重试
      }
    }
    return null;
  }

  /// 解析 TVBox 的 sites 数组
  static ({List<Site> sites, int skipped}) parseTvBoxSites(
    Iterable<Map<String, dynamic>> list,
  ) {
    final sites = <Site>[];
    var skipped = 0;
    var id = 0;
    for (final e in list) {
      final type = _toInt(e['type']);
      final api = _s(e['api']).trim();
      final name = _s(e['name']).trim();
      final key = _s(e['key']).trim();
      if (key.isEmpty || name.isEmpty || !api.startsWith('http')) {
        skipped++;
        continue;
      }
      if (type == 0) {
        sites.add(Site(
          id: id++,
          key: key,
          name: name,
          api: api,
          type: 'xml',
          group: 'TVBox',
        ));
      } else if (type == 1) {
        sites.add(Site(
          id: id++,
          key: key,
          name: name,
          api: api,
          type: 'json',
          group: 'TVBox',
        ));
      } else {
        // type 3/4：spider 源需要额外 JS 插件引擎，本应用无法支持
        skipped++;
      }
    }
    return (sites: sites, skipped: skipped);
  }

  /// 链接规范化，失败返回 null
  static String? normalizeUrl(String input) {
    var url = input.trim();
    // 去掉误粘贴的引号
    while (url.length >= 2 &&
        ((url.startsWith('"') && url.endsWith('"')) ||
            (url.startsWith('\'') && url.endsWith('\'')))) {
      url = url.substring(1, url.length - 1).trim();
    }
    if (url.isEmpty) return null;

    // clan:// 前缀（TVBox 本地协议）：剥离后按 http 处理
    if (url.toLowerCase().startsWith('clan://')) {
      url = url.substring(7);
    }

    // http:xxx / https:xxx 缺 // → 补上
    final missingSlashes =
        RegExp(r'^(https?):(?!//)', caseSensitive: false).firstMatch(url);
    if (missingSlashes != null) {
      url = '${missingSlashes.group(1)!}://${url.substring(missingSlashes.end)}';
    }

    // 没有任何协议 → 默认 http
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
      url = 'http://$url';
    }

    // 中文 / 非 ASCII 域名 → punycode
    final m =
        RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/?#]+)(.*)$').firstMatch(url);
    if (m != null) {
      var authority = m.group(2)!;
      final rest = m.group(3)!;
      final at = authority.lastIndexOf('@');
      var userinfo = '';
      if (at >= 0) {
        userinfo = authority.substring(0, at + 1);
        authority = authority.substring(at + 1);
      }
      var host = authority;
      var port = '';
      final colon = authority.lastIndexOf(':');
      if (colon >= 0 && !authority.contains(']')) {
        host = authority.substring(0, colon);
        port = authority.substring(colon);
      }
      if (host.runes.any((c) => c > 0x7F)) {
        host = host
            .split('.')
            .map((label) =>
                label.isEmpty ||
                        label.runes.every((c) => c <= 0x7F) ||
                        label.toLowerCase().startsWith('xn--')
                    ? label
                    : 'xn--${_punycodeEncode(label.toLowerCase())}')
            .join('.');
      }
      url = '${m.group(1)}$userinfo$host$port$rest';
    }

    return Uri.tryParse(url)?.toString();
  }

  /// 从响应正文里抠出 JSON：直接解析失败时，截取第一个 { / [ 到最后一个 } / ]
  static dynamic _extractJson(String raw) {
    var text = raw.trim();
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    try {
      return jsonDecode(text);
    } catch (_) {}
    final objStart = text.indexOf('{');
    final arrStart = text.indexOf('[');
    final start = objStart < 0
        ? arrStart
        : (arrStart < 0 ? objStart : (objStart < arrStart ? objStart : arrStart));
    final objEnd = text.lastIndexOf('}');
    final arrEnd = text.lastIndexOf(']');
    final end = objEnd > arrEnd ? objEnd : arrEnd;
    if (start >= 0 && end > start) {
      try {
        return jsonDecode(text.substring(start, end + 1));
      } catch (_) {}
    }
    return null;
  }

  static String _s(dynamic v) => v == null ? '' : v.toString();

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  // --------------------------------------------------------------------------
  // Punycode（RFC 3492），用于中文域名转 xn-- 形式
  // --------------------------------------------------------------------------

  static String _punycodeEncode(String input) {
    // skew / damp 只在 _adapt 里用到
    const base = 36, tmin = 1, tmax = 26;
    const initialBias = 72, initialN = 128, delimiter = 0x2D; // '-'
    var n = initialN, delta = 0, bias = initialBias;
    final output = StringBuffer();
    for (final cp in input.runes) {
      if (cp < 0x80) output.writeCharCode(cp);
    }
    final b = output.length;
    final total = input.runes.length;
    if (b > 0 && b < total) output.writeCharCode(delimiter);
    var handled = b;
    while (handled < total) {
      var m = 0x10FFFF;
      for (final cp in input.runes) {
        if (cp >= n && cp < m) m = cp;
      }
      delta += (m - n) * (handled + 1);
      n = m;
      for (final cp in input.runes) {
        if (cp < n) delta++;
        if (cp == n) {
          var q = delta;
          var k = base;
          while (true) {
            final t = k <= bias
                ? tmin
                : (k >= bias + tmax ? tmax : k - bias);
            if (q < t) break;
            output.writeCharCode(_digit(t + (q - t) % (base - t)));
            q = (q - t) ~/ (base - t);
            k += base;
          }
          output.writeCharCode(_digit(q));
          bias = _adapt(delta, handled + 1, handled == b);
          delta = 0;
          handled++;
        }
      }
      delta++;
      n++;
    }
    return output.toString();
  }

  static int _adapt(int delta, int numPoints, bool firstTime) {
    const base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700;
    delta = firstTime ? delta ~/ damp : delta ~/ 2;
    delta += delta ~/ numPoints;
    var k = 0;
    while (delta > ((base - tmin) * tmax) ~/ 2) {
      delta ~/= base - tmin;
      k += base;
    }
    return k + (((base - tmin + 1) * delta) ~/ (delta + skew));
  }

  /// 0..25 → a..z，26..35 → 0..9
  static int _digit(int d) => d < 26 ? 0x61 + d : 0x30 + d - 26;
}
