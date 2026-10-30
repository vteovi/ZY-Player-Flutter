import 'dart:async';
import 'dart:convert';

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

  const PageInfo({
    this.page = 1,
    this.pagecount = 1,
    this.pagesize = 20,
    this.recordcount = 0,
  });
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
      final res = await http.get(uri, headers: _headers).timeout(limit);
      if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
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
        final res = await http.post(uri, headers: _headers).timeout(limit);
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
    final res = await http.get(
      Uri.parse(url),
      headers: <String, String>{
        'User-Agent': userAgent,
        'Accept': _configAccept,
      },
    ).timeout(limit);
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
    final match =
        RegExp(r'charset=([\w-]+)', caseSensitive: false).firstMatch(contentType);
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
      type: _s(v['type_name']),
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

  static PageInfo _mapPage(Map<dynamic, dynamic> d) {
    return PageInfo(
      page: _i(d['page'], 1),
      pagecount: _i(d['pagecount'], 1),
      pagesize: _i(d['limit'], 20),
      recordcount: _i(d['total'], 0),
    );
  }

  /// 多播放源用 $$$ 分隔，集数用 # 分隔，每集为「名称$地址」
  static List<String> _mapPlayList(Map<dynamic, dynamic> v) {
    final groups = (v['vod_play_url'] ?? '').toString().split('\$\$\$');
    final nonEmpty = groups.where((x) => x.isNotEmpty).toList();
    final group = nonEmpty.firstWhere(
          (x) => x.toLowerCase().contains('m3u8'),
          orElse: () => nonEmpty.isNotEmpty ? nonEmpty.first : '',
        );
    if (group.isEmpty) return <String>[];
    return group.split('#').where((x) => x.isNotEmpty).toList();
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
    for (final url in <String>[_apiUrl(site, {'ac': 'list'}), site.api]) {
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
      list.add(VideoClass(
        tid: ty.getAttribute('id') ?? '',
        name: ty.innerText.trim(),
      ));
    }
    return list;
  }

  // ---------------------------------------------------------------------------
  // 源可用性检测
  // ---------------------------------------------------------------------------

  /// 检测专用超时：比正常取数短，免得一堆死站把「检测全部」拖到几分钟
  static const Duration _checkTimeout = Duration(seconds: 8);

  /// 检测单个源是否还能用。
  ///
  /// 判定方式与 App 自身取数据**完全一致**（请求 `?ac=list`），
  /// 所以"检测通过"和"首页真能加载出来"是同一件事，不是另写一套逻辑猜。
  ///
  /// - 解析出分类 / 片单 → [SiteHealth.ok]
  /// - 接口能连通但没有片单 → [SiteHealth.warn]
  ///   （域名还在、接口已改成网页，是采集站最常见的死法）
  /// - 连接层就失败，或返回内容不是采集接口 → [SiteHealth.fail]
  Future<SiteCheckResult> checkSite(Site site) async {
    final api = site.api.trim();
    if (api.isEmpty) {
      return const SiteCheckResult(SiteHealth.fail, '接口地址为空', 0);
    }
    final sw = Stopwatch()..start();

    final _Payload payload;
    try {
      payload =
          await _load(_apiUrl(site, {'ac': 'list'}), timeout: _checkTimeout);
    } catch (e) {
      sw.stop();
      // 连接层就失败，换裸地址也是同样的错，不必再等一次超时
      return SiteCheckResult(
        SiteHealth.fail,
        describeRequestError(e),
        sw.elapsedMilliseconds,
      );
    }

    var classes = _classesFromJson(payload.json);
    if (classes.isEmpty) classes = _classesFromXml(payload.xmlDoc);
    var videos = _videosFrom(payload);

    // 部分 xml 站只在裸地址输出 <class>，与 fetchClasses 的回退保持一致
    if (classes.isEmpty && videos.isEmpty) {
      try {
        final bare = await _load(api, timeout: _checkTimeout);
        classes = _classesFromJson(bare.json);
        if (classes.isEmpty) classes = _classesFromXml(bare.xmlDoc);
        videos = _videosFrom(bare);
      } catch (_) {
        // 裸地址失败不影响已有结论
      }
    }
    sw.stop();
    final ms = sw.elapsedMilliseconds;

    if (classes.isNotEmpty) {
      return SiteCheckResult(SiteHealth.ok, '可用 · ${classes.length} 个分类', ms);
    }
    if (videos.isNotEmpty) {
      return SiteCheckResult(SiteHealth.ok, '可用 · ${videos.length} 条资源', ms);
    }
    if (payload.json != null || payload.xmlDoc != null) {
      return SiteCheckResult(SiteHealth.warn, '接口能连通，但没返回片单', ms);
    }
    if (payload.looksLikeHtml) {
      return SiteCheckResult(SiteHealth.fail, '返回的是网页，接口已变更', ms);
    }
    return SiteCheckResult(SiteHealth.fail, '返回内容不是采集接口', ms);
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
    final params = <String, String>{'ac': 'videolist'};
    if (tid != null && tid.isNotEmpty && tid != '0') params['t'] = tid;
    params['pg'] = '$pg';
    final url = _apiUrl(site, params);
    if (strict) return _videosFrom(await _load(url));
    try {
      return _videosFrom(await _load(url));
    } catch (_) {
      return <Video>[];
    }
  }

  /// 从解析结果里取片单：JSON / XML 两种结构都认，谁有数据用谁
  static List<Video> _videosFrom(_Payload payload) {
    final fromJson = _videosFromJson(payload.json);
    if (fromJson.isNotEmpty) return fromJson;
    return _videosFromXml(payload.xmlDoc);
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
      final params = <String, String>{'ac': 'videolist'};
      if (tid != null && tid.isNotEmpty && tid != '0') params['t'] = tid;
      final payload = await _load(_apiUrl(site, params));
      if (payload.json != null) return _pageFromJson(payload.json!);
      return _pageFromXml(payload.xmlDoc);
    } catch (_) {
      return const PageInfo();
    }
  }

  static PageInfo _pageFromJson(Map<String, dynamic> json) {
    final dataNode = json['data'];
    final Map<dynamic, dynamic> data = dataNode is Map ? dataNode : json;
    return _mapPage(data);
  }

  static PageInfo _pageFromXml(xml.XmlDocument? doc) {
    final listNode = _firstElement(doc, 'list');
    if (listNode == null) return const PageInfo();
    return PageInfo(
      page: _i(listNode.getAttribute('page'), 1),
      pagecount: _i(listNode.getAttribute('pagecount'), 1),
      pagesize: _i(listNode.getAttribute('pagesize'), 20),
      recordcount: _i(listNode.getAttribute('recordcount'), 0),
    );
  }

  /// 搜索资源
  Future<List<Video>> search(Site site, String keyword) async {
    try {
      return _videosFrom(await _load(_apiUrl(site, {'wd': keyword})));
    } catch (_) {
      return <Video>[];
    }
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
      m3u8List: _mapPlayList(arr.first),
    );
  }

  static VideoDetail? _detailFromXml(xml.XmlDocument? doc) {
    final videoNode = _firstElement(doc, 'video');
    if (videoNode == null) return null;
    final detail = VideoDetail.fromVideo(_videoFromXml(videoNode));
    final ddList = videoNode.findAllElements('dd').toList();
    final m3u8List = <String>[];
    if (ddList.length == 1) {
      m3u8List.addAll(ddList.first.innerText.split('#'));
    } else {
      for (final dd in ddList) {
        if ((dd.getAttribute('flag') ?? '').contains('m3u8')) {
          m3u8List.addAll(dd.innerText.split('#'));
          break;
        }
      }
    }
    return VideoDetail.fromVideo(detail, m3u8List: m3u8List);
  }

  // --------------------------------------------------------------------------
  // 配置导入（TVBox / ZYFun）
  // --------------------------------------------------------------------------

  /// 配置导入的单次请求超时（导航页还要接着拉子配置，别拖太久）
  static const Duration _configTimeout = Duration(seconds: 15);
  static const Duration _configSubTimeout = Duration(seconds: 8);

  /// 像是 maccms 接口地址（用户直接粘贴接口而不是配置时用）
  static final RegExp _maccmsApiRe =
      RegExp(r'api\.php|provide/vod', caseSensitive: false);

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
      final summary =
          await _importFrom(candidate, tried, errors, depth: 0);
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
      final summary =
          await _importFrom(url, tried, errors, depth: depth + 1);
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
      while (value.isNotEmpty &&
          '.,;，。、:：'.contains(value[value.length - 1])) {
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
