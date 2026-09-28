import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../models/site.dart';
import '../models/video.dart';

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

  /// 统一走 POST，与 uni-app 版 uni-ajax 保持一致
  Future<String> _post(String url) async {
    final res = await http
        .post(Uri.parse(url), headers: _headers)
        .timeout(_timeout);
    return res.body;
  }

  Future<String> _get(String url) async {
    final res =
        await http.get(Uri.parse(url), headers: _headers).timeout(_timeout);
    return res.body;
  }

  Future<Map<String, dynamic>?> _json(Site site, String url) async {
    final raw = await _post(url);
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

  Future<xml.XmlDocument?> _xmlDoc(String url) async {
    final raw = await _post(url);
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

  /// 获取视频源的分类
  Future<List<VideoClass>> fetchClasses(Site site) async {
    final list = <VideoClass>[];
    try {
      if (site.isJson) {
        // maccms 的 json 接口里，分类只在 ac=list 的返回中带出来
        final json = await _json(site, '${site.api}?ac=list');
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
      final cls = _firstElement(await _xmlDoc(site.api), 'class');
      if (cls == null) return list;
      for (final ty in cls.findElements('ty')) {
        list.add(VideoClass(
          tid: ty.getAttribute('id') ?? '',
          name: ty.innerText.trim(),
        ));
      }
      return list;
    } catch (_) {
      return list;
    }
  }

  /// 获取视频列表
  Future<List<Video>> fetchList(Site site, {int pg = 1, String? tid}) async {
    try {
      final url =
          '${site.api}?ac=videolist${(tid != null && tid.isNotEmpty && tid != '0') ? '&t=$tid' : ''}&pg=$pg';
      if (site.isJson) {
        final json = await _json(site, url);
        if (json == null) return <Video>[];
        final raw = json['list'] ?? (json['data'] is Map ? json['data']['list'] : null);
        return _mapVideoList(raw);
      }
      final listNode = _firstElement(await _xmlDoc(url), 'list');
      if (listNode == null) return <Video>[];
      return listNode
          .findElements('video')
          .map(_videoFromXml)
          .where((v) => v.id.isNotEmpty)
          .toList();
    } catch (_) {
      return <Video>[];
    }
  }

  /// 获取总资源数与页数
  Future<PageInfo> fetchPage(Site site, {String? tid}) async {
    try {
      final url =
          '${site.api}?ac=videolist${(tid != null && tid.isNotEmpty && tid != '0') ? '&t=$tid' : ''}';
      if (site.isJson) {
        final json = await _json(site, url);
        if (json == null) return const PageInfo();
        final dataNode = json['data'];
        final Map<dynamic, dynamic> data = dataNode is Map ? dataNode : json;
        return _mapPage(data);
      }
      final listNode = _firstElement(await _xmlDoc(url), 'list');
      if (listNode == null) return const PageInfo();
      return PageInfo(
        page: _i(listNode.getAttribute('page'), 1),
        pagecount: _i(listNode.getAttribute('pagecount'), 1),
        pagesize: _i(listNode.getAttribute('pagesize'), 20),
        recordcount: _i(listNode.getAttribute('recordcount'), 0),
      );
    } catch (_) {
      return const PageInfo();
    }
  }

  /// 搜索资源
  Future<List<Video>> search(Site site, String keyword) async {
    try {
      final wd = Uri.encodeComponent(keyword);
      final url = '${site.api}?wd=$wd';
      if (site.isJson) {
        final json = await _json(site, url);
        if (json == null) return <Video>[];
        final raw = json['list'] ?? (json['data'] is Map ? json['data']['list'] : null);
        return _mapVideoList(raw);
      }
      final listNode = _firstElement(await _xmlDoc(url), 'list');
      if (listNode == null) return <Video>[];
      return listNode
          .findElements('video')
          .map(_videoFromXml)
          .where((v) => v.id.isNotEmpty)
          .toList();
    } catch (_) {
      return <Video>[];
    }
  }

  /// 获取资源详情（含播放列表）
  Future<VideoDetail?> fetchDetail(Site site, String id) async {
    try {
      final url = '${site.api}?ac=videolist&ids=$id';
      if (site.isJson) {
        final json = await _json(site, url);
        if (json == null) return null;
        final raw = json['list'] ?? (json['data'] is Map ? json['data']['list'] : null);
        final arr = raw is List
            ? raw.whereType<Map>().toList()
            : (raw is Map ? <Map>[raw] : <Map>[]);
        if (arr.isEmpty) return null;
        return VideoDetail.fromVideo(
          _mapVideo(arr.first),
          m3u8List: _mapPlayList(arr.first),
        );
      }
      final videoNode = _firstElement(await _xmlDoc(url), 'video');
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
    } catch (_) {
      return null;
    }
  }

  /// 通过 json 地址导入视频源
  Future<List<Site>> importSites(String jsonUrl) async {
    try {
      final raw = await _get(jsonUrl);
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map>().map((e) => Site.fromJson(e)).toList();
      }
      if (decoded is Map && decoded['sites'] is List) {
        return (decoded['sites'] as List)
            .whereType<Map>()
            .map((e) => Site.fromJson(e))
            .toList();
      }
      return <Site>[];
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
