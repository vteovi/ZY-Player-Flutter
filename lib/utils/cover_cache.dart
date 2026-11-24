import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 封面「URL → 本地缓存文件」索引，让封面在冷启动第一帧就能画出来。
///
/// 为什么需要它：`cached_network_image` 只是把图片**文件**放在磁盘上，要拿到
/// 那个文件仍然得异步查一次 sqflite、再异步读文件 —— 冷启动时每张卡片都会先
/// 转一会儿圈、等这一串异步走完才换成海报。片名和网格本身是同步缓存的，于是
/// 观感就成了「文字早出来了，图还要加载一会儿」。
///
/// 这里把 CacheManager 落盘后的真实路径提前记成一份 json（url → path）：启动时
/// 只读这一小份索引，[pathOf] 同步返回文件路径，卡片直接用 `Image.file` 画。
/// 文件若被系统清理或被 LRU 淘汰，[pathOf] 会 stat 失败并返回 null，调用方回退
/// 到网络加载 —— 索引只可能多命中一次，不会把图指丢。
///
/// 与 [AppImageCache] 的分工：那个管「文件存在哪、留多久」，这个只管「路径是多少」。
class CoverCache {
  CoverCache._();

  /// 最多记多少条，与 `AppImageCache` 的 `maxNrOfCacheObjects` 对齐，
  /// 避免索引里堆着早就被淘汰的路径。
  static const int _maxEntries = 2000;

  static const String _fileName = 'cover_index.json';

  /// 落盘用的防抖：一屏几十张封面会连续 remember，攒够再写一次
  static const Duration _flushDelay = Duration(milliseconds: 800);

  static final Map<String, String> _index = <String, String>{};

  /// 已经确认「文件存在」的 URL。
  ///
  /// [pathOf] 会在每次 build 里被调用（滚动一屏就是几十次），不能每次都 stat；
  /// 首次确认存在后记在这里，后续直接返回路径。文件在运行期被删是极小概率，
  /// 真删了 `Image.file` 的 errorBuilder 还会兜住并调用 [forget]。
  static final Set<String> _present = <String>{};

  /// 已经确认「文件不在」的 URL：避免每帧都对同一个坏路径 stat 一次
  static final Set<String> _missing = <String>{};

  static File? _file;
  static bool _dirty = false;
  static Timer? _flushTimer;
  static Future<void>? _loading;

  /// 启动时调用一次（`main()` 里 await）：把上次落盘的索引读进内存。
  ///
  /// 索引只是一个 txt 大小的 json，读它比逐张封面查 sqflite 便宜得多；
  /// 任何异常都吞掉 —— 没有索引顶多是回到原来的加载方式，不能让 App 起不来。
  static Future<void> load() {
    return _loading ??= _doLoad();
  }

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
      decoded.forEach((k, v) {
        if (k is String && v is String && k.isNotEmpty && v.isNotEmpty) {
          _index[k] = v;
        }
      });
    } catch (_) {
      // 索引坏了就当没有
    }
  }

  /// 同步取本地文件路径；没有、或文件已经不在了就返回 null（调用方走网络）。
  ///
  /// 这里刻意用 `existsSync`：一屏二三十张卡片也就二三十次 stat，是微秒级的；
  /// 换成异步反而又回到「先转圈再出图」，正是本次要解决的问题。
  static String? pathOf(String url) {
    if (url.isEmpty) return null;
    if (_present.contains(url)) return _index[url];
    if (_missing.contains(url)) return null;
    final path = _index[url];
    if (path == null) return null;
    try {
      if (File(path).existsSync()) {
        _present.add(url);
        return path;
      }
    } catch (_) {
      // 落到下面统一当「文件不在」处理
    }
    // 文件被系统清理 / 被 CacheManager 淘汰：丢掉这条，别每帧再 stat 一次
    _missing.add(url);
    _index.remove(url);
    _markDirty();
    return null;
  }

  /// 记录一次真实落盘的路径（由预取拿到 File 后调用）。
  static void remember(String url, String path) {
    if (url.isEmpty || path.isEmpty) return;
    if (_index[url] == path) {
      // 路径没变（多半是预取第二次碰到同一张图），只需保证它被认定为可用
      _missing.remove(url);
      _present.add(url);
      return;
    }
    _missing.remove(url);
    // 先删再插，让它排到 Map 末尾，_trim 淘汰时优先丢真正最久没碰的
    _index.remove(url);
    _index[url] = path;
    _present.add(url);
    _trim();
    _markDirty();
  }

  /// 该 URL 的缓存不可用（文件损坏等）：先忘掉，下次会重新下载。
  static void forget(String url) {
    _present.remove(url);
    if (_index.remove(url) == null) return;
    _missing.add(url);
    _markDirty();
  }

  static void _trim() {
    while (_index.length > _maxEntries) {
      final oldest = _index.keys.first;
      _index.remove(oldest);
      // 淘汰掉的条目不能再留在「已确认存在」里，否则 pathOf 会返回 null 却永远
      // 跳不过 _present 的快速通道
      _present.remove(oldest);
    }
  }

  static void _markDirty() {
    _dirty = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () {
      unawaited(flush());
    });
  }

  /// 立即把索引写盘（App 退到后台 / 退出前调用更稳妥）。
  static Future<void> flush() async {
    if (!_dirty) return;
    final f = _file;
    if (f == null) return;
    _dirty = false;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_index), flush: true);
      // Windows 上 rename 到已存在的目标会抛异常，先删掉旧文件
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    } catch (_) {
      // 写失败就等下一次 remember 再试
      _dirty = true;
    }
  }
}
