/// 视频源配置地址的规范化工具。
///
/// 用户从各种地方复制来的地址经常不规范，直接丢给 `Uri.parse` 会失败：
/// - `box.example.com`（没有协议头）
/// - `http:box.example.com`（漏了 `//`）
/// - `http://www.饭太硬.cc/tv`（中文域名，系统 DNS 解析不了）
///
/// 这里统一成可直接请求的 ASCII URL。中文域名按 RFC 3492 转成 punycode
/// （`xn--...`），不依赖任何第三方包。
library;

/// 把用户输入的配置地址整理成可直接请求的形式。
///
/// 无法解析时原样返回（至少不会比输入更差）。
String normalizeConfigUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';

  // 去掉粘贴时常见的引号 / 尖括号包裹
  s = s.replaceAll(RegExp(r'''^[<"'“”‘’\s]+|[>"'“”‘’\s]+$'''), '');
  if (s.isEmpty) return '';

  final schemeMatch =
      RegExp(r'^(https?):(?!//)', caseSensitive: false).firstMatch(s);
  if (schemeMatch != null) {
    // http:host → http://host（顺便吃掉多余的前导斜杠）
    final scheme = schemeMatch.group(1)!.toLowerCase();
    var rest = s.substring(schemeMatch.end);
    while (rest.startsWith('/')) {
      rest = rest.substring(1);
    }
    s = '$scheme://$rest';
  } else if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(s)) {
    // 没有协议头：默认 http（很多配置站不支持 https）
    s = 'http://$s';
  }

  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return s;

  // ⚠️ Dart 的 Uri 会把中文域名预先编码成 `%E9%A5%AD...`，
  // 直接看 host 会误判成 ASCII，必须先解回 Unicode 才能转 punycode。
  var host = uri.host;
  if (host.contains('%')) {
    try {
      host = Uri.decodeComponent(host);
    } catch (_) {
      // 保持原样
    }
  }
  if (_isAscii(host)) return uri.toString();

  final asciiHost = toAsciiHost(host);
  if (asciiHost == null) return s;
  try {
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: asciiHost,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  } catch (_) {
    return s;
  }
}

/// 把可能含中文的域名转成 ASCII（punycode）。已是 ASCII 时原样返回。
String? toAsciiHost(String host) {
  if (host.isEmpty) return null;
  if (_isAscii(host)) return host;
  final labels = host.split('.');
  final out = <String>[];
  for (final label in labels) {
    if (label.isEmpty) {
      out.add(label);
      continue;
    }
    if (_isAscii(label)) {
      out.add(label.toLowerCase());
    } else {
      final encoded = _punycodeEncode(label);
      if (encoded == null) return null;
      out.add('xn--$encoded');
    }
  }
  return out.join('.');
}

bool _isAscii(String s) {
  for (final unit in s.codeUnits) {
    if (unit > 127) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Punycode（RFC 3492）
// ---------------------------------------------------------------------------

const int _base = 36;
const int _tMin = 1;
const int _tMax = 26;
const int _skew = 38;
const int _damp = 700;
const int _initialBias = 72;
const int _initialN = 128;

int _adapt(int delta, int numPoints, bool firstTime) {
  delta = firstTime ? delta ~/ _damp : delta ~/ 2;
  delta += delta ~/ numPoints;
  var k = 0;
  while (delta > ((_base - _tMin) * _tMax) ~/ 2) {
    delta ~/= _base - _tMin;
    k += _base;
  }
  return k + (((_base - _tMin + 1) * delta) ~/ (delta + _skew));
}

/// digit → 小写字母 / 数字（0-25 → a-z，26-35 → 0-9）
int _encodeDigit(int d) => d < 26 ? 97 + d : 48 + (d - 26);

String? _punycodeEncode(String label) {
  final input = label.runes.toList();
  if (input.isEmpty) return null;

  final output = StringBuffer();
  final basic = input.where((c) => c < 0x80).toList();
  output.write(String.fromCharCodes(basic));
  var handled = basic.length;
  final basicCount = handled;
  if (basicCount > 0) output.write('-');

  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;

  while (handled < input.length) {
    // 取下一个要处理的码位（>= n 中最小的）
    var m = input.firstWhere((c) => c >= n, orElse: () => n);
    for (final c in input) {
      if (c >= n && c < m) m = c;
    }
    delta += (m - n) * (handled + 1);
    n = m;

    for (final c in input) {
      if (c < n) {
        delta++;
      } else if (c == n) {
        var q = delta;
        for (var k = _base;; k += _base) {
          final t = k <= bias
              ? _tMin
              : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) break;
          output.writeCharCode(
            _encodeDigit(t + (q - t) % (_base - t)),
          );
          q = (q - t) ~/ (_base - t);
        }
        output.writeCharCode(_encodeDigit(q));
        bias = _adapt(delta, handled + 1, handled == basicCount);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }

  return output.toString();
}
