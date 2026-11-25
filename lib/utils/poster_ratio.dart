import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 海报「宽 / 高」比例缓存，供瀑布流布局使用。
///
/// 采集站接口只给图片 URL，不给尺寸；而瀑布流要让每张卡按海报**真实比例**
/// 占位（不裁切），就必须先知道比例。三条获取途径，按成本从低到高：
///
/// 1. 内存命中 —— 本次运行已经量过；
/// 2. 落盘索引命中 —— 上次运行量过（`poster_ratio.json`）；
/// 3. 读图片文件头 —— 只读前 64KB 解析宽高，**不解码像素**，微秒级。
///
/// 第 3 步的数据来源是本地已经存在的封面文件（[CoverCache] 索引 + 后台预取
/// 落盘），所以整个过程零额外网络请求、零额外解码，不会和「封面秒开」抢资源。
///
/// 比例变化通过 [revision] 广播：瀑布流网格监听它，图片量出真实比例后重排一次。
class PosterRatio {
  PosterRatio._();

  /// 常见竖版海报比例（2:3）。量不出来时先用它占位，量到后自动修正。
  static const double fallback = 2 / 3;

  /// 最多记多少条，与 [CoverCache] 的 2000 条对齐。
  static const int _maxEntries = 2000;

  static const String _fileName = 'poster_ratio.json';

  /// 只读文件头这么多字节：JPEG 的 SOF 段一般在最前面，64KB 足够覆盖
  /// 带大 EXIF 的图。
  static const int _headBytes = 64 * 1024;

  /// 落盘防抖：一屏几十张卡会连续 remember，攒够再写一次。
  static const Duration _flushDelay = Duration(milliseconds: 900);

  /// 重排通知的节流间隔：比例是成批量出来的，逐条 setState 会让列表抖个不停。
  static const Duration _notifyDelay = Duration(milliseconds: 220);

  static final Map<String, double> _ratios = <String, double>{};

  static final Set<String> _measuring = <String>{};

  /// 正在「探测网络图比例」的 URL。
  ///
  /// 与 [_measuring] 分开：那个是「读文件头」的短任务，这个是等图片解码完成
  /// 的回调，两者可能同时发生在同一个 URL 上。
  static final Set<String> _probing = <String>{};

  static File? _file;
  static bool _dirty = false;
  static Timer? _flushTimer;
  static Timer? _notifyTimer;
  static Future<void>? _loading;

