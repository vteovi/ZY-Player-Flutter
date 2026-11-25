import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/site.dart';

/// 导出格式。
enum SiteExportFormat {
  /// TVBox / 影视仓 / 猫影视一类客户端通用的配置：`{"sites":[...]}`
  ///
  /// 兼容面最广，本应用自己也能再导入（`SourceImport` 认 `sites` 数组）。
  tvbox,

  /// ZYFun（zy-player 桌面版）配置：`{"tbl_site":[...]}`
  ///
  /// 与它的「设置 → 数据管理 → 配置导出」同构，会额外保留启用状态。
  zyfun,
}

/// 导出结果。
class SiteExportResult {
  final bool ok;
  final String message;
  final String? path;

  const SiteExportResult({required this.ok, required this.message, this.path});
}

/// 视频源导出。
///
/// 只导出**采集接口**（maccms json/xml），因为这些客户端也只认 type 0/1
/// 的 cms 源；spider / drpy 源本应用本来就不支持，自然不会出现在列表里。
///
/// 两种格式的 `type` 都用数字：`0` = maccms xml、`1` = maccms json。
/// TVBox 的 Site 模型里 type 是整数，写字符串会解析失败；ZYFun 与 TVBox
/// 一脉相承，同样吃数字。
class SiteExport {
  SiteExport._();

  /// 美化输出：两空格缩进，方便用户直接看 / 手工改。
  static const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

  /// Site.type 是 'json' / 'xml' 字符串，导出时要换回客户端的数字约定。
  static int _typeCode(Site site) => site.isJson ? 1 : 0;

  static String _name(Site site) => site.name.trim().isEmpty
      ? (site.key.trim().isEmpty ? '未命名' : site.key.trim())
      : site.name.trim();

  static String _group(Site site) =>
      site.group.trim().isEmpty ? '默认' : site.group.trim();

  /// 生成配置文本（不落盘，便于自检与复用）。
  static String buildJson(List<Site> sites, SiteExportFormat format) {
    final payload = switch (format) {
      SiteExportFormat.tvbox => <String, dynamic>{'sites': _tvboxSites(sites)},
      SiteExportFormat.zyfun => <String, dynamic>{'tbl_site': _zyfunSites(sites)},
    };
    return _pretty.convert(payload);
  }

  /// TVBox / 影视仓的 sites 数组。
  static List<Map<String, dynamic>> _tvboxSites(List<Site> sites) {
    final list = <Map<String, dynamic>>[];
    for (final s in sites) {
      list.add(<String, dynamic>{
        'key': s.key,
        'name': _name(s),
        'type': _typeCode(s),
        'api': s.api,
        // TVBox 用这三个开关表达「参与搜索 / 快搜 / 筛选」。
        // 停用的源置 0：TVBox 没有 isActive 概念，这样至少不会往
        // 搜索结果里塞一堆用户已经不要的站。
        'searchable': s.isActive ? 1 : 0,
        'quickSearch': s.isActive ? 1 : 0,
        'filterable': 1,
        'group': _group(s),
        // 只在配了的时候写：TVBox 系客户端会忽略不认识的字段，但空串
        // 铺满整个配置也没必要。
        if (s.parseApi.trim().isNotEmpty) 'parseApi': s.parseApi,
      });
    }
    return list;
  }

  /// ZYFun 的 tbl_site 数组（保留启用状态与状态文案）。
  static List<Map<String, dynamic>> _zyfunSites(List<Site> sites) {
    final list = <Map<String, dynamic>>[];
    var id = 1;
    for (final s in sites) {
      list.add(<String, dynamic>{
        'id': id++,
        'key': s.key,
        'name': _name(s),
        'api': s.api,
        'type': _typeCode(s),
        'group': _group(s),
        'isActive': s.isActive,
        'status': s.status,
        'download': s.download,
        if (s.parseApi.trim().isNotEmpty) 'parseApi': s.parseApi,
      });
    }
    return list;
  }

  /// 导出为文件：弹系统「另存为」对话框，用户选好位置即落盘。
  ///
  /// 平台差异与数据备份一致（见 `DataBackup.backup`）：
  /// - Android / iOS：`saveFile` 必须带 bytes，由原生端走 SAF 写入所选位置；
  /// - Windows / macOS / Linux：`saveFile` 只返回路径，内容由 Dart 侧写。
  static Future<SiteExportResult> save(
    List<Site> sites,
    SiteExportFormat format,
  ) async {
    if (sites.isEmpty) {
      return const SiteExportResult(ok: false, message: '没有可导出的视频源');
    }
    final json = buildJson(sites, format);
    final bytes = Uint8List.fromList(utf8.encode(json));
    final fileName = 'ZYPlayer-sites-${_timestamp()}.json';
    final count = sites.length;

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final result = await FilePicker.platform.saveFile(
          dialogTitle: '导出视频源',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: const ['json'],
          bytes: bytes,
        );
        if (result == null) {
          return const SiteExportResult(ok: false, message: '已取消导出');
        }
        // Android 返回 content:// URI，没有可读磁盘路径，提示用所选位置 + 文件名
        final shown =
            result.startsWith('content:') ? '所选位置：$fileName' : result;
        return SiteExportResult(
          ok: true,
          message: '已导出 $count 个源到$shown',
          path: result,
        );
      }

      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出视频源',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (path == null) {
        return const SiteExportResult(ok: false, message: '已取消导出');
      }
      await File(path).writeAsString(json, encoding: utf8);
      return SiteExportResult(
        ok: true,
        message: '已导出 $count 个源到：$path',
        path: path,
      );
    } catch (e) {
      // 保存对话框在个别系统 / 版本上不可用：退回免权限可写目录，
      // 别让「导出」直接失败（用户至少还能拿到文件）。
      try {
        final dir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final path = '${dir.path}${Platform.pathSeparator}$fileName';
        await File(path).writeAsString(json, encoding: utf8);
        return SiteExportResult(
          ok: true,
          message: '无法打开保存对话框，已改存到：$path',
          path: path,
        );
      } catch (_) {
        return SiteExportResult(
          ok: false,
          message: '导出失败：${_localized(e)}',
        );
      }
    }
  }

  /// 文件名时间戳：YYYYMMDD_HHMMSS。
  static String _timestamp() {
    final now = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p(now.month)}${p(now.day)}_'
        '${p(now.hour)}${p(now.minute)}${p(now.second)}';
  }

  /// 把常见底层异常转成中文，避免把英文堆给用户。
  static String _localized(Object e) {
    final s = e.toString();
    final lower = s.toLowerCase();
    if (s.contains('not supported on this platform')) {
      return '当前平台不支持该保存方式';
    }
    if (lower.contains('permission')) return '没有写入权限';
    if (lower.contains('no such file') ||
        lower.contains('cannot open') ||
        lower.contains('read-only')) {
      return '无法创建或写入文件';
    }
    return s;
  }
}
