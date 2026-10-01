import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../models/site.dart';
import '../models/video.dart';
import 'source_import.dart';

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

  const _Payload({this.json, this.xmlDoc});
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
  Future<String> _fetch(String url) async {
    final uri = Uri.parse(url);
    var worthRetry = false;
    try {
      final res = await http.get(uri, headers: _headers).timeout(_timeout);
      if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
        return _decode(res);
      }
      worthRetry = res.statusCode >= 400 && res.statusCode < 500;
    } catch (_) {
      worthRetry = false;
    }
    if (worthRetry) {
      try {
        final res = await http.post(uri, headers: _headers).timeout(_timeout);
        if (res.statusCode >= 200 &&
            res.statusCode < 300 &&
            res.body.isNotEmpty) {
          return _decode(res);
        }
      } catch (_) {
        // 落到下面统一抛出
      }
    }
    throw Exception('请求失败: $url');
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
  Future<_Payload> _load(String url) async => _parse(await _fetch(url));

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
    return const _Payload();
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

  /// 获取资源详情（含播放列表）
  Future<VideoDetail?> fetchDetail(Site site, String id) async {
    try {
      final payload =
          await _load(_apiUrl(site, {'ac': 'videolist', 'ids': id}));
      final fromJson = _detailFromJson(payload.json);
      if (fromJson != null) return fromJson;
      return _detailFromXml(payload.xmlDoc);
    } catch (_) {
      return null;
    }
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
