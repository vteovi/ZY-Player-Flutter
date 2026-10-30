/// 视频条目。
///
/// xml 源里对应 <video> 节点，json 源里对应 list 中的 vod_* 字段，
/// 两者统一映射成本类后再交给 UI 使用。
class Video {
  final String id;
  final String tid;
  final String name;
  final String type;
  final String pic;
  final String lang;
  final String area;
  final String year;
  final String note;
  final String actor;
  final String director;
  final String des;
  final String last;

  const Video({
    this.id = '',
    this.tid = '',
    this.name = '',
    this.type = '',
    this.pic = '',
    this.lang = '',
    this.area = '',
    this.year = '',
    this.note = '',
    this.actor = '',
    this.director = '',
    this.des = '',
    this.last = '',
  });

  factory Video.fromJson(Map<dynamic, dynamic> json) {
    return Video(
      id: _s(json['id']),
      tid: _s(json['tid']),
      name: _s(json['name']),
      type: _s(json['type']),
      pic: _s(json['pic']),
      lang: _s(json['lang']),
      area: _s(json['area']),
      year: _s(json['year']),
      note: _s(json['note']),
      actor: _s(json['actor']),
      director: _s(json['director']),
      des: _s(json['des']),
      last: _s(json['last']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'tid': tid,
        'name': name,
        'type': type,
        'pic': pic,
        'lang': lang,
        'area': area,
        'year': year,
        'note': note,
        'actor': actor,
        'director': director,
        'des': des,
        'last': last,
      };

  Video copyWith({
    String? id,
    String? tid,
    String? name,
    String? type,
    String? pic,
    String? lang,
    String? area,
    String? year,
    String? note,
    String? actor,
    String? director,
    String? des,
    String? last,
  }) {
    return Video(
      id: id ?? this.id,
      tid: tid ?? this.tid,
      name: name ?? this.name,
      type: type ?? this.type,
      pic: pic ?? this.pic,
      lang: lang ?? this.lang,
      area: area ?? this.area,
      year: year ?? this.year,
      note: note ?? this.note,
      actor: actor ?? this.actor,
      director: director ?? this.director,
      des: des ?? this.des,
      last: last ?? this.last,
    );
  }

  static String _s(dynamic v) => v == null ? '' : v.toString();
}

/// 视频详情 = 视频条目 + 播放列表（m3u8List 中每一项的原始写法为「集名$地址」）
class VideoDetail extends Video {
  final List<String> m3u8List;

  const VideoDetail({
    super.id,
    super.tid,
    super.name,
    super.type,
    super.pic,
    super.lang,
    super.area,
    super.year,
    super.note,
    super.actor,
    super.director,
    super.des,
    super.last,
    this.m3u8List = const [],
  });

  factory VideoDetail.fromVideo(Video v, {List<String> m3u8List = const []}) {
    return VideoDetail(
      id: v.id,
      tid: v.tid,
      name: v.name,
      type: v.type,
      pic: v.pic,
      lang: v.lang,
      area: v.area,
      year: v.year,
      note: v.note,
      actor: v.actor,
      director: v.director,
      des: v.des,
      last: v.last,
      m3u8List: m3u8List,
    );
  }

  factory VideoDetail.fromJson(Map<dynamic, dynamic> json) {
    final list = json['m3u8List'];
    return VideoDetail.fromVideo(
      Video.fromJson(json),
      m3u8List: list is List ? list.map((e) => e.toString()).toList() : const [],
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json['m3u8List'] = m3u8List;
    return json;
  }
}

/// 一集可播放项：value 为真实播放地址，label 为「第 n 集」或影片名
class PlayItem {
  final String index;
  final String value;
  final String label;
  final String siteKey;
  final String videoId;

  const PlayItem({
    required this.index,
    required this.value,
    required this.label,
    required this.siteKey,
    required this.videoId,
  });
}

/// 收藏 / 历史记录条目：视频信息 + 播放位置
class RecordItem extends Video {
  /// `${siteKey}-${videoId}`，与 uni-app 版保持一致
  final String key;
  /// 最近一次播放的集名
  final String label;
  /// 最近一次播放的地址
  final String url;
  final double currentTime;
  final double duration;
  /// 写入/最近一次更新时间（epoch 毫秒），用于收藏/历史分栏「最新在前」倒序。
  /// 旧数据没有此字段时按 0 处理，自然排在列表末尾。
  final int ts;

  const RecordItem({
    required this.key,
    this.label = '',
    this.url = '',
    this.currentTime = 0,
    this.duration = 0,
    this.ts = 0,
    super.id,
    super.tid,
    super.name,
    super.type,
    super.pic,
    super.lang,
    super.area,
    super.year,
    super.note,
    super.actor,
    super.director,
    super.des,
    super.last,
  });

  factory RecordItem.fromJson(Map<dynamic, dynamic> json) {
    final v = Video.fromJson(json);
    return RecordItem(
      key: (json['key'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      currentTime: _d(json['currentTime']),
      duration: _d(json['duration']),
      ts: json['ts'] is int ? json['ts'] as int : int.tryParse('${json['ts']}') ?? 0,
      id: v.id,
      tid: v.tid,
      name: v.name,
      type: v.type,
      pic: v.pic,
      lang: v.lang,
      area: v.area,
      year: v.year,
      note: v.note,
      actor: v.actor,
      director: v.director,
      des: v.des,
      last: v.last,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json.addAll({
      'key': key,
      'label': label,
      'url': url,
      'currentTime': currentTime,
      'duration': duration,
      'ts': ts,
    });
    return json;
  }

  /// 解析收藏/历史的 key，返回 (siteKey, videoId)。
  ///
  /// ⚠️ 内置源的 key 是 **UUID**（形如 `210d9548-8f89-410c-8ca3-d6b69c0a513c`），
  /// 本身就带 4 个连字符，所以**不能按第一个连字符切**：
  /// `split('-')[0]` 只会切出 `210d9548` 这种不存在的站点，详情页随即报
  /// 「获取详情失败」。这里按**最后一个**连字符切（videoId 是数字，不含连字符）。
  /// 更精确的拆法见 `AppState.resolveRecordKey()`。
  static List<String> splitKey(String key) {
    final idx = key.lastIndexOf('-');
    if (idx <= 0) return [key, ''];
    return [key.substring(0, idx), key.substring(idx + 1)];
  }

  RecordItem copyWithRecord({
    String? label,
    String? url,
    double? currentTime,
    double? duration,
    int? ts,
  }) {
    return RecordItem(
      key: key,
      label: label ?? this.label,
      url: url ?? this.url,
      currentTime: currentTime ?? this.currentTime,
      duration: duration ?? this.duration,
      ts: ts ?? this.ts,
      id: id,
      tid: tid,
      name: name,
      type: type,
      pic: pic,
      lang: lang,
      area: area,
      year: year,
      note: note,
      actor: actor,
      director: director,
      des: des,
      last: last,
    );
  }

  /// 播放进度百分比（0 ~ 100）
  int get progress {
    if (currentTime <= 0 || duration <= 0) return 0;
    final p = (100 * currentTime / duration).round();
    return p.clamp(0, 100);
  }

  static double _d(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }
}

/// 软件配置（对应 setting 库里 key = config 的记录）
class AppConfig {
  final int id;
  final String key;

  /// 播放页画面比例，见 `utils/player_options.dart` 的 PlayerAspects
  final String playerAspect;

  /// 播放页画面大小 / 填充方式，见 PlayerScales
  final String playerScale;

  /// 手动纠正画面方向：交换宽高。
  /// 少数视频源上报的分辨率方向与实际画面不符（竖屏视频被当成横屏），
  /// 打开这个开关就把显示比例的宽高对调，用户改过之后会一直被记住。
  final bool playerFlip;

  /// 全屏播放时在右上角显示实时下载速度
  final bool showSpeed;

  /// 强制使用软件解码器播放（仅 Android 生效）。
  /// 部分机型的硬件解码器在 H.264 High Profile/1080p 上会抛
  /// `MediaCodecVideoRenderer error`，开启后始终走软件解码器（如
  /// c2.android.avc.decoder），兼容性最好，代价是略耗电。默认关闭。
  final bool forceSoftwareDecode;

  /// 全屏播放时长按画面加速的倍率（2.0 / 4.0 / 8.0），默认 2.0。
  /// 长按期间把播放速度提到该倍率，松手恢复到 1.0。
  final double playerLongPressRate;

  /// 显示模式：'system' 跟随系统 / 'light' 浅色 / 'dark' 深色，默认跟随系统。
  final String themeMode;

  /// 首页卡片横向模式：开启后海报横向（左图右文），
  /// 手机竖屏每行一个，平板大屏自适应多列；关闭为竖向海报（默认）。
  final bool landscapeCard;

  /// 自定义播放器的可执行文件路径（Windows 专属）。
  /// 设置后，「外部播放」会直接启动该 exe 并带上播放地址，
  /// 而不是自动查找已安装的播放器（PotPlayer / VLC 等）。为空表示未设置。
  final String externalPlayerPath;

  /// 版本更新清单地址（`update.json`）。
  /// 为空时用内置默认地址（`UpdateService.defaultManifestUrl`）。
  /// 直连 GitHub raw 不通时，可改成自己的服务器或 Gitee raw 地址。
  final String updateUrl;

  const AppConfig({
    this.id = 0,
    this.key = 'config',
    this.playerAspect = 'auto',
    this.playerScale = 'fit',
    this.playerFlip = false,
    this.showSpeed = false,
    this.forceSoftwareDecode = false,
    this.playerLongPressRate = 2.0,
    this.themeMode = 'system',
    this.landscapeCard = false,
    this.externalPlayerPath = '',
    this.updateUrl = '',
  });

  factory AppConfig.fromJson(Map<dynamic, dynamic> json) {
    final mode = (json['themeMode'] ?? 'system').toString();
    return AppConfig(
      id: json['id'] is int ? json['id'] as int : int.tryParse('${json['id']}') ?? 0,
      key: (json['key'] ?? 'config').toString(),
      playerAspect: (json['playerAspect'] ?? 'auto').toString(),
      playerScale: (json['playerScale'] ?? 'fit').toString(),
      playerFlip: json['playerFlip'] == true || json['playerFlip'].toString() == 'true',
      showSpeed: json['showSpeed'] == true || json['showSpeed'].toString() == 'true',
      forceSoftwareDecode: json['forceSoftwareDecode'] == true ||
          json['forceSoftwareDecode'].toString() == 'true',
      playerLongPressRate: () {
        final rate = json['playerLongPressRate'];
        if (rate == null) return 2.0;
        return rate is num ? rate.toDouble() : double.tryParse('$rate') ?? 2.0;
      }(),
      themeMode: mode == 'light' || mode == 'dark' ? mode : 'system',
      landscapeCard:
          json['landscapeCard'] == true || json['landscapeCard'].toString() == 'true',
      externalPlayerPath: (json['externalPlayerPath'] ?? '').toString(),
      updateUrl: (json['updateUrl'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'playerAspect': playerAspect,
        'playerScale': playerScale,
        'playerFlip': playerFlip,
        'showSpeed': showSpeed,
        'forceSoftwareDecode': forceSoftwareDecode,
        'playerLongPressRate': playerLongPressRate,
        'themeMode': themeMode,
        'landscapeCard': landscapeCard,
        'externalPlayerPath': externalPlayerPath,
        'updateUrl': updateUrl,
      };

  AppConfig copyWith({
    String? playerAspect,
    String? playerScale,
    bool? playerFlip,
    bool? showSpeed,
    bool? forceSoftwareDecode,
    double? playerLongPressRate,
    String? themeMode,
    bool? landscapeCard,
    String? externalPlayerPath,
    String? updateUrl,
  }) =>
      AppConfig(
        id: id,
        key: key,
        playerAspect: playerAspect ?? this.playerAspect,
        playerScale: playerScale ?? this.playerScale,
        playerFlip: playerFlip ?? this.playerFlip,
        showSpeed: showSpeed ?? this.showSpeed,
        forceSoftwareDecode: forceSoftwareDecode ?? this.forceSoftwareDecode,
        playerLongPressRate: playerLongPressRate ?? this.playerLongPressRate,
        themeMode: themeMode ?? this.themeMode,
        landscapeCard: landscapeCard ?? this.landscapeCard,
        externalPlayerPath: externalPlayerPath ?? this.externalPlayerPath,
        updateUrl: updateUrl ?? this.updateUrl,
      );
}
