/// 视频源（对应 utils/initSite.json 中的每一条数据）
class Site {
  final int id;

  /// 数据库主键，同时是收藏/历史记录拼接用的标识
  final String key;
  final String name;

  /// 采集站接口地址
  final String api;

  /// 接口返回类型：json（maccms json 接口）或 xml
  final String type;

  /// 播放解析接口（可为空）。
  ///
  /// 有一部分采集站返回的播放地址**不是直链**，而是腾讯 / 爱奇艺 / 优酷这类
  /// 平台的**网页地址**，必须再经过一个「解析接口」换出真正的 m3u8 / mp4 才能播。
  /// 这里存的就是那个前缀，形如 `https://jx.example.com/?url=`，使用时直接接在
  /// 播放地址前面（对齐 TVBox 的 parse 用法）。空串 = 这个源不需要解析，
  /// 或者用户还没填 —— 两种情况都按「直接播原地址」处理。
  final String parseApi;

  final String download;
  final String group;

  /// 是否启用，未启用的源不在首页站点列表里出现
  final bool isActive;
  final String status;

  const Site({
    required this.id,
    required this.key,
    required this.name,
    required this.api,
    required this.type,
    this.parseApi = '',
    this.download = '',
    this.group = '默认',
    this.isActive = true,
    this.status = '可用',
  });

  /// 是否配了解析接口
  bool get hasParse => parseApi.trim().isNotEmpty;

  /// 是否为 json 接口（zx / zyfun 导出的源大多是 maccms 的 json 接口）
  bool get isJson => type == 'json';

  Site copyWith({
    int? id,
    String? key,
    String? name,
    String? api,
    String? type,
    String? parseApi,
    String? download,
    String? group,
    bool? isActive,
    String? status,
  }) {
    return Site(
      id: id ?? this.id,
      key: key ?? this.key,
      name: name ?? this.name,
      api: api ?? this.api,
      type: type ?? this.type,
      parseApi: parseApi ?? this.parseApi,
      download: download ?? this.download,
      group: group ?? this.group,
      isActive: isActive ?? this.isActive,
      status: status ?? this.status,
    );
  }

  factory Site.fromJson(Map<dynamic, dynamic> json) {
    return Site(
      id: _toInt(json['id']),
      key: (json['key'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      api: (json['api'] ?? '').toString(),
      type: (json['type'] ?? 'xml').toString(),
      // 兼容几种常见写法：本应用自己写的是 parseApi，TVBox 系配置里可能叫
      // parse_url / parseUrl，以前从别的播放器导出的还见过 parse。
      parseApi: _firstStr(json, const [
        'parseApi',
        'parse_url',
        'parseUrl',
        'parse',
      ]),
      download: (json['download'] ?? '').toString(),
      group: (json['group'] ?? '默认').toString(),
      isActive: _toBool(json['isActive']),
      status: (json['status'] ?? '可用').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'key': key,
      'name': name,
      'api': api,
      'type': type,
      'parseApi': parseApi,
      'download': download,
      'group': group,
      'isActive': isActive,
      'status': status,
    };
  }

  static String _firstStr(Map<dynamic, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _toBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    return v.toString() == 'true';
  }
}
