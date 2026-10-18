import 'dart:convert';
import 'dart:typed_data';

/// TVBox 加密配置的解码。
///
/// TVBox 的「加密配置」在网络上传输的是一大段十六进制文本，解出来的字节形如：
///
/// ```text
/// $#123456#$ <AES-128-CBC 密文> <13 字节 IV>
/// ```
///
/// - 头 `$#<key>#$`：key 不足 16 字节时用 `'0'` 右补到 16；
/// - 尾 13 字节：IV，同样用 `'0'` 右补到 16；
/// - 中间：AES-128-CBC + PKCS7 的密文。
///
/// 这与 TVBox 官方 `ApiConfig.FindResult()` 的处理一致。实现只依赖
/// `dart:typed_data`（AES 是自带的，见 [AesCbc]），不引入第三方包。
class TvBoxCrypto {
  TvBoxCrypto._();

  /// 二进制内容的头部长度：`$#key#$` 固定 10 字节（key 为 6 位时）。
  ///
  /// 实际解析时按 `#$` 的位置算，不写死 10。
  static const int _ivLength = 13;

  /// 尝试把 [content] 当作 TVBox 加密配置解码。
  ///
  /// 不是加密配置（或解码失败）时返回 null，调用方可继续按普通 JSON 处理。
  static String? decode(String content) {
    final text = content.trim();
    // 十六进制形式下 `$#` 是 `2423`；极少数站点直接给原文，也兼容一下。
    if (!text.startsWith('2423') && !text.startsWith(r'$#')) return null;

    Uint8List raw;
    try {
      raw = text.startsWith(r'$#')
          ? Uint8List.fromList(utf8.encode(text))
          : _hexToBytes(text);
    } catch (_) {
      return null;
    }
    if (raw.length < 32) return null;

    // 定位头部 `$#key#$`
    final keyStart = _indexOfBytes(raw, const [0x24, 0x23]); // "$#"
    if (keyStart < 0 || keyStart > 8) return null;
    final keyEnd = _indexOfBytes(raw, const [0x23, 0x24], from: keyStart + 2);
    if (keyEnd < 0) return null;
    final key = utf8.decode(raw.sublist(keyStart + 2, keyEnd), allowMalformed: true);

    final bodyStart = keyEnd + 2;
    final bodyEnd = raw.length - _ivLength;
    if (bodyEnd <= bodyStart) return null;
    final body = Uint8List.sublistView(raw, bodyStart, bodyEnd);
    if (body.length % 16 != 0) return null;

    final iv = utf8.decode(
      raw.sublist(bodyEnd),
      allowMalformed: true,
    );
    final keyBytes = _padKey(key, 16);
    final ivBytes = _padKey(iv, 16);
    if (keyBytes == null || ivBytes == null) return null;

    try {
      final plain = AesCbc.decrypt(
        body,
        Uint8List.fromList(keyBytes),
        Uint8List.fromList(ivBytes),
      );
      final out = utf8.decode(plain, allowMalformed: true).trim();
      if (!out.startsWith('{') && !out.startsWith('[')) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 不足 [length] 字节用 `'0'` 右补；超长则截断（与 TVBox 的 rightPadding 一致）。
  static List<int>? _padKey(String value, int length) {
    final bytes = utf8.encode(value.trim());
    if (bytes.isEmpty) return null;
    if (bytes.length >= length) {
      return bytes.sublist(0, length);
    }
    final out = List<int>.from(bytes);
    while (out.length < length) {
      out.add(0x30); // '0'
    }
    return out;
  }

  static Uint8List _hexToBytes(String hex) {
    final s = hex.trim();
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static int _indexOfBytes(Uint8List haystack, List<int> needle, {int from = 0}) {
    outer:
    for (var i = from; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

/// 纯 Dart 的 AES-128-CBC 解密（只实现解密，够用即可）。
///
/// 之所以不引入 pointycastle：本项目只在「导入 TVBox 加密配置」这一处需要
/// AES，自带实现可以避免为一次解密给构建链加一个新依赖。
class AesCbc {
  AesCbc._();

  /// AES-128 CBC 解密 + 去 PKCS7 填充。
  static Uint8List decrypt(Uint8List data, Uint8List key, Uint8List iv) {
    if (key.length != 16 || iv.length != 16) {
      throw ArgumentError('AES-128 需要 16 字节的 key 与 iv');
    }
    if (data.isEmpty || data.length % 16 != 0) {
      throw ArgumentError('密文长度必须是 16 的整数倍');
    }
    final roundKeys = _expandKey(key);
    final out = Uint8List(data.length);
    var prev = iv;
    for (var off = 0; off < data.length; off += 16) {
      final block = Uint8List.sublistView(data, off, off + 16);
      final dec = _decryptBlock(block, roundKeys);
      for (var i = 0; i < 16; i++) {
        out[off + i] = dec[i] ^ prev[i];
      }
      prev = block;
    }
    return _removePkcs7(out);
  }

  // ---------------------------------------------------------------------------
  // 轮函数
  // ---------------------------------------------------------------------------

  static Uint8List _decryptBlock(Uint8List block, Uint8List roundKeys) {
    final s = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      s[i] = block[i] ^ roundKeys[160 + i];
    }
    for (var round = 9; round >= 1; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      for (var i = 0; i < 16; i++) {
        s[i] ^= roundKeys[round * 16 + i];
      }
      _invMixColumns(s);
    }
    _invShiftRows(s);
    _invSubBytes(s);
    for (var i = 0; i < 16; i++) {
      s[i] ^= roundKeys[i];
    }
    return s;
  }

  /// 逆行移位：第 r 行循环右移 r 位。状态按列优先存放（`s[r + 4c]`）。
  static void _invShiftRows(Uint8List s) {
    final t = Uint8List.fromList(s);
    for (var r = 1; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        s[r + 4 * c] = t[r + 4 * ((c - r + 4) % 4)];
      }
    }
  }

  static void _invSubBytes(Uint8List s) {
    for (var i = 0; i < 16; i++) {
      s[i] = _invSbox[s[i]];
    }
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _gmul(a0, 0x0e) ^ _gmul(a1, 0x0b) ^ _gmul(a2, 0x0d) ^ _gmul(a3, 0x09);
      s[i + 1] =
          _gmul(a0, 0x09) ^ _gmul(a1, 0x0e) ^ _gmul(a2, 0x0b) ^ _gmul(a3, 0x0d);
      s[i + 2] =
          _gmul(a0, 0x0d) ^ _gmul(a1, 0x09) ^ _gmul(a2, 0x0e) ^ _gmul(a3, 0x0b);
      s[i + 3] =
          _gmul(a0, 0x0b) ^ _gmul(a1, 0x0d) ^ _gmul(a2, 0x09) ^ _gmul(a3, 0x0e);
    }
  }

  // ---------------------------------------------------------------------------
  // 密钥扩展（AES-128 → 11 组 16 字节轮密钥）
  // ---------------------------------------------------------------------------

  static Uint8List _expandKey(Uint8List key) {
    final rk = Uint8List(176);
    rk.setRange(0, 16, key);
    var rcon = 0x01;
    final t = Uint8List(4);
    for (var i = 16; i < 176; i += 4) {
      t.setRange(0, 4, rk, i - 4);
      if (i % 16 == 0) {
        final tmp = t[0];
        t[0] = _sbox[t[1]];
        t[1] = _sbox[t[2]];
        t[2] = _sbox[t[3]];
        t[3] = _sbox[tmp];
        t[0] ^= rcon;
        rcon = _gmul(rcon, 0x02);
      }
      for (var j = 0; j < 4; j++) {
        rk[i + j] = rk[i - 16 + j] ^ t[j];
      }
    }
    return rk;
  }

  static Uint8List _removePkcs7(Uint8List data) {
    if (data.isEmpty) return data;
    final pad = data.last;
    if (pad < 1 || pad > 16 || pad > data.length) return data;
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) return data;
    }
    return Uint8List.sublistView(data, 0, data.length - pad);
  }

  // ---------------------------------------------------------------------------
  // GF(2^8) 与 S 盒（用算法生成，避免手抄 256 字节表出错）
  // ---------------------------------------------------------------------------

  static int _gmul(int a, int b) {
    var x = a & 0xff;
    var y = b & 0xff;
    var p = 0;
    for (var i = 0; i < 8; i++) {
      if (y & 1 != 0) p ^= x;
      final hi = x & 0x80;
      x = (x << 1) & 0xff;
      if (hi != 0) x ^= 0x1b;
      y >>= 1;
    }
    return p;
  }

  static final Uint8List _sbox = _buildSbox();

  static final Uint8List _invSbox = _buildInvSbox(_sbox);

  /// GF(2^8) 上的乘法逆元：x^254 = x^-1。
  ///
  /// ⚠️ 注意这里必须做**幂运算**，不是 `_gmul(x, 254)`（那表示乘 254）。
  static int _inverse(int x) {
    if (x == 0) return 0; // 约定 0 的逆元为 0
    var result = 1;
    var base = x;
    var exp = 254;
    while (exp > 0) {
      if (exp & 1 != 0) result = _gmul(result, base);
      base = _gmul(base, base);
      exp >>= 1;
    }
    return result;
  }

  static Uint8List _buildSbox() {
    final s = Uint8List(256);
    for (var x = 0; x < 256; x++) {
      final inv = _inverse(x);
      var b = inv;
      var acc = inv;
      for (var i = 0; i < 4; i++) {
        b = ((b << 1) | (b >> 7)) & 0xff;
        acc ^= b;
      }
      s[x] = acc ^ 0x63;
    }
    return s;
  }

  static Uint8List _buildInvSbox(Uint8List sbox) {
    final inv = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      inv[sbox[i]] = i;
    }
    return inv;
  }
}
