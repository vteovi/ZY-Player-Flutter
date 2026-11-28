import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/site.dart';
import '../models/video.dart';
import 'http_service.dart' show VideoClass;
import 'list_cache.dart';

/// 首屏快照：把「上次打开时看到的首页」存成一个小 json。
///
/// 为什么需要它：App 的数据全在 shared_preferences 里，而 `bootstrap()` 是异步的，
/// 首帧渲染时站点列表还是空的 —— 首页只能先画「暂无可用视频源」/ 骨架屏，等
/// 异步链路全部走完（读偏好 → 网络问分类 → 再读片单缓存）才长出内容。冷启动
/// 那一两秒的空白就是这么来的。
///
/// 这里在 `runApp()` **之前**把这份快照读进内存（纯本地小文件），首页第一帧就能
/// 直接画出站点名、分类栏、片单和封面；随后正常的异步链路照常跑，拿到新数据后
/// 静默替换，用户看不到等待。
///
/// **v3：片单按分类分栏存**（`pages: {tid: [...]}`），每栏各存头部 [_maxVideos] 条。
/// 之前 v2 只存「当前那一栏」一份，靠 `tid` 记归属；一旦停在「最新」栏退出，
/// 那个 tid 不在分类列表里会被兜底改写成第一个真实分类，片单却还是「最新」栏的
/// —— 下次冷启动就挂在别的标签栏下面，海报整栏错位。分栏存储从结构上消除这类
/// 错位：每一栏的片单只跟着自己的 tid 走，切到哪一栏都能立刻出图。
///
/// v2 / v1 的老文件仍能读：v2 有 `videos` 单份，归到它的 `tid`；
/// v1 连片单都没有，退回读 [ListCache]。
class BootSnapshot {
  BootSnapshot._();

  static const String _fileName = 'boot_screen.json';

  /// 每栏最多内联多少条片单：够铺满一屏多一点，文件也不会大到阻塞启动
  static const int _maxVideos = 30;

  /// 最多记住几栏（首页分类常有一二十个，全存文件会越来越胖）
  static const int _maxClasses = 8;

  /// 首页「最新」栏的 tid（与 `FilmPageState._latestClass` 保持一致）。
  ///
  /// 它不在接口返回的分类里，但完全可以被选为「上次停留的位置」，
  /// 所以校验 tid 合法性时要连带放行。
  static const String latestTid = '0';

  /// 落盘防抖：切分类会连续触发，攒一下再写
  static const Duration _flushDelay = Duration(milliseconds: 600);

  /// 上次使用的站点
  static Site? site;

  /// 上次的分类栏（**不含**「最新」，那个由首页自己补）
  static List<VideoClass> classes = const <VideoClass>[];

  /// 上次停留的分类 tid
  static String activeTid = '';

  /// 各分类的头部片单（key = tid）
  static Map<String, List<Video>> pages = const <String, List<Video>>{};

  /// 各分类的资源总数（顶部「共 N 资源」用）
  static Map<String, int> counts = const <String, int>{};

  /// 停留那一栏的片单 / 资源数（兼容老调用点）
  static List<Video> get videos => pages[activeTid] ?? const <Video>[];
  static int get recordCount => counts[activeTid] ?? 0;

  /// 取指定分类的头部片单
  static List<Video> videosOf(String tid) => pages[tid] ?? const <Video>[];

  /// 取指定分类的资源数
  static int countOf(String tid) => counts[tid] ?? 0;

  /// 快照是否可用（有站点且有分类）
  static bool get hasContent => site != null && classes.isNotEmpty;

  static File? _file;
  static String? _pending;
  static String? _lastWritten;
  static Timer? _flushTimer;
  static Future<void>? _loading;

  /// 启动时调用一次（`main()` 里 await）。任何异常都吞掉 ——
  /// 没有快照顶多是回到原来的启动路径，不能让 App 起不来。
  static Future<void> load() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_fileName');
      _file = f;
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final siteJson = decoded['site'];
      if (siteJson is! Map) return;
      final s = Site.fromJson(siteJson);
      if (s.key.isEmpty || s.api.isEmpty) return;

      final cls = <VideoClass>[];
      final rawCls = decoded['classes'];
      if (rawCls is List) {
        for (final e in rawCls) {
          if (e is! Map) continue;
          final tid = (e['tid'] ?? '').toString();
          final name = (e['name'] ?? '').toString();
          if (tid.isEmpty || name.isEmpty) continue;
          cls.add(VideoClass(tid: tid, name: name));
        }
      }
      if (cls.isEmpty) return;

      // 停留位置：合法值只有「已知分类」和「最新」栏；脏数据才退回第一栏。
      // 以前这里只要不在分类列表里就无脑改写，把「最新」栏也一起改掉了。
      final savedTid = (decoded['tid'] ?? '').toString();
      final tidOk = savedTid == latestTid || cls.any((c) => c.tid == savedTid);
      final tid = tidOk ? savedTid : cls.first.tid;

      final outPages = <String, List<Video>>{};
      final outCounts = <String, int>{};

      List<Video> parseList(Object? rawList) {
        final list = <Video>[];
        if (rawList is! List) return list;
        for (final e in rawList) {
          if (e is! Map) continue;
          try {
            list.add(Video.fromJson(e));
          } catch (_) {
            // 单条坏了就跳过，剩下的照常显示
          }
          if (list.length >= _maxVideos) break;
        }
        return list;
      }

