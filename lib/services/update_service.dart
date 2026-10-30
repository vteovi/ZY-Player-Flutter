import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/version.dart';

// 让调用方只 import 这一个文件：清单模型与版本比较都在 version.dart
export '../utils/version.dart';

/// 版本检查与安装包下载（网络 / 文件部分）。
///
/// 清单是一个普通 JSON，放在任意可直连的地址即可（GitHub raw、Gitee raw、
/// 自己的服务器）。默认指向本仓库 `main` 分支根目录的 `update.json`，
/// 可在设置里改成自己的地址。
class UpdateService {
  UpdateService._();

  /// 默认清单地址。仓库不是公开的、或国内直连 raw 不通时，在设置里改。
  static const String defaultManifestUrl =
      'https://raw.githubusercontent.com/vteovi/ZY-Player-Flutter/main/update.json';

  /// 见 [VersionRules.isNewer]（这里转发一下，调用方不必区分两个类）。
  static bool isNewer(
    UpdateInfo info, {
    required int localCode,
    required String localName,
  }) =>
      VersionRules.isNewer(info, localCode: localCode, localName: localName);

  /// 见 [VersionRules.compareNames]。
  static int compareVersionName(String a, String b) =>
      VersionRules.compareNames(a, b);

  /// 拉取并解析更新清单。[url] 为空时用内置默认地址。
  static Future<UpdateInfo> fetchManifest(String url) async {
    final target = url.trim().isEmpty ? defaultManifestUrl : url.trim();
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const UpdateException('更新地址不合法');
    }

    final client = http.Client();
    try {
      final resp = await client.get(
        uri,
        headers: const {
          // 部分 CDN 会按 UA 返回不同内容，这里给一个明确的标识
          'User-Agent': 'ZYPlayer-Update/1.0',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 12));

      if (resp.statusCode == 404) {
        throw const UpdateException('更新清单不存在（HTTP 404），请检查更新地址');
      }
      if (resp.statusCode != 200) {
        throw UpdateException('更新清单读取失败（HTTP ${resp.statusCode}）');
      }

      final text = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
      // 有些站点 404 时会用 200 返回一个 HTML 错误页，先看首字符
      if (!text.startsWith('{')) {
        throw const UpdateException('更新清单格式不对（返回的不是 JSON）');
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const UpdateException('更新清单格式不对');
      }
      return UpdateInfo.fromJson(decoded.cast<String, dynamic>());
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw const UpdateException('连接更新服务器超时');
    } on SocketException {
      throw const UpdateException('网络连不上，请检查网络或更换更新地址');
    } on FormatException {
      throw const UpdateException('更新清单格式不对（JSON 解析失败）');
    } finally {
      client.close();
    }
  }

  /// 把安装包下载到缓存目录，返回本地文件。
  ///
  /// [onProgress] 收到 0.0 ~ 1.0（服务器没给 Content-Length 时不会回调）。
  /// [isCancelled] 返回 true 时尽快中止并删掉半成品文件。
  static Future<File> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final uri = Uri.tryParse(info.apkUrl);
    if (uri == null || !uri.hasScheme) {
      throw const UpdateException('安装包地址不合法');
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/zy_player_${info.versionCode}.apk');
    if (await file.exists()) {
      await file.delete();
    }

    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] = 'ZYPlayer-Update/1.0';
      final resp = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw UpdateException('下载失败（HTTP ${resp.statusCode}）');
      }

      final total = resp.contentLength ?? 0;
      var received = 0;
      sink = file.openWrite();
      await for (final chunk in resp.stream) {
        if (isCancelled?.call() == true) {
          throw const UpdateException('已取消下载');
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (received == 0) {
        await file.delete();
        throw const UpdateException('下载到的文件是空的');
      }
      // APK 本质是 zip，前两字节应为 PK：能挡掉「下载到网页错误页」的情况
      final head = await file.openRead(0, 2).first;
      if (head.length < 2 || head[0] != 0x50 || head[1] != 0x4B) {
        await file.delete();
        throw const UpdateException('下载到的不是安装包（可能被重定向到了网页）');
      }
      onProgress?.call(1.0);
      return file;
    } on UpdateException {
      await _safeDelete(file);
      rethrow;
    } on TimeoutException {
      await _safeDelete(file);
      throw const UpdateException('下载超时，请换个网络再试');
    } on SocketException {
      await _safeDelete(file);
      throw const UpdateException('下载中断：网络连不上');
    } on HttpException {
      await _safeDelete(file);
      throw const UpdateException('下载中断：连接被关闭');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