  /// 比例版本号：每批量出新的比例就 +1。
  ///
  /// 瀑布流网格把它接进 setState，从而在图片量出真实比例后重排一次。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 启动时调用一次（`main()` 里 await），把上次落盘的比例读进内存。
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
        if (k is! String || k.isEmpty) return;
        final r = v is num ? v.toDouble() : double.tryParse('$v');
        if (r != null && r.isFinite && r > 0.2 && r < 5) {
          _ratios[k] = r;
        }
      });
    } catch (_) {
      // 索引坏了当没有，退回默认比例
    }
  }

  /// 同步取已知比例；没量过返回 null。
  static double? of(String url) {
    if (url.isEmpty) return null;
    return _ratios[url];
  }

  /// 已有比例就直接用，没有就返回默认值（布局先按默认排，量到后重排）。
  static double ofOrFallback(String url) => of(url) ?? fallback;

  /// 记录一个已知比例（宽 / 高）。
  static void remember(String url, double ratio) {
    if (url.isEmpty || !ratio.isFinite || ratio <= 0.2 || ratio >= 5) return;
    final old = _ratios[url];
    if (old != null && (old - ratio).abs() < 0.0005) return;
    // 先删再插，让它排到末尾，_trim 优先淘汰真正最久没碰的
    _ratios.remove(url);
    _ratios[url] = ratio;
    _trim();
    _markDirty();
    _scheduleNotify();
  }

  /// 读本地封面文件的头信息拿比例，成功后记进缓存。
  ///
  /// 同一 URL 若已在测量中则直接返回，避免一屏里重复读同一个文件。
  static Future<void> measureFromFile(String url, String path) async {    if (url.isEmpty || path.isEmpty) return;
    if (_ratios.containsKey(url)) return;
    if (!_measuring.add(url)) return;
    try {
      final ratio = await _readRatio(path);
      if (ratio != null) remember(url, ratio);
    } finally {
      _measuring.remove(url);
    }
  }

  /// 开始一次「网络图比例探测」，返回 false 表示该 URL 已有比例或正在探测。
  ///
  /// 用于本地还没有封面文件、只能等图片解码完才能知道尺寸的场景
  /// （搜索页、收藏页、历史页 —— 它们不走后台预取）。
  static bool beginProbe(String url) {
    if (url.isEmpty) return false;
    if (_ratios.containsKey(url)) return false;
    return _probing.add(url);
  }

  /// 探测结束（成功或失败都要调），失败后下次还能再试。
  static void endProbe(String url) {
    _probing.remove(url);
  }

  /// 解析图片文件头，返回「宽 / 高」。拿不到返回 null。
  static Future<double?> _readRatio(String path) async {
    RandomAccessFile? raf;
    try {
      final f = File(path);
      raf = await f.open();
      final size = await raf.length();
      if (size <= 0) return null;
      final head = await raf.read(math.min(size, _headBytes));
      final wh = _parseHeader(head);
      if (wh == null) return null;
      final w = wh.$1;
      final h = wh.$2;
      if (w <= 0 || h <= 0) return null;
      return w / h;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 按文件头魔数分派解析，返回 (宽, 高)。
  ///
  /// 只覆盖封面图实际会用到的格式：JPEG（绝大多数采集站）、PNG、WebP、GIF。
  /// 其他格式返回 null，让调用方退回默认比例。
  static (int, int)? _parseHeader(Uint8List b) {
    if (b.length < 16) return null;
    // JPEG：FF D8
    if (b[0] == 0xFF && b[1] == 0xD8) return _parseJpeg(b);
    // PNG：89 50 4E 47 0D 0A 1A 0A
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return _u32be(b, 16) > 0 && _u32be(b, 20) > 0
          ? (_u32be(b, 16), _u32be(b, 20))
          : null;
    }
    // GIF：47 49 46 38
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
      final w = b[6] | (b[7] << 8);
      final h = b[8] | (b[9] << 8);
      return w > 0 && h > 0 ? (w, h) : null;
    }
    // WebP：52 49 46 46 ... 57 45 42 50
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return _parseWebp(b);
    }
    return null;
  }

  /// 遍历 JPEG 的段标记，找到 SOF（帧头）读宽高。
  static (int, int)? _parseJpeg(Uint8List b) {
    var i = 2;
    final n = b.length;
    while (i + 9 < n) {
      // 段以 0xFF 开头，允许连续填充字节
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      // 0xD8/0xD9 无长度；0x01 与 0xD0~0xD7 也无长度
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
        i += 2;
        continue;
      }
      final segLen = (b[i + 2] << 8) | b[i + 3];
      if (segLen < 2) return null;
      // SOF0~SOF15，排除 DHT(C4) / JPG(C8) / DAC(CC)
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (i + 9 >= n) return null;
        final h = (b[i + 5] << 8) | b[i + 6];
        final w = (b[i + 7] << 8) | b[i + 8];
        return w > 0 && h > 0 ? (w, h) : null;
      }
      i += 2 + segLen;
    }
    return null;
  }

  /// WebP 三种子格式：VP8X（扩展，带 24 位宽高）、VP8（有损）、VP8L（无损）。
  static (int, int)? _parseWebp(Uint8List b) {
    if (b.length < 30) return null;
    var i = 12; // 跳过 RIFF 头
    while (i + 8 < b.length) {
      final tag0 = b[i];
      final tag1 = b[i + 1];
      final tag2 = b[i + 2];
      final tag3 = b[i + 3];
      final chunkSize = _u32le(b, i + 4);
      if (tag0 == 0x56 && tag1 == 0x50 && tag2 == 0x38) {
        // "VP8 "
        if (tag3 == 0x20 && i + 30 <= b.length) {
          // 帧头后是 3 字节起始码 9D 01 2A，再是 14 位宽、14 位高
          final p = i + 8 + 3;
          if (p + 4 > b.length) return null;
          final w = ((b[p + 1] << 8) | b[p]) & 0x3FFF;
          final h = ((b[p + 3] << 8) | b[p + 2]) & 0x3FFF;
          return w > 0 && h > 0 ? (w, h) : null;
        }
        // "VP8L"
        if (tag3 == 0x4C && i + 25 <= b.length) {
          final p = i + 8 + 1; // 跳过 0x2F 签名
          if (p + 4 > b.length) return null;
          final bits = b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24);
          final w = (bits & 0x3FFF) + 1;
          final h = ((bits >> 14) & 0x3FFF) + 1;
          return (w, h);
        }
        // "VP8X"
        if (tag3 == 0x58 && i + 30 <= b.length) {
          final w = 1 + (b[i + 12] | (b[i + 13] << 8) | (b[i + 14] << 16));
          final h = 1 + (b[i + 15] | (b[i + 16] << 8) | (b[i + 17] << 16));
          return w > 0 && h > 0 ? (w, h) : null;
        }
      }
      i += 8 + chunkSize + (chunkSize & 1); // chunk 长度为奇数时补 1 字节对齐
    }
    return null;
  }

  static int _u32be(Uint8List b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  static int _u32le(Uint8List b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

  static void _trim() {
    while (_ratios.length > _maxEntries) {
      _ratios.remove(_ratios.keys.first);
    }
  }

  static void _markDirty() {
    _dirty = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () {
      unawaited(flush());
    });
  }

  /// 合并通知：一屏图片量完可能连着来几十条，攒一小会儿只重排一次。
  static void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(_notifyDelay, () {
      revision.value++;
    });
  }

  /// 立即把比例索引写盘（App 退到后台 / 退出前调用更稳妥）。
  static Future<void> flush() async {
    if (!_dirty) return;
    final f = _file;
    if (f == null) return;
    _dirty = false;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(_ratios), flush: true);
      // Windows 上 rename 到已存在的目标会抛异常，先删旧文件
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    } catch (_) {
      _dirty = true;
    }
  }
}
