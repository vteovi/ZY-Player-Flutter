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
/// 这里在 `runApp()` **之前**把这份快照读进内存（纯本地小文件 + 一次
/// shared_preferences 内存读取），首页第一帧就能直接画出站点名、分类栏、片单和
/// 封面；随后正常的异步链路照常跑，拿到新数据后静默替换，用户看不到等待。
///
/// 只存「结构」（站点 + 分类 + 上次停留的分类），片单仍然从 [ListCache] 读 ——
/// 同一份数据只存一处，不会出现两份内容打架。
class BootSnapshot {
  BootSnapshot._();

  static const String _fileName = 'boot_screen.json';

  /// 落盘防抖：切分类会连续触发，攒一下再写
  static const Duration _flushDelay = Duration(milliseconds: 600);

  /// 上次使用的站点
  static Site? site;

  /// 上次的分类栏（**不含**「最新」，那个由首页自己补）
  static List<VideoClass> classes = const <VideoClass>[];

  /// 上次停留的分类 tid
  static String activeTid = '';

  /// [activeTid] 的第一页片单，来自 [ListCache]
  static List<Video> videos = const <Video>[];

  /// [activeTid] 的资源总数（顶部「共 N 资源」用）
  static int recordCount = 0;

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

      final savedTid = (decoded['tid'] ?? '').toString();
      final tid = cls.any((c) => c.tid == savedTid) ? savedTid : cls.first.tid;

      // 片单与资源数从 ListCache 取（和首页正常路径同一份数据）。
      // 读失败只当没有片单：分类栏照样能先画出来。
      //
      // 加超时是因为这一步会触发 shared_preferences 首次初始化（整份偏好一次
      // 读进内存），收藏 / 历史特别多时可能要几百毫秒 —— 宁可先只给结构，
      // 也不能把首帧一直卡在这儿。
      List<Video> firstPage = const <Video>[];
      var count = 0;
      try {
        const budget = Duration(milliseconds: 500);
        firstPage =
            await ListCache.getPage(s.key, tid, 1).timeout(budget) ??
                const <Video>[];
        final meta = await ListCache.getMeta(s.key, tid).timeout(budget);
        count = meta?.recordcount ?? 0;
      } catch (_) {
        // 超时 / 读坏：没有片单就不注入，交给 CategoryTab 自己加载
      }

      site = s;
      classes = cls;
      activeTid = tid;
      videos = firstPage;
      recordCount = count;
    } catch (_) {
      // 快照坏了就当没有
    }
  }

  /// 首页站点 / 分类 / 停留位置变化后调用；内容没变则一次写盘都不做。
  static void save(Site s, List<VideoClass> cls, String tid) {
    if (s.key.isEmpty || cls.isEmpty) return;
    final tidOk = cls.any((c) => c.tid == tid) ? tid : cls.first.tid;
    // ts 每次都不同，所以「是否变化」只比对去掉 ts 的那部分，
    // 否则内容没变的分类切换也会一直重写整个文件。
    final body = <String, dynamic>{
      'v': 1,
      'site': s.toJson(),
      'classes': [
        for (final c in cls)
          if (c.tid.isNotEmpty && c.name.isNotEmpty)
            <String, String>{'tid': c.tid, 'name': c.name},
      ],
      'tid': tidOk,
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
