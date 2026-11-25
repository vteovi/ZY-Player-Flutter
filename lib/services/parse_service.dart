import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 解析失败时抛出，[reason] 是**可直接展示给用户**的中文原因。
class ParseException implements Exception {
  final String reason;

  const ParseException(this.reason);

  @override
  String toString() => reason;
}

/// 播放地址解析：把「网页地址」换成「能直接播的直链」。
///
/// ## 为什么需要
///
/// maccms 采集站返回的 `play_url` 有两种截然不同的东西：
/// - 大部分是**直链**（`.m3u8` / `.mp4`），播放器拿到就能播；
/// - 少部分是**第三方平台的网页地址**（`https://v.qq.com/x/cover/xxx.html`），
///   直接丢给播放器只会得到一句看不懂的解码错误。这类站需要配一个
///   「解析接口」——把网页地址拼在接口后面请求一次，由它换出真正的视频流。
///
/// ## 拼接方式
///
/// 按 TVBox 的习惯**直接字符串拼接**，不做 URL 编码：
/// `https://jx.example.com/?url=https://v.qq.com/x/cover/xxx.html`。
/// 绝大多数解析接口都能处理未编码的地址，反而有站不认编码后的（把 `%3A%2F%2F`
/// 原样当参数值）；而 maccms 给的网页地址通常不带查询串，不存在 `&` 被截断的问题。
/// 想在任意位置插入地址时，可在接口里写 `{url}` 占位符。
///
/// ## 结果识别
///
/// 解析接口的返回五花八门，这里按「最可能→最不可能」依次识别：
/// 1. 302 跳转（`Location` 直接是 m3u8 时立刻返回，否则跟着再请求一次）；
/// 2. JSON（`{"url": "..."}`、`{"data": {"url": ...}}`、`{"play_url": ...}` 等）；
/// 3. 正文本身就是 m3u8 索引（`#EXTM3U` 开头）；
/// 4. HTML 里能抠出第一个 m3u8 / mp4 链接。
class ParseService {
  ParseService._();

  static final ParseService instance = ParseService._();

  /// 单次请求（含建立连接）的超时
  static const Duration _hopTimeout = Duration(seconds: 8);

  /// 整次解析（含所有跳转）的总超时 —— 解析接口卡住时不能让用户干等
  static const Duration _totalTimeout = Duration(seconds: 18);

  /// 最多跟几跳重定向
  static const int _maxHops = 5;

  /// 响应正文最多读这么多字节 —— 解析接口正常只回几百字节的 JSON，
  /// 回一整个网页时才需要多读一点抠链接，再大就没意义了
  static const int _maxBodyBytes = 256 * 1024;

  /// 解析站大多是网页服务，按 UA 分流的不少，带浏览器 UA 最稳
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 认作「已经是直链、不需要解析」的扩展名
  static const List<String> _mediaExts = <String>[
    '.m3u8',
    '.mp4',
    '.flv',
    '.mkv',
    '.ts',
    '.mpd',
    '.mov',
    '.webm',
    '.avi',
    '.wmv',
    '.m4v',
    '.mp3',
    '.m4a',
    '.aac',
  ];

