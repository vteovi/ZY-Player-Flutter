import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../models/site.dart';
import '../models/video.dart';
import '../utils/config_url.dart';
import '../utils/tvbox_crypto.dart';
import 'source_import.dart';

/// 请求失败时抛出，携带**可直接展示给用户**的中文原因。
///
/// 普通取数路径只关心"成没成"，但源可用性检测需要把失败原因讲清楚
/// （域名没了 / 超时 / 403 / 接口变了），所以单独定义这个异常。
class HttpRequestException implements Exception {
  final String reason;

  const HttpRequestException(this.reason);

  @override
  String toString() => reason;
}

/// 源可用性
enum SiteHealth {
  /// 拿到了分类或片单
  ok,

  /// 接口能连通，但没返回片单 —— 域名还在、接口已改版，是采集站最常见的死法
  warn,

  /// 连不上，或返回的内容根本不是采集接口
  fail,
}

/// 单个源的检测结果
class SiteCheckResult {
  final SiteHealth health;

  /// 人类可读的结论，例如「可用 · 12 个分类」「域名解析失败」
  final String message;

  /// 耗时（毫秒）
  final int ms;

  const SiteCheckResult(this.health, this.message, this.ms);

  bool get ok => health == SiteHealth.ok;
}

/// 分类
class VideoClass {
  final String tid;
  final String name;

  const VideoClass({required this.tid, required this.name});
}

/// 分页信息
class PageInfo {
  final int page;
  final int pagecount;
  final int pagesize;
  final int recordcount;

  /// 这次请求是否真的拿到了分页信息。
  ///
  /// [HttpService.fetchPage] 内部会吞掉网络异常并返回一个空对象，调用方必须靠这个
  /// 标记区分「站点真的只有 1 页」和「这次没取到」。否则一次超时就会把总页数写成 1，
  /// 列表被误判成「没有更多了」再也翻不动，元信息缓存也被污染。
  final bool ok;

  const PageInfo({
    this.page = 1,
    this.pagecount = 1,
    this.pagesize = 20,
    this.recordcount = 0,
    this.ok = true,
  });
}

/// 一页搜索结果：片单 + 站点给的分页信息。
///
/// ⚠️ maccms 的搜索接口**默认每页只回 20 条**，不传 `pg` 就永远只拿第一页 ——
/// 这正是「每个源最多只能搜到 20 条」的原因。想拿更多只能自己带页码翻页。
class SearchPageResult {
  final List<Video> videos;

  /// 本次请求的页码（从 1 开始）
  final int page;

  /// 站点声明的每页条数。站点没给时按 maccms 的默认 20 算。
  final int pageSize;

  /// 站点声明的总页数；0 表示站点没给（未知）。
  final int pagecount;

  const SearchPageResult({
    required this.videos,
    required this.page,
    this.pageSize = 20,
    this.pagecount = 0,
  });

  /// 是否可能还有下一页。
  ///
  /// 判据刻意放得很松：**只要这一页还有数据、且没越过站点声明的总页数，
  /// 就认为可能还有**。
  ///
  /// 不能用「不满一页就到底」来收尾：有些采集站的搜索接口另有条数上限
  /// （声明 `limit=20`，实际每页只回 10 条，甚至更少），按满页判会把这类
  /// 站误判成「只有 10 条」，正好卡住用户。
  ///
  /// 真正的收尾交给上层的两条硬判据：拿到的整页都是已存在的 id（站点不认
  /// 页码）、或返回空页。再加每源页数上限兜底，不会无限翻下去。
  bool get hasMore {
    if (videos.isEmpty) return false;
    if (pagecount > 1 && page >= pagecount) return false;
    return true;
  }
}

/// 接口响应解析结果：JSON 与 XML 二选一。
///
/// 由 [HttpService._parse] 按**响应内容**判定，不依赖源清单里的 `type` 字段。
class _Payload {
  final Map<String, dynamic>? json;

  /// ⚠️ 字段名不能叫 `xml` —— 会遮蔽 `import 'package:xml/xml.dart' as xml`
  /// 的前缀，导致本文件里所有 `xml.XXX` 都被判为「前缀被局部声明遮蔽」。
  final xml.XmlDocument? xmlDoc;

  /// 正文看起来是 HTML 网页（而非采集接口）。
  /// 实测这是采集站"域名还在、接口已改版"的典型特征，据此给出更准的提示。
  final bool looksLikeHtml;

  const _Payload({this.json, this.xmlDoc, this.looksLikeHtml = false});
}

/// 视频源请求服务，对应 uni-app 版 utils/request.js。
///
/// 支持两种采集站接口：
/// - json：maccms 的 json 接口（zx / zyfun 导出的源大多是这种）
/// - xml：maccms 的 xml 接口
class HttpService {
  HttpService._();

  static final HttpService instance = HttpService._();

  /// 列表 / 分类 / 搜索接口的超时。
  ///
  /// 原来 15 秒：源站卡住时用户就要在列表底部干等 15 秒才看到「没有更多」。
  /// 实测这批采集站正常响应在 1~9 秒（最慢的暴风首屏 8.9 秒），10 秒足够放行
  /// 正常请求，又能把「死等」的上限压掉 5 秒。首页另有后台预取兜底，
  /// 偶尔一次超时不会让用户停在底部。
  static const Duration _timeout = Duration(seconds: 10);

  /// 详情请求专用超时：比列表短一些，配合下面的重试把最坏等待压住。
  static const Duration _detailTimeout = Duration(seconds: 12);

  /// 详情请求对**瞬时错误**的重试次数。
  ///
  /// 采集站大多是个人小水管，偶发超时 / 连接被重置 / 5xx；重试大概率能救回来。
  static const int _detailMaxRetries = 2;

  static const Map<String, String> _headers = {
    'User-Agent': _browserUserAgent,
    'Accept': '*/*',
  };

  /// 全 App 复用同一个客户端。
  ///
  /// 顶层 `http.get()` 每次都会新建 client 再关掉，等于每个请求都从零握手：
  /// 同一站点连续翻页本可以命中 keep-alive 省掉 TCP/TLS 握手，DNS 解析结果
  /// 也能在 client 内缓存（源管理「检测全部」时同一域名只会解析一次）。
  /// **不要 close** —— 空闲连接由底层 idleTimeout 自动回收。
  static final http.Client _client = http.Client();

