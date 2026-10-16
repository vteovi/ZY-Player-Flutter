import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../models/site.dart';
import '../models/video.dart';
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

  static const Duration _timeout = Duration(seconds: 15);

  /// 详情请求专用超时：比列表短一些，配合下面的重试把最坏等待压住。
  static const Duration _detailTimeout = Duration(seconds: 12);

  /// 详情请求对**瞬时错误**的重试次数。
  ///
  /// 采集站大多是个人小水管，偶发超时 / 连接被重置 / 5xx；重试大概率能救回来。
  static const int _detailMaxRetries = 2;

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
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

  Future<String> _get(String url) async {
    final res =
        await http.get(Uri.parse(url), headers: _headers).timeout(_timeout);
    return _decode(res);
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
    final head = trimmed.length > 400
        ? trimmed.substring(0, 400).toLowerCase()
        : trimmed.toLowerCase();
    return head.contains('<!doctype html') || head.contains('<html');
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
  Future<List<Video>> fetchList(Site site, {int pg = 1, String? tid}) async {
    try {
      final params = <String, String>{'ac': 'videolist'};
      if (tid != null && tid.isNotEmpty && tid != '0') params['t'] = tid;
      params['pg'] = '$pg';
      return _videosFrom(await _load(_apiUrl(site, params)));
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

  /// 通过 json 地址导入视频源。
  ///
  /// 与本地文件导入走**同一套解析**（[SourceImport]），
  /// 这样 `tbl_site` / 裸数组 / TVBox 等几种导出格式的表现完全一致。
  Future<List<Site>> importSites(String jsonUrl) async {
    try {
      final raw = await _get(jsonUrl);
      return SourceImport.parse(raw).sites;
    } catch (_) {
      return <Site>[];
    }
  }

  static String _s(dynamic v) => v == null ? '' : v.toString();

  static int _i(dynamic v, int fallback) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? fallback;
  }
}
