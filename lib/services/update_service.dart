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
/// 自己的服务器）。默认指向本仓库 `main` 分支根目录的 `update.json`。
///
/// 大陆直连 `raw.githubusercontent.com` 基本是「DNS 污染 + TCP 被重置」，
/// 所以默认地址会**并发**尝试若干镜像，谁先成功用谁；安装包下载也一样，
/// 直连失败会自动套一层 GitHub 加速前缀重试。
class UpdateService {
  UpdateService._();

  /// 清单的主地址（GitHub raw）。
  static const String defaultManifestUrl =
      'https://raw.githubusercontent.com/vteovi/ZY-Player-Flutter/main/update.json';

  /// 默认镜像组：raw 直连 + 两个 GitHub 加速 + jsDelivr CDN。
  ///
  /// 注意 jsDelivr 对 `@main` 有小时级缓存，清单更新可能滞后，所以放最后一位，
  /// 只在其他都失败时才靠它兜底。
  static List<String> get defaultManifestUrls => <String>[
        defaultManifestUrl,
        'https://ghproxy.net/$defaultManifestUrl',
        'https://gh-proxy.com/$defaultManifestUrl',
        'https://cdn.jsdelivr.net/gh/vteovi/ZY-Player-Flutter@main/update.json',
      ];

  static const Map<String, String> _manifestHeaders = {
    // 部分 CDN 会按 UA 返回不同内容，这里给一个明确的标识
    'User-Agent': 'ZYPlayer-Update/1.0',
    'Cache-Control': 'no-cache',
  };

  /// 单个地址的等待上限。并发请求下取最大值，不必按地址累加。
  static const Duration _manifestTimeout = Duration(seconds: 12);

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

  /// 拉取并解析更新清单。[url] 为空时用内置默认地址组。
  ///
  /// 用户自己填了地址时**只试那一个**（他可能填的是 Gitee 或自建服务器，
  /// 硬套 GitHub 镜像没有意义）。
  static Future<UpdateInfo> fetchManifest(String url) async {
    final custom = url.trim();
    final targets = custom.isEmpty ? defaultManifestUrls : <String>[custom];

    final uris = <Uri>[];
    for (final t in targets) {
      final uri = Uri.tryParse(t);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) uris.add(uri);
    }
    if (uris.isEmpty) {
      throw const UpdateException('更新地址不合法');
    }

    final resp = await _raceGet(uris);

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
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const UpdateException('更新清单格式不对');
      }
      return UpdateInfo.fromJson(decoded.cast<String, dynamic>());
    } on FormatException {
      throw const UpdateException('更新清单格式不对（JSON 解析失败）');
    }
  }

  /// 并发请求 [uris]，返回**第一个 200** 的响应；全部失败时抛出人话错误。
  ///
  /// 并发而不是串行：串行在断网环境下要把每个地址的超时累加一遍
  /// （4 个地址 × 12 秒 = 用户等 48 秒），并发最多等一个超时。
  static Future<http.Response> _raceGet(List<Uri> uris) async {
    final client = http.Client();
    final completer = Completer<http.Response>();
    final failures = <String>[];
    var pending = uris.length;
    var saw404 = false;

    void settle() {
      pending--;
      if (pending <= 0 && !completer.isCompleted) {
        final reason = failures.isEmpty ? '网络连不上' : failures.join('，');
        completer.completeError(UpdateException(
          saw404
              ? '更新清单不存在（HTTP 404），请检查更新地址'
              : '连不上更新服务器（$reason）。可挂代理后重试，或在设置里填写可用的更新地址',
        ));
      }
    }

    for (final uri in uris) {
      client
          .get(uri, headers: _manifestHeaders)
          .timeout(_manifestTimeout)
          .then((resp) {
        if (resp.statusCode == 200) {
          if (!completer.isCompleted) completer.complete(resp);
        } else {
          if (resp.statusCode == 404) saw404 = true;
          failures.add('${_hostLabel(uri)} HTTP ${resp.statusCode}');
        }
      }).catchError((Object e) {
        failures.add('${_hostLabel(uri)} ${_briefError(e)}');
      }).whenComplete(settle);
    }

    try {
      return await completer.future;
    } finally {
      // 胜出后立刻掐掉还在跑的请求，避免白耗流量
      client.close();
    }
  }

  /// 把安装包下载到缓存目录，返回本地文件。
  ///
  /// [onProgress] 收到 0.0 ~ 1.0（服务器没给 Content-Length 时不会回调）。
  /// [isCancelled] 返回 true 时尽快中止并删掉半成品文件。
  ///
  /// 直连 `github.com` 失败时会自动改走加速前缀重试（同一个文件）。
  static Future<File> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final raw = info.apkUrl.trim();
    final first = Uri.tryParse(raw);
    if (first == null || !first.hasScheme) {
      throw const UpdateException('安装包地址不合法');
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/zy_player_${info.versionCode}.apk');
    await _safeDelete(file);

    Object? lastError;
    for (final uri in _apkCandidates(raw, first)) {
      try {
        return await _downloadOnce(
          uri,
          file,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      } on UpdateException catch (e) {
        // 用户主动取消：不要再换地址重试
        if (e.message.contains('已取消')) rethrow;
        lastError = e;
      } catch (e) {
        lastError = e;
      }
      await _safeDelete(file);
    }

    if (lastError is UpdateException) {
      throw UpdateException(
        '${lastError.message}（已尝试 ${_apkCandidates(raw, first).length} 个下载地址）',
      );
    }
    throw const UpdateException('下载失败，请换个网络再试');
  }

  /// 直连 + GitHub 加速镜像。非 github 域名（自建/Gitee）只试直连。
  static List<Uri> _apkCandidates(String raw, Uri first) {
    final list = <Uri>[first];
    if (raw.contains('github.com') || raw.contains('githubusercontent.com')) {
      for (final prefix in const ['https://gh-proxy.com/', 'https://ghproxy.net/']) {
        final u = Uri.tryParse('$prefix$raw');
        if (u != null) list.add(u);
      }
    }
    return list;
  }

  static Future<File> _downloadOnce(
    Uri uri,
    File file, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
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
        throw const UpdateException('下载到的文件是空的');
      }
      // APK 本质是 zip，前两字节应为 PK：能挡掉「下载到网页错误页」的情况
      final head = await file.openRead(0, 2).first;
      if (head.length < 2 || head[0] != 0x50 || head[1] != 0x4B) {
        throw const UpdateException('下载到的不是安装包（可能被重定向到了网页）');
      }
      onProgress?.call(1.0);
      return file;
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw const UpdateException('下载超时，请换个网络再试');
    } on SocketException {
      throw const UpdateException('下载中断：网络连不上');
    } on HttpException {
      throw const UpdateException('下载中断：连接被关闭');
    } on http.ClientException {
      throw const UpdateException('下载中断：连接被重置');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }
  }

  static String _hostLabel(Uri uri) {
    // 镜像地址的 host 都是一样的代理域名，带上路径首段更好认
    final seg = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    return seg.isEmpty ? uri.host : '${uri.host}/$seg';
  }

  static String _briefError(Object e) {
    if (e is TimeoutException) return '超时';
    if (e is SocketException) return '连不上';
    if (e is http.ClientException) {
      // 典型：Connection reset by peer / Connection closed
      return e.message.contains('reset') ? '连接被重置' : '连接异常';
    }
    return '请求失败';
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