  /// 拼接口地址：把站点 api 自带的参数与本次调用的参数**合并**，同名以后者为准。
  ///
  /// ⚠️ 别退回字符串拼接。zyfun 导出的 api 常自带查询串，例如
  /// `https://api.apibdzy.com/api.php/provide/vod/?ac=list`，直接拼
  /// `?ac=videolist&pg=1` 会得到 `...?ac=list?ac=videolist&pg=1` ——
  /// 服务端只取到第一个 `ac=list`，表现就是「这个源在 App 里加载不出来」。
  /// 用 `Uri` 重新组装既能去掉重复，又能正确编码中文关键词。
  static String _apiUrl(Site site, Map<String, String> params) {
    final base = site.api.trim();
    if (base.isEmpty) return base;
    try {
      final uri = Uri.parse(base);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        return uri
            .replace(
              queryParameters: <String, String>{
                ...uri.queryParameters,
                ...params,
              },
            )
            .toString();
      }
    } catch (_) {
      // 地址解析不了就退回最朴素的拼接
    }
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$base?$query';
  }

  /// 列表类请求的公共参数（分类 + 页码）。
  ///
  /// ⚠️ `t` / `pg` 是 maccms 的标准参数名，但有一批站（例如
  /// `http://movie.iqinu.com/api.php/v1.vod`）的网关只认 `tid` / `page`，
  /// 对 `t` / `pg` **完全无视**：请求照样 200、照样回片单，只是永远回最新那一页。
  /// 在 App 里就表现成「点了别的分类还是同一批片」「翻页一直翻不动」——
  /// 用户看到的就是「这个网站只能获取到一个分类」。
  ///
  /// 所以两套参数同时带上：标准站会忽略不认识的 `tid` / `page`（实测红牛等
  /// 内置源带不带完全一致），非标准站则靠自己的那一套生效。
  static Map<String, String> _listParams({String? tid, int? pg}) {
    final params = <String, String>{'ac': 'videolist'};
    final t = (tid ?? '').trim();
    if (t.isNotEmpty && t != '0') {
      params['t'] = t;
      params['tid'] = t;
    }
    if (pg != null) {
      params['pg'] = '$pg';
      params['page'] = '$pg';
    }
    return params;
  }

  /// 发起请求：**先 GET，必要时再回退 POST**。
  ///
  /// 原实现统一走 POST（对齐 uni-app 版 uni-ajax），但实测有采集站
  /// （如 `cj.lziapi.com`）对 POST 直接返回 403、只放行 GET，在 App 里就表现为
  /// 「这个源加载不了」。GET 是 maccms 的通用方式，所以先试它。
  ///
  /// ⚠️ 回退只针对 **4xx**（可能是服务端不接受这种请求方法）。
  /// 网络层错误（DNS 解析不了 / 连接被拒 / 超时）换方法同样会失败，
  /// 若也去重试，一个死站就要白等两个超时（30 秒），故直接放弃。
  Future<String> _fetch(String url, {Duration? timeout}) async {
    final uri = Uri.parse(url);
    final limit = timeout ?? _timeout;
    // 非空初值：下面每条分支都会覆盖它，analyzer 也不会再报
    // DEAD_NULL_AWARE_EXPRESSION
    var reason = '请求失败';
    var worthRetry = false;
    try {
      final res = await _client.get(uri, headers: _headers).timeout(limit);
      if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          res.body.isNotEmpty) {
        return _decode(res);
      }
      reason = _httpReason(res.statusCode);
      worthRetry = res.statusCode >= 400 && res.statusCode < 500;
    } catch (e) {
      reason = _describeRawError(e.toString());
      worthRetry = false;
    }
    if (worthRetry) {
      try {
        final res = await _client.post(uri, headers: _headers).timeout(limit);
        if (res.statusCode >= 200 &&
            res.statusCode < 300 &&
            res.body.isNotEmpty) {
          return _decode(res);
        }
        reason = _httpReason(res.statusCode);
      } catch (e) {
        reason = _describeRawError(e.toString());
      }
    }
    throw HttpRequestException(reason);
  }

  /// 拉取 TVBox / 视频源配置时可用的 UA，按优先级排列。
  ///
  /// ⚠️ 很多配置站**按 UA 分发内容**：带 `okhttp/*` 才返回真配置，浏览器 UA
  /// 只给一个「站点创建成功」的占位页（实测 `https://box.iqinu.com` 就是这样，
  /// 用浏览器 UA 拿到 623 字节的占位 HTML，用 `okhttp/3.15` 拿到 67KB 配置）。
  /// 所以配置请求先按 TVBox 的 UA 试，拿不到配置文件再退回浏览器 UA。
  static const List<String> _configUserAgents = <String>[
    'okhttp/3.15',
    'okhttp/3.12.0',
    _browserUserAgent,
  ];

  static const String _browserUserAgent =
      'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  /// 配置请求的 Accept（与 TVBox 一致，部分站点也看这个头）。
  static const String _configAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,'
      'image/avif,image/webp,image/apng,*/*;q=0.8';

  /// 按指定 UA 拉一次配置。
  Future<String> _fetchConfigWithUa(
    String url,
    String userAgent,
    Duration limit,
  ) async {
    final res = await _client
        .get(
          Uri.parse(url),
          headers: <String, String>{
            'User-Agent': userAgent,
            'Accept': _configAccept,
          },
        )
        .timeout(limit);
    if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
      return _decode(res);
    }
    throw HttpRequestException(_httpReason(res.statusCode));
  }

  /// 拉配置：挨个 UA 试，返回第一个「像配置」的响应。
  ///
  /// 全部 UA 都只拿到网页时，返回那份 HTML —— 导航页流程还要从里面找配置链接。
  Future<String> _fetchConfig(String url, Duration limit) async {
    String? fallback;
    String? firstError;
    for (final ua in _configUserAgents) {
      try {
        final text = await _fetchConfigWithUa(url, ua, limit);
        if (_looksLikeConfigPayload(text)) return text;
        fallback ??= text;
      } catch (e) {
        firstError ??= describeRequestError(e);
      }
    }
    if (fallback != null) return fallback;
    throw HttpRequestException(firstError ?? '配置拉取失败');
  }

  /// 内容是否像「配置本体」：JSON、TVBox 加密十六进制，或其它非网页文本。
  static bool _looksLikeConfigPayload(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('{') || t.startsWith('[')) return true;
    if (t.startsWith('2423') || t.startsWith(r'$#')) return true;
    // 够长又不是网页 —— 基本就是配置正文（含未知的加密格式）
    if (t.length > 200 && !_looksLikeHtml(t) && !t.startsWith('<')) {
      return true;
    }
    return false;
  }

  /// 把请求异常翻译成能直接展示给用户的中文原因。
  static String describeRequestError(Object e) {
    if (e is HttpRequestException) return e.reason;
    if (e is TimeoutException) return '连接超时';
    return _describeRawError(e.toString());
  }

  static String _httpReason(int code) {
    if (code == 403) return 'HTTP 403（服务端拒绝访问）';
    if (code == 404) return 'HTTP 404（接口不存在）';
    if (code >= 500) return 'HTTP $code（服务端错误）';
    return 'HTTP $code';
  }

  /// 判断失败原因是否值得重试。
  ///
  /// 瞬时错误（网络层抖动 / 源站偶发 5xx / 超时 / 连接被重置）重试大概率能成功；
  /// 永久错误（403 / 404 / 接口改版返回网页）重试毫无意义，直接放弃。
  static bool _isTransientReason(String reason) {
    return reason.contains('超时') ||
        reason.contains('被重置') ||
        reason.contains('服务端错误') ||
        reason.contains('网络不可达') ||
        reason.contains('域名解析失败') ||
        reason.contains('网络错误');
  }

  /// ⚠️ 只做字符串匹配，不 import `dart:io` —— 保持本文件不依赖平台库。
  ///
  /// 分类规则是拿真实采集站实测出来的（Windows 下 OS 错误码与 Linux 不同，
  /// 比如连接被拒在 Windows 上是 errno 1225 / 10061，Linux 是 111）。
  static String _describeRawError(String text) {
    if (text.contains('CERTIFICATE_VERIFY_FAILED') ||
        text.contains('certificate has expired') ||
        text.contains('CERTIFICATE')) {
      return 'HTTPS 证书无效或已过期';
    }
    if (text.contains('HandshakeException')) return 'TLS 握手失败';
    if (text.contains('Failed host lookup') ||
        text.contains('getaddrinfo') ||
        text.contains('No address associated')) {
      return '域名解析失败（站点可能已关停或换了域名）';
    }
    if (text.contains('Connection refused') ||
        text.contains('errno = 111') ||
        text.contains('errno = 1225') ||
        text.contains('errno = 10061') ||
        text.contains('拒绝网络连接')) {
      return '连接被拒绝';
    }
    if (text.contains('Connection reset') ||
        text.contains('errno = 104') ||
        text.contains('errno = 10054') ||
        text.contains('强制关闭')) {
      return '连接被重置';
    }
    if (text.contains('Network is unreachable')) return '网络不可达';
    if (text.contains('TimeoutException') || text.contains('timed out')) {
      return '连接超时';
    }
    return '网络错误';
  }

  /// 按响应推断编码后再解码。
  ///
  /// `http` 包的 `res.body` 在响应头**没有 `charset` 时按 latin1 解码**，
  /// 中文采集站的 UTF-8 字节会被解成乱码（片名一屏怪字符）。这里在没有明确
  /// charset 时改用 utf8，并把 `allowMalformed` 打开以免个别坏字节整段失败。
  ///
  /// ⚠️ GBK / GB2312 站点仍未支持：`dart:convert` 只自带 utf8 / latin1 / ascii，
  /// `Encoding.getByName('gbk')` 返回 null，此时退回 utf8（与改动前一样是乱码，
  /// 不会更差）。要真支持得引入 `charset_converter` 之类的依赖。
  static String _decode(http.Response res) {
    final contentType = res.headers['content-type'] ?? '';
    final match = RegExp(
      r'charset=([\w-]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    final charset = match?.group(1)?.toLowerCase();
    if (charset != null && charset != 'utf-8' && charset != 'utf8') {
      final codec = Encoding.getByName(charset);
      if (codec != null) {
        try {
          return codec.decode(res.bodyBytes);
        } catch (_) {
          // 解不了就落到下面的 utf8
        }
      }
    }
    try {
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return res.body;
    }
  }

  /// 拉取接口并按**响应内容**判定格式。
  ///
  /// 源清单里的 `type` 字段并不可靠 —— 内置源里就有标注错的例子
  /// （`taopianapi.com/cjapi/sda/vod/json.html` 被标成 `xml`，实际返回 JSON），
  /// 按 `type` 选解析器必然失败。这里改为看首字符：
  /// `{` / `[` → JSON，`<` → XML；都认不出就把两种都试一遍。
  Future<_Payload> _load(String url, {Duration? timeout}) async =>
      _parse(await _fetch(url, timeout: timeout));

  static _Payload _parse(String raw) {
    final t = raw.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) {
      final json = _tryJson(raw);
      if (json != null) return _Payload(json: json);
    }
    if (t.startsWith('<')) {
      final doc = _tryXml(raw);
      if (doc != null) return _Payload(xmlDoc: doc);
    }
    // 内容不像预期格式时，仍给两种解析各一次机会
    final json = _tryJson(raw);
    if (json != null) return _Payload(json: json);
    final doc = _tryXml(raw);
    if (doc != null) return _Payload(xmlDoc: doc);
    return _Payload(looksLikeHtml: _looksLikeHtml(t));
  }

  static bool _looksLikeHtml(String trimmed) {
    final t = trimmed.trimLeft();
    final head = t.length > 400
        ? t.substring(0, 400).toLowerCase()
        : t.toLowerCase();
    return head.contains('<!doctype html') ||
        head.contains('<html') ||
        head.contains('<head') ||
        head.contains('<body');
  }

  static Map<String, dynamic>? _tryJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      if (decoded is List && decoded.isNotEmpty) {
        return <String, dynamic>{'list': decoded};
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static xml.XmlDocument? _tryXml(String raw) {
    try {
      return xml.XmlDocument.parse(raw);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // json 源字段映射（对齐 xml 里 <video> 节点下的字段名）
  // ---------------------------------------------------------------------------

  static Video _mapVideo(Map<dynamic, dynamic> v) {
    return Video(
      id: _s(v['vod_id']),
      tid: _s(v['type_id']),
      name: _s(v['vod_name']),
      type: _typeName(v),
      pic: _s(v['vod_pic']),
      lang: _s(v['vod_lang']),
      area: _s(v['vod_area']),
      year: _s(v['vod_year']),
      note: _s(v['vod_remarks']),
      actor: _s(v['vod_actor']),
      director: _s(v['vod_director']),
      des: _s(v['vod_content']),
      last: _s(v['vod_time']),
    );
  }

  /// 分类名。
  ///
  /// 标准接口给扁平的字符串 `type_name`；新版 maccms（如 `movie.iqinu.com`）
  /// 把整个分类对象塞进 `type`、顶层 `type_name` 为空，直接 `toString()` 会把
  /// `{type_id: 3, type_name: 综艺, …}` 整串显示到卡片上。
  static String _typeName(Map<dynamic, dynamic> v) {
    final flat = _s(v['type_name']).trim();
    if (flat.isNotEmpty) return flat;
    final type = v['type'];
    if (type is Map) return _s(type['type_name']).trim();
    return _s(type).trim();
  }

  static PageInfo _mapPage(Map<dynamic, dynamic> d) {
    final size = _i(d['limit'] ?? d['pagesize'], 20);
    final total = _i(d['total'] ?? d['recordcount'], 0);
    var pages = _i(d['pagecount'], 0);
    // 有些网关只给 total + limit、不给 pagecount（`movie.iqinu.com` 就是）。
    // 缺了就自己算，否则总页数被当成 1，列表永远翻不到第二页。
    if (pages <= 0 && total > 0 && size > 0) {
      pages = (total + size - 1) ~/ size;
    }
    return PageInfo(
      page: _i(d['page'], 1),
      pagecount: pages > 0 ? pages : 1,
      pagesize: size > 0 ? size : 20,
      recordcount: total,
    );
  }

  /// 多播放线路：`vod_play_from` 与 `vod_play_url` 都是 `$$$` 分隔、按序号对应。
  ///
  /// ⚠️ 老实现只 `firstWhere(含 m3u8)` 取一段就返回，聚合站的其余线路被直接丢弃：
  /// 实测 `ys.cxkjg.cn` 同一部剧有 11 条线路（金鹰/闪电/非凡/量子/WS/速博/HD(SN)/
  /// 红牛/U酷/光速/樱花），App 里永远只看到第一条的 19 集，量子那条的 20、21 集
  /// 根本点不到，第一条失效时也没有替补。
  static List<PlayLine> _mapPlayLines(Map<dynamic, dynamic> v) {
    final groups = (v['vod_play_url'] ?? '').toString().split('\$\$\$');
    final names = (v['vod_play_from'] ?? '').toString().split('\$\$\$');
    final lines = <PlayLine>[];
    for (var i = 0; i < groups.length; i++) {
      final items = groups[i]
          .split('#')
          .map((x) => x.trim())
          .where((x) => x.isNotEmpty)
          .toList();
      if (items.isEmpty) continue;
      final raw = i < names.length ? names[i].trim() : '';
      // 名字缺失时给个可读的序号，UI 上至少能区分「线路1 / 线路2」
      lines.add(PlayLine(raw.isEmpty ? '线路${lines.length + 1}' : raw, items));
    }
    // 含 m3u8 的线路排前面：个别站会先给一段网页地址（需专用客户端），
    // 让内置播放器优先吃到能播的那条，原来的「优先 m3u8」策略保留下来。
    if (lines.length > 1) {
      final playable = <PlayLine>[];
      final others = <PlayLine>[];
      for (final line in lines) {
        final hit = line.items.any((x) => x.toLowerCase().contains('m3u8'));
        (hit ? playable : others).add(line);
      }
      return [...playable, ...others];
    }
    return lines;
  }

  static List<Video> _mapVideoList(dynamic list) {
    if (list == null) return <Video>[];
    final arr = list is List ? list : [list];
    return arr
        .whereType<Map>()
        .map((e) => _mapVideo(e))
        .where((v) => v.id.isNotEmpty)
        .toList();
  }

  /// 取文档中第一个同名节点，不存在返回 null（不依赖 Iterable.firstOrNull 扩展）
  static xml.XmlElement? _firstElement(xml.XmlDocument? doc, String name) {
    if (doc == null) return null;
    for (final e in doc.findAllElements(name)) {
      return e;
    }
    return null;
  }

  /// xml 的 <video> 节点 -> 通用字段 map
  static Map<String, dynamic> _xmlVideoToMap(xml.XmlElement v) {
    final map = <String, dynamic>{};
    for (final child in v.childElements) {
      map[child.name.local] = child.innerText.trim();
    }
    return map;
  }

  static Video _videoFromXml(xml.XmlElement v) =>
      Video.fromJson(_xmlVideoToMap(v));

  // ---------------------------------------------------------------------------
  // 接口
  // ---------------------------------------------------------------------------

  /// 获取视频源的分类。
  ///
  /// 先带 `?ac=list` 请求（maccms 的 json 接口只在这里带出分类），
  /// 拿不到再试裸接口（部分 xml 站在裸地址才输出 `<class>`）。
  Future<List<VideoClass>> fetchClasses(Site site) async {
    for (final url in <String>[
      _apiUrl(site, {'ac': 'list'}),
      site.api,
    ]) {
      final _Payload payload;
      try {
        payload = await _load(url);
      } catch (_) {
        // 连都连不上，换地址也一样，不必再等第二个超时
        return <VideoClass>[];
      }
      // 请求是成功的，只是这个地址没带出分类时才换下一个地址
      final fromJson = _classesFromJson(payload.json);
      if (fromJson.isNotEmpty) return fromJson;
      final fromXml = _classesFromXml(payload.xmlDoc);
      if (fromXml.isNotEmpty) return fromXml;
      // 兜底：接口只回片单、压根不给 class 列表（如 `movie.iqinu.com` 的
      // `/api.php/v1.vod`，`ac=list` 也只是最新 20 条）。这类站本来会被判成
      // 「只有『最新』一个分类」，所以从片单里的 `type` 反推分类表。
      final fromVideos = _classesFromVideos(payload.json);
      if (fromVideos.isNotEmpty) {
        return _extendClasses(site, fromVideos);
      }
    }
    return <VideoClass>[];
  }

  /// 取分类：json 结构
  static List<VideoClass> _classesFromJson(Map<String, dynamic>? json) {
    final list = <VideoClass>[];
    if (json == null) return list;
    final dataNode = json['data'];
    final raw = json['class'] ?? (dataNode is Map ? dataNode['class'] : null);
    if (raw is List) {
      for (final i in raw) {
        if (i is Map) {
          list.add(VideoClass(tid: _s(i['type_id']), name: _s(i['type_name'])));
        }
      }
    }
    return list;
  }

  /// 取分类：xml 结构
  static List<VideoClass> _classesFromXml(xml.XmlDocument? doc) {
    final list = <VideoClass>[];
    final cls = _firstElement(doc, 'class');
    if (cls == null) return list;
    for (final ty in cls.findElements('ty')) {
      list.add(
        VideoClass(tid: ty.getAttribute('id') ?? '', name: ty.innerText.trim()),
      );
    }
    return list;
  }

  /// 从片单反推分类（接口没有 class 列表时的兜底）。
  ///
  /// 兼容两种字段形态：标准 maccms 是顶层 `type_id` + `type_name`（或字符串
  /// `type`）；新版 maccms 把**整个分类对象**塞进 `type`（`type_name` 在里面）。
  /// 只看顶层字段会得到空表，那就是「这个网站只有一个分类」的由来。
  static List<VideoClass> _classesFromVideos(Map<String, dynamic>? json) {
    final out = <VideoClass>[];
    if (json == null) return out;
    final raw =
        json['list'] ?? (json['data'] is Map ? json['data']['list'] : null);
    if (raw is! List) return out;
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final type = item['type'];
      var tid = _s(item['type_id']).trim();
      var name = _s(item['type_name']).trim();
      if (type is Map) {
        if (tid.isEmpty) tid = _s(type['type_id']).trim();
        if (name.isEmpty) name = _s(type['type_name']).trim();
      } else if (name.isEmpty) {
        name = _s(type).trim();
      }
      if (tid.isEmpty || name.isEmpty) continue;
      if (seen.add(tid)) out.add(VideoClass(tid: tid, name: name));
    }
    return out;
  }

  /// 反推最多补几个相邻分类。
  static const int _classProbeExtra = 4;

  /// 补齐反推漏掉的冷门分类。
  ///
  /// 片单反推只覆盖「最新」那一页里出现过的类型，冷门分类（短剧之类）一条
  /// 都不会出现。按 tid 顺序往后探几个就能补上——分类 id 在 maccms 里是连续
  /// 分配的。探测并发执行，且**只在反推路径**上跑，正常给 class 的站不受影响。
  Future<List<VideoClass>> _extendClasses(
    Site site,
    List<VideoClass> base,
  ) async {
    final nums = base.map((c) => int.tryParse(c.tid)).whereType<int>().toList();
    if (nums.isEmpty) return base;
    final maxTid = nums.reduce((a, b) => a > b ? a : b);
    final extra = (await Future.wait(<Future<VideoClass?>>[
      for (var i = 1; i <= _classProbeExtra; i++)
        _probeClass(site, '${maxTid + i}'),
    ])).whereType<VideoClass>().toList();
    if (extra.isEmpty) return base;
    final out = <VideoClass>[...base, ...extra]
      ..sort((a, b) {
        final x = int.tryParse(a.tid);
        final y = int.tryParse(b.tid);
        if (x == null || y == null) return 0;
        return x.compareTo(y);
      });
    return out;
  }

  /// 探一个 tid 有没有资源；有就带上它自己的分类名。
  ///
  /// 站点若忽略 `tid`（回了「全部」片单），里面没有 tid 相同的项，这里返回
  /// null —— 不会凭空多出一个错分类。
  Future<VideoClass?> _probeClass(Site site, String tid) async {
    try {
      final payload = await _load(
        _apiUrl(site, _listParams(tid: tid, pg: 1)),
        timeout: const Duration(seconds: 6),
      );
      for (final c in _classesFromVideos(payload.json)) {
        if (c.tid == tid) return c;
      }
    } catch (_) {
      // 探测失败就当没有，不影响已经反推出的分类
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 源可用性检测
  // ---------------------------------------------------------------------------

  /// 检测专用超时：比正常取数短，免得一堆死站把「检测全部」拖到几分钟。
  ///
  /// 实测内置源 `?ac=list` 中位 1.4 秒、最慢 3.4 秒，6 秒留了近一倍余量；
  /// 而死站卡在「SYN 无响应」时，8 秒和 6 秒的体感差 2 秒，8 个源并发时
  /// 正好省掉一轮的时间。
  static const Duration _checkTimeout = Duration(seconds: 6);

  /// 检测单个源是否还能用。
  ///
  /// 判定方式与 App 自身取数据**完全一致**（请求 `?ac=list`），
  /// 所以"检测通过"和"首页真能加载出来"是同一件事，不是另写一套逻辑猜。
  ///
  /// - 解析出分类 / 片单 → [SiteHealth.ok]
  /// - 接口能连通但没有片单 → [SiteHealth.warn]
  ///   （域名还在、接口已改成网页，是采集站最常见的死法）
  /// - 连接层就失败，或返回内容不是采集接口 → [SiteHealth.fail]
  ///
  /// ⚠️ **失败会自动重试一次**：批量检测是 8 路并发，采集站对这种突发流量
  /// 很敏感（限流 / 5xx / 瞬时超时 / CDN 临时回源失败都是常态）。早期只测
  /// 一次就判 fail，而批量检测结束会把 fail 源自动停用 —— 用户看到的就是
  /// 「明明能用的源，检测一下就没了，再测一次又好了」。重试只对失败项发生，
  /// 成功 / 存疑一次就返回，所以整体速度几乎不受影响。
  Future<SiteCheckResult> checkSite(Site site, {bool retry = true}) async {
    if (site.api.trim().isEmpty) {
      return const SiteCheckResult(SiteHealth.fail, '接口地址为空', 0);
    }
    final sw = Stopwatch()..start();
    var result = await _checkSiteOnce(site, _checkTimeout);
    if (retry && result.health == SiteHealth.fail) {
      // 错峰重试：一批失败请求同时回重试会再次撞上限流，散开 300~700ms。
      // 第二次给更长的超时，慢站 / 冷启动的 CDN 才有机会回包。
      await Future<void>.delayed(
        Duration(milliseconds: 300 + math.Random().nextInt(400)),
      );
      final second = await _checkSiteOnce(site, const Duration(seconds: 9));
      if (second.health != SiteHealth.fail) result = second;
    }
    sw.stop();
    // 耗时按用户实际等待计入（含重试），显示出来才是真实体感
    return SiteCheckResult(result.health, result.message, sw.elapsedMilliseconds);
  }

  /// 单次探测：只负责发请求 + 分类判定，是否重试由 [checkSite] 决定。
  Future<SiteCheckResult> _checkSiteOnce(Site site, Duration timeout) async {
    final api = site.api.trim();
    final _Payload payload;
    try {
      payload = await _load(
        _apiUrl(site, {'ac': 'list'}),
        timeout: timeout,
      );
    } catch (e) {
      // 连接层就失败，换裸地址也是同样的错，不必再等一次超时
      return SiteCheckResult(SiteHealth.fail, describeRequestError(e), 0);
    }

    var classes = _classesFromJson(payload.json);
    if (classes.isEmpty) classes = _classesFromXml(payload.xmlDoc);
    var videos = _videosFrom(payload, site);

    // 部分 xml 站只在裸地址输出 <class>，与 fetchClasses 的回退保持一致。
    // 但如果带 `ac=list` 就已经返回网页，说明接口路径整体换了 —— 换裸地址
    // 只会再白等一个超时，直接判 fail（采集站最常见的死法就是主页还在、
    // 接口改成了网站页）。
    if (classes.isEmpty && videos.isEmpty && !payload.looksLikeHtml) {
      try {
        final bare = await _load(api, timeout: timeout);
        classes = _classesFromJson(bare.json);
        if (classes.isEmpty) classes = _classesFromXml(bare.xmlDoc);
        videos = _videosFrom(bare, site);
      } catch (_) {
        // 裸地址失败不影响已有结论
      }
    }

    if (classes.isNotEmpty) {
      return SiteCheckResult(SiteHealth.ok, '可用 · ${classes.length} 个分类', 0);
    }
    if (videos.isNotEmpty) {
      return SiteCheckResult(SiteHealth.ok, '可用 · ${videos.length} 条资源', 0);
    }
    if (payload.json != null || payload.xmlDoc != null) {
      return SiteCheckResult(SiteHealth.warn, '接口能连通，但没返回片单', 0);
    }
    if (payload.looksLikeHtml) {
      return const SiteCheckResult(SiteHealth.fail, '返回的是网页，接口已变更', 0);
    }
    return const SiteCheckResult(SiteHealth.fail, '返回内容不是采集接口', 0);
  }

  /// 获取视频列表
  ///
  /// [strict] = true 时**失败直接抛出**。首页翻页要靠它区分两种「空」：
  /// 「这页确实没有更多了」（应消费页号、收尾）与「这页没取到」（应回退页号、
  /// 挂出重试）。默认 false 保持原来的「失败返回空列表」，不影响其他调用方。
  Future<List<Video>> fetchList(
    Site site, {
    int pg = 1,
    String? tid,
    bool strict = false,
  }) async {
    final url = _apiUrl(site, _listParams(tid: tid, pg: pg));
    if (strict) return _videosFrom(await _load(url), site);
    try {
      return _videosFrom(await _load(url), site);
    } catch (_) {
      return <Video>[];
    }
  }

  /// 从解析结果里取片单：JSON / XML 两种结构都认，谁有数据用谁。
  ///
  /// 顺便把封面地址补成绝对 URL —— 采集站的 `vod_pic` 常见三种不规范写法
  /// （`//host/a.jpg`、`/upload/a.jpg`、`img.host.com/a.jpg`），图片组件拿到
  /// 这种地址解析失败，只会显示成破图标。
  static List<Video> _videosFrom(_Payload payload, Site site) {
    final fromJson = _videosFromJson(payload.json);
    final list = fromJson.isNotEmpty
        ? fromJson
        : _videosFromXml(payload.xmlDoc);
    if (list.isEmpty) return list;
    return list
        .map(
          (v) => v.pic.isEmpty ? v : v.copyWith(pic: _absolutePic(v.pic, site)),
        )
        .toList();
  }

  /// 图片地址补全：已经是 http(s) 的原样返回，其余按站点域名拼出绝对地址。
  static String _absolutePic(String pic, Site site) {
    final p = pic.trim();
    if (p.isEmpty) return p;
    final lower = p.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return p;

    String origin = '';
    try {
      final u = Uri.parse(site.api.trim());
      if (u.hasScheme && u.host.isNotEmpty) origin = '${u.scheme}://${u.host}';
    } catch (_) {
      // 站点地址本身不规范就放弃拼域名，保留原值
    }
    // 省了协议：//host/a.jpg
    if (p.startsWith('//')) return 'https:$p';
    // 省了域名：/upload/a.jpg
    if (p.startsWith('/')) return origin.isEmpty ? p : '$origin$p';

    // 省了协议：img.host.com/upload/a.jpg（首段像域名才补，避免把
    // `upload/a.jpg` 这种相对路径误拼成 http://upload/...）
    final firstSeg = p.split('/').first;
    final looksLikeHost =
        firstSeg.contains('.') &&
        !RegExp(
          r'\.(?:jpe?g|png|gif|webp|bmp|avif)$',
          caseSensitive: false,
        ).hasMatch(firstSeg);
    if (looksLikeHost) return 'http://$p';
    return p;
  }

  static List<Video> _videosFromJson(Map<String, dynamic>? json) {
    if (json == null) return <Video>[];
    final raw =
        json['list'] ?? (json['data'] is Map ? json['data']['list'] : null);
    return _mapVideoList(raw);
  }

  static List<Video> _videosFromXml(xml.XmlDocument? doc) {
    final listNode = _firstElement(doc, 'list');
    if (listNode == null) return <Video>[];
    return listNode
        .findElements('video')
        .map(_videoFromXml)
        .where((v) => v.id.isNotEmpty)
        .toList();
  }

  /// 获取总资源数与页数
  Future<PageInfo> fetchPage(Site site, {String? tid}) async {
    try {
      final payload = await _load(_apiUrl(site, _listParams(tid: tid)));
      if (payload.json != null) return _pageFromJson(payload.json!);
      return _pageFromXml(payload.xmlDoc);
    } catch (_) {
      return const PageInfo(ok: false);
    }
  }

  static PageInfo _pageFromJson(Map<String, dynamic> json) {
    final dataNode = json['data'];
    final Map<dynamic, dynamic> data = dataNode is Map ? dataNode : json;
    return _mapPage(data);
  }

  static PageInfo _pageFromXml(xml.XmlDocument? doc) {
    final listNode = _firstElement(doc, 'list');
    // 拿到网页而不是采集接口时 listNode 为空：这是「没取到」而不是「只有 1 页」
    if (listNode == null) return const PageInfo(ok: false);
    return PageInfo(
      page: _i(listNode.getAttribute('page'), 1),
      pagecount: _i(listNode.getAttribute('pagecount'), 1),
      pagesize: _i(listNode.getAttribute('pagesize'), 20),
      recordcount: _i(listNode.getAttribute('recordcount'), 0),
    );
  }

  /// 回包里到底有没有「采集数据」的形状。
  ///
  /// 只看 `json == null && xmlDoc == null` 不够：`<html><body>…</body></html>`
  /// 这类网页能被 XML 解析器整段吃进去（xmlDoc 非空），于是「不认 videolist
  /// 的站」永远走不到回退分支，搜索结果直接是空的。
  static bool _looksLikeCollection(_Payload p) {
    if (p.json != null) return true;
    final doc = p.xmlDoc;
    if (doc == null) return false;
    return _firstElement(doc, 'list') != null ||
        doc.findAllElements('video').isNotEmpty;
  }

  /// 搜索资源（只要第一页）。保留给不需要翻页的调用方。
  Future<List<Video>> search(Site site, String keyword) async =>
      (await searchPaged(site, keyword)).videos;

  /// 搜索资源，可指定页码（从 1 开始）。
  ///
  /// ⚠️ 必须带 `ac=videolist`。采集站默认走 `ac=list`，只回精简字段
  /// （`vod_id` / `vod_name` / `vod_remarks`…），**不含 `vod_pic`**。首页列表一直
  /// 带着 videolist 所以有封面，搜索漏了这个参数，表现就是「搜索结果的卡片全没图，
  /// 点进详情（走的是另一支接口）却能看到海报，返回列表继续没图」。
  ///
  /// ⚠️ `pg` / `page` 两个参数一起带（与 [_listParams] 同样的坑）：标准 maccms 认
  /// `pg`，有一批网关只认 `page`，只带一个会出现「翻页翻不动、永远第一页」。
  /// 第 1 页不带页码参数，尽量少改请求形状，兼容那些对多余参数敏感的老站。
  ///
  /// 少数站不认 `videolist + wd`（返回网页或直接报错），这时退回老参数再试一次：
  /// 宁可没封面，也不能搜不到。
  Future<SearchPageResult> searchPaged(
    Site site,
    String keyword, {
    int pg = 1,
  }) async {
    final page = pg < 1 ? 1 : pg;
    final legacy = <String, String>{
      'wd': keyword,
      if (page > 1) 'pg': '$page',
      if (page > 1) 'page': '$page',
    };
    try {
      final payload = await _load(
        _apiUrl(site, {'ac': 'videolist', ...legacy}),
      );
      // 回包里没有采集数据的形状（网页 / 空正文）→ 这个站不认 videolist，
      // 退回老参数再试一次
      if (!_looksLikeCollection(payload)) {
        return _searchResultFrom(
          await _load(_apiUrl(site, legacy)),
          site,
          page,
        );
      }
      return _searchResultFrom(payload, site, page);
    } catch (_) {
      try {
        return _searchResultFrom(
          await _load(_apiUrl(site, legacy)),
          site,
          page,
        );
      } catch (_) {
        return SearchPageResult(videos: const <Video>[], page: page);
      }
    }
  }

  static SearchPageResult _searchResultFrom(
    _Payload payload,
    Site site,
    int page,
  ) {
    final info = payload.json != null
        ? _pageFromJson(payload.json!)
        : _pageFromXml(payload.xmlDoc);
    return SearchPageResult(
      videos: _videosFrom(payload, site),
      page: page,
      pageSize: info.pagesize > 0 ? info.pagesize : 20,
      // ok = false 表示没拿到分页信息（回了网页 / 空包），按「未知」处理，
      // 交给「不满一页就到底」那条兜底，而不是当成只有一页。
      pagecount: info.ok ? info.pagecount : 0,
    );
  }

  /// 获取资源详情（含播放列表）。
  ///
  /// 采集站大多是个人小水管，偶发超时 / 连接被重置 / 5xx。详情页只在进入时请求
  /// 一次，若直接挂掉就表现为"点卡片/搜索结果/收藏记录，有时候显示获取详情失败"。
  /// 这里对**瞬时错误**重试 [_detailMaxRetries] 次（指数退避），非瞬时错误
  /// （403 / 404 / 改版）不重试；最终仍失败则把原因抛给上层，由详情页提示并
  /// 给出"重试"按钮，而不是静默返回一个死掉的 null。
  Future<VideoDetail?> fetchDetail(Site site, String id) async {
    late HttpRequestException lastErr;
    for (var attempt = 0; attempt <= _detailMaxRetries; attempt++) {
      try {
        final payload = await _load(
          _apiUrl(site, {'ac': 'videolist', 'ids': id}),
          timeout: _detailTimeout,
        );
        final detail =
            _detailFromJson(payload.json) ?? _detailFromXml(payload.xmlDoc);
        if (detail == null && payload.looksLikeHtml) {
          throw const HttpRequestException('接口返回了网页而非数据（站点可能已改版）');
        }
        return detail;
      } on HttpRequestException catch (e) {
        lastErr = e;
        if (attempt == _detailMaxRetries || !_isTransientReason(e.reason)) {
          break;
        }
        await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    throw lastErr;
  }

  static VideoDetail? _detailFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final raw =
        json['list'] ?? (json['data'] is Map ? json['data']['list'] : null);
    final arr = raw is List
        ? raw.whereType<Map>().toList()
        : (raw is Map ? <Map>[raw] : <Map>[]);
    if (arr.isEmpty) return null;
    return VideoDetail.fromVideo(
      _mapVideo(arr.first),
      lines: _mapPlayLines(arr.first),
    );
  }

  static VideoDetail? _detailFromXml(xml.XmlDocument? doc) {
    final videoNode = _firstElement(doc, 'video');
    if (videoNode == null) return null;
    final detail = VideoDetail.fromVideo(_videoFromXml(videoNode));
    // 多个 <dd> 就是多条线路，flag 属性是线路名（`m3u8` / `ffm3u8` / `bfzym3u8`…）。
    // 以前只采第一个带 m3u8 的 dd 就 break，与 json 侧的丢数据问题一样。
    final lines = <PlayLine>[];
    for (final dd in videoNode.findAllElements('dd')) {
      final items = dd.innerText
          .split('#')
          .map((x) => x.trim())
          .where((x) => x.isNotEmpty)
          .toList();
      if (items.isEmpty) continue;
      final flag = (dd.getAttribute('flag') ?? '').trim();
      lines.add(PlayLine(
        flag.isEmpty ? '线路${lines.length + 1}' : flag,
        items,
      ));
    }
    return VideoDetail.fromVideo(detail, lines: lines);
  }

  // --------------------------------------------------------------------------
  // 配置导入（TVBox / ZYFun）
  // --------------------------------------------------------------------------

  /// 配置导入的单次请求超时（导航页还要接着拉子配置，别拖太久）
  static const Duration _configTimeout = Duration(seconds: 15);
  static const Duration _configSubTimeout = Duration(seconds: 8);

  /// 像是 maccms 接口地址（用户直接粘贴接口而不是配置时用）
  static final RegExp _maccmsApiRe = RegExp(
    r'api\.php|provide/vod',
    caseSensitive: false,
  );

  /// 网页里提取链接用
  static final RegExp _attrRe = RegExp(
    r'''(?:href|src|data-url|data-src|data-href)\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _bareUrlRe = RegExp(
    r'''https?://[^\s"'<>()]+''',
    caseSensitive: false,
  );

  /// 静态资源 / 普通网页，不当作配置候选
  static final RegExp _skipAssetRe = RegExp(
    r'''\.(?:css|js|mjs|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|eot|mp4|m3u8|html?)(?:[?#]|$)''',
    caseSensitive: false,
  );

  /// 地址里带这些词才当作配置候选
  static final RegExp _configHintRe = RegExp(
    r'''(?:tvbox|config|interface|接口|\.json|\.txt|api\.php|provide/vod)''',
    caseSensitive: false,
  );

  /// 通过配置地址导入视频源。
  ///
  /// 与本地文件导入走**同一套解析**（[SourceImport]），并对真实场景做了这些
  /// 兜底：
  /// - 地址不规范：`box.xxx.com`、`http:box.xxx.com`、中文域名；
  /// - 返回 JSONP / 夹带说明文字；
  /// - 直接给了 TVBox「导航页」：自动从页面里找 `.json` 配置链接再拉一次；
  /// - TVBox 多仓配置：`{"urls":[...]}` 自动拉取子配置并合并；
  /// - 直接粘贴了 maccms 接口地址：识别后作为单个源导入。
  Future<ImportSummary> importSites(String rawUrl) async {
    final start = normalizeConfigUrl(rawUrl);
    if (start.isEmpty) {
      return const ImportSummary(
        sites: [],
        skipped: 0,
        format: 'unknown',
        message: '请输入配置地址',
      );
    }

    final tried = <String>{};
    final errors = <String>[];
    // 输入 http 时也试试 https（很多站点强制跳转），反之亦然
    for (final candidate in _schemeVariants(start)) {
      if (!tried.add(candidate)) continue;
      final summary = await _importFrom(candidate, tried, errors, depth: 0);
      if (summary != null && summary.sites.isNotEmpty) return summary;
    }

    return ImportSummary(
      sites: const [],
      skipped: 0,
      format: 'unknown',
      message: errors.isEmpty ? '没有找到可用的视频源' : errors.first,
    );
  }

  List<String> _schemeVariants(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return <String>[url];
    final out = <String>[url];
    if (uri.scheme == 'https') {
      out.add(uri.replace(scheme: 'http').toString());
    } else if (uri.scheme == 'http') {
      out.add(uri.replace(scheme: 'https').toString());
    }
    return out;
  }

  /// 拉一个地址并尝试解析成源清单；失败返回 null（原因写入 [errors]）。
  Future<ImportSummary?> _importFrom(
    String url,
    Set<String> tried,
    List<String> errors, {
    required int depth,
  }) async {
    final String text;
    try {
      text = await _fetchConfig(
        url,
        depth == 0 ? _configTimeout : _configSubTimeout,
      );
    } catch (e) {
      errors.add('$url：${describeRequestError(e)}');
      return null;
    }
    if (text.trim().isEmpty) {
      errors.add('$url：返回内容为空');
      return null;
    }

    // TVBox 加密配置（`$#key#$` + hex + AES-128-CBC）：先解密再走普通解析
    final decrypted = TvBoxCrypto.decode(text);
    final config = decrypted ?? text;

    final parsed = SourceImport.parse(config);
    if (parsed.sites.isNotEmpty) return parsed;

    if (_looksEncrypted(text)) {
      errors.add(
        decrypted == null
            ? '$url：配置已加密，且无法用 TVBox 通用算法解密'
            : '$url：配置解密成功，但里面没有可直接播放的视频源',
      );
      return null;
    }

    // 用户直接粘贴了 maccms 接口地址（返回的是片单而不是配置）
    final direct = _directMaccmsSite(url, text);
    if (direct != null) return direct;

    // 多仓配置：{"urls":[{"url":"..."}]}
    if (depth < 2) {
      final repos = SourceImport.repoUrls(config);
      if (repos.isNotEmpty) {
        final merged = await _importRepos(repos, tried, errors, depth);
        if (merged != null) return merged;
      }
    }

    // 导航网页：自动找页面里的配置链接（只对用户输入的首个地址做一层）
    if (depth == 0 && _looksLikeHtml(text)) {
      final links = _extractConfigLinks(text, url);
      // 导航页可能列几十个链接，逐个超时会等到天荒地老；
      // 给整轮尝试一个总时限，超时就带着已收集的原因返回。
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      for (final link in links.take(6)) {
        if (DateTime.now().isAfter(deadline)) break;
        if (!tried.add(link)) continue;
        final summary = await _importFrom(link, tried, errors, depth: 1);
        if (summary != null && summary.sites.isNotEmpty) {
          return ImportSummary(
            sites: summary.sites,
            skipped: summary.skipped,
            format: summary.format,
            message: '已从页面自动识别配置：$link',
          );
        }
      }
    }

    if (parsed.message.isNotEmpty) {
      errors.add('$url：${parsed.message}');
    }
    return null;
  }

  /// 多仓配置：逐个拉子配置并合并（最多 6 个，避免一个仓库拖很久）。
  Future<ImportSummary?> _importRepos(
    List<String> repos,
    Set<String> tried,
    List<String> errors,
    int depth,
  ) async {
    final sites = <Site>[];
    final seen = <String>{};
    var skipped = 0;
    var format = 'unknown';
    for (final repo in repos.take(5)) {
      final url = normalizeConfigUrl(repo);
      if (url.isEmpty || !tried.add(url)) continue;
      final summary = await _importFrom(url, tried, errors, depth: depth + 1);
      if (summary == null || summary.sites.isEmpty) continue;
      skipped += summary.skipped;
      if (summary.format != 'unknown') format = summary.format;
      for (final site in summary.sites) {
        final sig = site.api.trim().toLowerCase();
        if (seen.add(sig)) sites.add(site);
      }
    }
    if (sites.isEmpty) return null;
    return ImportSummary(
      sites: sites,
      skipped: skipped,
      format: format,
      message: '已导入多仓配置中的 ${sites.length} 个源',
    );
  }

  /// 直接给的地址本身就是 maccms 接口时，把它当成单个源导入。
  ImportSummary? _directMaccmsSite(String url, String text) {
    if (!_maccmsApiRe.hasMatch(url)) return null;
    final head = text.trimLeft();
    String? type;
    if (head.startsWith('<?xml') || head.startsWith('<rss')) {
      type = 'xml';
    } else {
      try {
        final decoded = jsonDecode(head);
        if (decoded is Map && decoded.containsKey('list')) type = 'json';
      } catch (_) {
        // 不是 maccms 返回，交给后续流程
      }
    }
    if (type == null) return null;

    final host = Uri.tryParse(url)?.host ?? '';
    final key = host.isNotEmpty ? host : 'maccms';
    return ImportSummary(
      sites: <Site>[
        Site(
          id: 0,
          key: key,
          name: host.isNotEmpty ? host : 'maccms 接口',
          api: url,
          type: type,
          group: '导入',
        ),
      ],
      skipped: 0,
      format: 'maccms',
      message: '已识别为 maccms 接口',
    );
  }

  /// TVBox 的加密配置是一大段纯十六进制，直接给出明确提示。
  bool _looksEncrypted(String text) {
    final t = text.trim();
    if (t.length < 200 || t.contains('{')) return false;
    return RegExp(r'^[0-9a-fA-F\s]+$').hasMatch(t);
  }

  /// 从导航网页里提取可能的配置地址：`href/src` 属性 + 正文裸链接。
  List<String> _extractConfigLinks(String html, String baseUrl) {
    final base = Uri.tryParse(baseUrl);
    final out = <String>[];
    final seen = <String>{};

    void add(String raw) {
      var value = raw.trim().replaceAll('&amp;', '&');
      // 正文里的裸链接后面常跟着中文标点，去掉再解析
      while (value.isNotEmpty && '.,;，。、:：'.contains(value[value.length - 1])) {
        value = value.substring(0, value.length - 1);
      }
      if (value.isEmpty) return;
      final lowerRaw = value.toLowerCase();
      if (lowerRaw.startsWith('javascript:') ||
          lowerRaw.startsWith('mailto:') ||
          lowerRaw.startsWith('data:') ||
          lowerRaw.startsWith('#')) {
        return;
      }
      Uri? uri;
      try {
        uri = base == null ? Uri.parse(value) : base.resolve(value);
      } catch (_) {
        return;
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') return;
      final full = uri.toString();
      final lower = full.toLowerCase();
      if (lower == baseUrl.toLowerCase()) return;
      if (!_maccmsApiRe.hasMatch(lower)) {
        if (_skipAssetRe.hasMatch(lower)) return;
        if (!_configHintRe.hasMatch(lower)) return;
      }
      if (seen.add(full)) out.add(full);
    }

    for (final m in _attrRe.allMatches(html)) {
      add(m.group(1)!);
    }
    for (final m in _bareUrlRe.allMatches(html)) {
      add(m.group(0)!);
    }
    // .json 结尾的优先试
    out.sort((a, b) {
      final aj = a.toLowerCase().endsWith('.json') ? 0 : 1;
      final bj = b.toLowerCase().endsWith('.json') ? 0 : 1;
      return aj.compareTo(bj);
    });
    return out;
  }

  static String _s(dynamic v) => v == null ? '' : v.toString();

  static int _i(dynamic v, int fallback) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? fallback;
  }
}