      final rawPages = decoded['pages'];
      if (rawPages is Map) {
        // v3：分栏存储
        for (final entry in rawPages.entries) {
          final key = entry.key.toString();
          if (key.isEmpty) continue;
          final list = parseList(entry.value);
          if (list.isNotEmpty) outPages[key] = list;
        }
        final rawCounts = decoded['counts'];
        if (rawCounts is Map) {
          for (final entry in rawCounts.entries) {
            final key = entry.key.toString();
            final v = entry.value;
            if (key.isEmpty || v is! int || v <= 0) continue;
            outCounts[key] = v;
          }
        }
      } else {
        // v2 及更早：v2 只有「当前栏一份」片单，且老逻辑会把「最新」栏的 tid
        // 兜底改写成第一个真实分类 —— 那一份数据本身就可能挂错栏（正是这次
        // 串栏的来源）。宁可这版先不注入片单（走缓存兜底，首帧稍慢一点也只会
        // 慢这一次），也不要一升级就把旧站 / 别的栏的海报画出来。
        // 退出时写回的是 v3 分栏数据，之后就恢复正常。
        try {
          const budget = Duration(milliseconds: 500);
          final list =
              await ListCache.getPage(s.key, tid, 1).timeout(budget) ??
                  const <Video>[];
          if (list.isNotEmpty) outPages[tid] = list;
          final meta = await ListCache.getMeta(s.key, tid).timeout(budget);
          final n = meta?.recordcount ?? 0;
          if (n > 0) outCounts[tid] = n;
        } catch (_) {
          // 超时 / 读坏：没有片单就不注入，交给 CategoryTab 自己加载
        }
      }

      site = s;
      classes = cls;
      activeTid = tid;
      pages = outPages;
      counts = outCounts;
    } catch (_) {
      // 快照坏了就当没有
    }
  }

  /// 快照里的片单只留卡片要用的字段。
  ///
  /// 列表接口回来的 `des` / `actor` / `director` 动辄几十上百字，8 栏存下来文件
  /// 能胖到几百 KB；而首屏卡片只用 id / 片名 / 封面 / 备注 / 年份这些。
  /// 点进详情是重新按 id 请求的，不依赖这几个字段。
  static Map<String, dynamic> _packVideo(Video v) => <String, dynamic>{
        'id': v.id,
        'tid': v.tid,
        'name': v.name,
        'type': v.type,
        'pic': v.pic,
        'lang': v.lang,
        'area': v.area,
        'year': v.year,
        'note': v.note,
        'last': v.last,
      };

  /// 首页站点 / 分类 / 停留位置 / 各栏头部片单变化后调用；
  /// 内容没变则一次写盘都不做。
  ///
  /// [pages] 是「tid → 该栏头部片单」，[counts] 是「tid → 资源数」，两者都按
  /// 分类独立存，不做任何 tid 改写 —— 一旦改写，片子就会挂到别的标签栏下面。
  static void save(
    Site s,
    List<VideoClass> cls,
    String tid, {
    Map<String, List<Video>>? pages,
    Map<String, int>? counts,
  }) {
    if (s.key.isEmpty || cls.isEmpty) return;
    // 只收集「这一栏确实存在」的片单，脏 key（换源残留）不写进文件
    final known = <String>{latestTid, for (final c in cls) c.tid};
    final outPages = <String, List<dynamic>>{};
    void addPage(String key, List<Video> list) {
      if (!known.contains(key) || list.isEmpty) return;
      if (outPages.length >= _maxClasses) return;
      outPages[key] = [
        for (final v in list.take(_maxVideos)) _packVideo(v),
      ];
    }

    final srcPages = pages ?? const <String, List<Video>>{};
    // 当前停留的这一栏先放，保证它一定不会被 [_maxClasses] 上限挤掉 ——
    // 决定「打开 App 看到什么」的就是它。
    addPage(tid, srcPages[tid] ?? const <Video>[]);
    for (final entry in srcPages.entries) {
      if (entry.key == tid) continue;
      addPage(entry.key, entry.value);
    }
    final outCounts = <String, int>{};
    for (final entry in (counts ?? const <String, int>{}).entries) {
      if (!known.contains(entry.key) || entry.value <= 0) continue;
      outCounts[entry.key] = entry.value;
    }

    // ts 每次都不同，所以「是否变化」只比对去掉 ts 的那部分，
    // 否则内容没变的分类切换也会一直重写整个文件。
    final body = <String, dynamic>{
      'v': 3,
      'site': s.toJson(),
      'classes': [
        for (final c in cls)
          if (c.tid.isNotEmpty && c.name.isNotEmpty)
            <String, String>{'tid': c.tid, 'name': c.name},
      ],
      'tid': tid,
      'pages': outPages,
      'counts': outCounts,
    };
    final encoded = jsonEncode(body);
    if (encoded == _lastWritten) return;
    _lastWritten = encoded;
    body['ts'] = DateTime.now().millisecondsSinceEpoch;
    _pending = jsonEncode(body);
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () {
      unawaited(flush());
    });
  }

  /// 立即写盘（切到后台 / 退出前调用更稳）。
  static Future<void> flush() async {
    final f = _file;
    final raw = _pending;
    if (f == null || raw == null) return;
    _pending = null;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(raw, flush: true);
      // Windows 上 rename 到已存在的目标会抛异常，先删旧文件
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    } catch (_) {
      // 写失败就留着，下次 save 再试
      _pending = raw;
    }
  }
}
