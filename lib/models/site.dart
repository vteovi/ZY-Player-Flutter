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
    this.download = '',
    this.group = '默认',
    this.isActive = true,
    this.status = '可用',
  });

  /// 是否为 json 接口（zx / zyfun 导出的源大多是 maccms 的 json 接口）
  bool get isJson => type == 'json';

  Site copyWith({
    int? id,
    String? key,
    String? name,
    String? api,
    String? type,
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
      type: _typeString(json['type']),
      download: (json['download'] ?? '').toString(),
      group: (json['group'] ?? '默认').toString(),
      isActive: _toBool(json['isActive']),
      status: (json['status'] ?? '可用').toString(),
    );
  }

  /// 接口类型归一化：兼容 TVBox 的数字 type（0 = xml，1 = json）
  static String _typeString(dynamic v) {
    if (v is num) return v == 1 ? 'json' : 'xml';
    final s = v?.toString() ?? '';
    if (s == '0') return 'xml';
    if (s == '1') return 'json';
    return s.isEmpty ? 'xml' : s;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'key': key,
      'name': name,
      'api': api,
      'type': type,
      'download': download,
      'group': group,
      'isActive': isActive,
      'status': status,
    };
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
