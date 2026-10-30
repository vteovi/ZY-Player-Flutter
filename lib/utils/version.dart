/// 版本相关**纯逻辑**：更新清单模型 + 版本比较。
///
/// 刻意不依赖 Flutter / http / path_provider，这样可以直接用 `dart run`
/// 做验证（`flutter test` 在部分环境起不来 flutter_tester）。
library;

/// 更新过程中可以直接展示给用户的失败原因。
///
/// 单独包一层：网络层抛出来的 `SocketException` / `TimeoutException`
/// 对用户没有意义（和早期详情页裸抛异常是同一类问题）。
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

/// 远端更新清单（`update.json`）解析结果。
///
/// 字段名做了兼容：`versionName` / `version_name` / `version` 都认，
/// `apkUrl` / `apk_url` / `downloadUrl` / `url` 都认；
/// `version` 写成 `"1.18.0+192"` 时，`+` 后面按 versionCode 解析。
class UpdateInfo {
  final String versionName;

  /// 0 表示清单里没给 versionCode，此时只能按版本名比较。
  final int versionCode;
  final String apkUrl;
  final String notes;

  /// 强制更新：对话框不可取消，只留「立即更新」。
  final bool force;

  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    this.notes = '',
    this.force = false,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final rawName = _pick(
      json,
      const ['versionName', 'version_name', 'version', 'name'],
    ).toString().trim();

    var name = rawName;
    var codeFromName = 0;
    final plus = rawName.indexOf('+');
    if (plus > 0) {
      name = rawName.substring(0, plus).trim();
      codeFromName = int.tryParse(rawName.substring(plus + 1).trim()) ?? 0;
    }

    final code = _asInt(
          _pick(json, const ['versionCode', 'version_code', 'code']),
        ) ??
        codeFromName;

    final url = _pick(
      json,
      const ['apkUrl', 'apk_url', 'downloadUrl', 'download_url', 'url'],
    ).toString().trim();

    if (name.isEmpty) throw const UpdateException('更新清单缺少版本号');
    if (url.isEmpty) throw const UpdateException('更新清单缺少安装包地址');

    final notes =
        _pick(json, const ['notes', 'changelog', 'desc', 'description'])
            .toString()
            .trim();
    final forceRaw = _pick(json, const ['force', 'mandatory']);
    final force = forceRaw == true || forceRaw.toString() == 'true';

    return UpdateInfo(
      versionName: name,
      versionCode: code,
      apkUrl: url,
      notes: notes,
      force: force,
    );
  }

  static dynamic _pick(Map<String, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (v != null && v.toString().trim().isNotEmpty) return v;
    }
    return '';
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim());
  }
}

/// 版本比较规则。全部是纯函数，便于直接验证。
class VersionRules {
  /// 清单版本是否比本地新。
  /// [localCode] 为 0（取不到 versionCode）时退化为版本名比较。
  static bool isNewer(
    UpdateInfo info, {
    required int localCode,
    required String localName,
  }) {
    if (localCode > 0 && info.versionCode > 0) {
      return info.versionCode > localCode;
    }
    return compareNames(info.versionName, localName) > 0;
  }

  /// 比较版本名：`1.18.0` > `1.17.9`，`1.10.0` > `1.9.0`（按数字逐段比，
  /// 不能用字符串比——那样 `"1.10"` 会小于 `"1.9"`）。无法比较时返回 0。
  static int compareNames(String a, String b) {
    List<int> parts(String s) => s
        .split(RegExp(r'[.\-_+]'))
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();

    final pa = parts(a);
    final pb = parts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }
}