  /// 从 HTML / 转义文本里抠视频链接
  static final RegExp _linkRe = RegExp(
    r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|flv|mkv)(?:\?[^\s"'<>\\]*)?''',
    caseSensitive: false,
  );

  /// 这个地址需不需要走解析接口。
  ///
  /// 只在这两条同时成立时为 true：配了解析接口、且地址看起来不是直链。
  /// 直链一律跳过 —— 拿 m3u8 去过解析接口只会把能播的弄成不能播。
  static bool shouldParse(String rawUrl, String parseApi) {
    if (parseApi.trim().isEmpty) return false;
    return !isDirectMedia(rawUrl);
  }

  /// 地址是否已经是能直接交给播放器的直链。
  ///
  /// 非 http(s) 协议（`rtmp` / `magnet` / `ed2k` 等）也按直链处理：
  /// 它们有各自的播放方式，解析接口只处理网页地址。
  static bool isDirectMedia(String rawUrl) {
    final raw = rawUrl.trim();
    // 空地址无从解析：当成「不需要解析」，让播放器自己去报错，
    // 而不是拿一个空参数去请求解析接口（会得到一个更难懂的错误）
    if (raw.isEmpty) return true;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      // 认不出域名时别乱套解析接口，按原样交给播放器
      return true;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return true;
    final path = uri.path.toLowerCase();
    for (final ext in _mediaExts) {
      if (path.endsWith(ext)) return true;
    }
    return false;
  }

  /// 把解析接口和播放地址拼成要请求的地址。
  static String buildUrl(String parseApi, String rawUrl) {
    final api = parseApi.trim();
    final url = rawUrl.trim();
    if (api.contains('{url}')) return api.replaceAll('{url}', url);
    return '$api$url';
  }

  /// 解析出一条可播放地址。
  ///
  /// 地址本身是直链、或没配解析接口时**原样返回**（调用方不必先判断）。
  /// 解析不出来时抛 [ParseException]，原因可直接展示。
  Future<String> resolve({
    required String parseApi,
    required String rawUrl,
  }) async {
    if (!shouldParse(rawUrl, parseApi)) return rawUrl;
    try {
      return await _resolveInner(parseApi, rawUrl).timeout(
        _totalTimeout,
        onTimeout: () => throw const ParseException('解析接口响应超时，换一个接口试试'),
      );
    } on ParseException {
      rethrow;
    } on SocketException catch (e) {
      throw ParseException('连不上解析接口：${_short(e.message)}');
    } on HandshakeException {
      throw const ParseException('解析接口的 https 证书有问题');
    } on TimeoutException {
      throw const ParseException('解析接口响应超时，换一个接口试试');
    } on FormatException {
      throw const ParseException('解析接口返回的地址格式不对');
    } catch (e) {
      throw ParseException('解析失败：${_short(e.toString())}');
    }
  }

  Future<String> _resolveInner(String parseApi, String rawUrl) async {
    final client = HttpClient()..connectionTimeout = _hopTimeout;
    try {
      var current = buildUrl(parseApi, rawUrl);
      for (var hop = 0; hop <= _maxHops; hop++) {
        final req = await client
            .getUrl(Uri.parse(current))
            .timeout(_hopTimeout);
        // 自己跟跳转：要拿到最终地址，以及「跳到 m3u8 就到此为止」的判断权
        req.followRedirects = false;
        req.headers.set(HttpHeaders.userAgentHeader, _ua);
        req.headers.set(HttpHeaders.acceptHeader, '*/*');
        final res = await req.close().timeout(_hopTimeout);
        final code = res.statusCode;

        if (code >= 300 && code < 400) {
          final location = res.headers.value(HttpHeaders.locationHeader);
          await res.drain<void>();
          if (location == null || location.trim().isEmpty) {
            throw const ParseException('解析接口返回了跳转，却没给目标地址');
          }
          current = Uri.parse(current).resolve(location.trim()).toString();
          if (isDirectMedia(current)) return current;
          continue;
        }

        if (code < 200 || code >= 300) {
          await res.drain<void>();
          throw ParseException(
            code == 403 || code == 401
                ? '解析接口拒绝了请求（HTTP $code），可能要 Referer 或已失效'
                : '解析接口返回 HTTP $code',
          );
        }

        final body = await _readBody(res);
        final found = _extract(body, current);
        if (found != null) return found;
        throw const ParseException('解析接口没给出播放地址（不是直链、也没返回 url）');
      }
      throw const ParseException('解析接口跳转次数太多，可能配错了地址');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _readBody(HttpClientResponse res) async {
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
      if (bytes.length >= _maxBodyBytes) break;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 从响应正文里找出播放地址；认不出返回 null。
  String? _extract(String body, String currentUrl) {
    final text = body.trim();
    if (text.isEmpty) return null;

    // ① 正文就是 m3u8 索引：说明 currentUrl 本身就是流地址
    if (text.startsWith('#EXTM3U')) return currentUrl;

    // ② JSON：解析接口最常见的形式
    if (text.startsWith('{') || text.startsWith('[')) {
      final fromJson = _fromJson(text);
      if (fromJson != null) return fromJson;
    }

    // ③ 网页里抠链接。先还原 JSON / JS 里常见的 `\/` 转义，否则整串都被
    //    「反斜杠」卡住匹配不到。
    final plain = body.replaceAll(r'\/', '/');
    final m = _linkRe.firstMatch(plain);
    if (m != null) {
      return _trimUrl(m.group(0)!);
    }
    return null;
  }

  String? _fromJson(String text) {
    Object? data;
    try {
      data = jsonDecode(text);
    } catch (_) {
      return null;
    }
    return _pickUrl(data, 0);
  }

  /// 在 JSON 结构里按常见字段名找地址，最多往下钻三层
  String? _pickUrl(Object? node, int depth) {
    if (depth > 3 || node == null) return null;
    if (node is String) {
      final s = node.trim();
      if (!s.startsWith('http://') && !s.startsWith('https://')) return null;
      // 兜底扫描整棵树时容易捞到封面图 / 统计脚本，这些显然不是播放地址
      final lower = s.toLowerCase();
      for (final ext in const [
        '.jpg',
        '.jpeg',
        '.png',
        '.gif',
        '.webp',
        '.css',
        '.js',
      ]) {
        if (lower.endsWith(ext)) return null;
      }
      return s;
    }
    if (node is List) {
      for (final item in node) {
        final found = _pickUrl(item, depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    if (node is! Map) return null;

    // 优先按字段名取，字段名认不出再把整棵子树扫一遍
    for (final key in const [
      'url',
      'play_url',
      'playUrl',
      'src',
      'm3u8',
      'video',
      'data',
      'result',
    ]) {
      if (!node.containsKey(key)) continue;
      final found = _pickUrl(node[key], depth + 1);
      if (found != null) return found;
    }
    for (final value in node.values) {
      final found = _pickUrl(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  /// 抠出来的链接常被 HTML 实体或标点包着，去掉尾巴上的杂字符
  String _trimUrl(String url) {
    var s = url
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&')
        .replaceAll(r'\/', '/');
    while (s.isNotEmpty) {
      final last = s[s.length - 1];
      if (last == ',' ||
          last == ';' ||
          last == ')' ||
          last == ']' ||
          last == '}' ||
          last == '\\' ||
          last == '"' ||
          last == "'") {
        s = s.substring(0, s.length - 1);
      } else {
        break;
      }
    }
    return s;
  }

  /// 异常信息可能很长（含完整 URI），截一段够定位就行
  String _short(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 120 ? '${one.substring(0, 120)}…' : one;
  }
}
