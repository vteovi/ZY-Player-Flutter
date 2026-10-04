import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'zy_database.dart';

/// 备份 / 恢复结果。
class BackupResult {
  final bool ok;
  final String message;
  final String? path;

  const BackupResult({required this.ok, required this.message, this.path});
}

/// 数据备份与恢复。
///
/// 备份内容：视频源(site)、播放记录(history)、收藏夹(star)、设置项(setting)。
/// - 备份：通过系统文件管理器（目录选择器）让用户选一个目录，再把备份文件
///   写入该目录（Android / iOS 13+ / Windows / macOS / Linux 均支持）。
///   仅在目录选择器不可用的极少数系统上，才退回写入免权限的可写目录，
///   保证功能不会失效、也不再把英文异常暴露给用户。
/// - 恢复：用系统文件选择器读取备份 JSON，按命名空间整体回写（覆盖式），随后刷新内存。
class DataBackup {
  DataBackup._();

  /// 需要备份 / 恢复的命名空间，顺序即展示顺序。
  static const List<String> _namespaces = <String>[
    DbNames.site,
    DbNames.history,
    DbNames.star,
    DbNames.setting,
  ];

  /// 把所有命名空间的记录收集成 JSON 字符串。
  static Future<String> buildBackupJson() async {
    final data = <String, dynamic>{};
    for (final db in _namespaces) {
      data[db] = await ZyDatabase.instance.getAll(db);
    }
    final payload = <String, dynamic>{
      'app': 'ZY-Player',
      'schema': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'data': data,
    };
    return jsonEncode(payload);
  }

  /// 备份到本地文件。
  ///
  /// 通过系统文件管理器（目录选择器 getDirectoryPath）让用户选一个目录，
  /// 再把备份 JSON 写入该目录。支持 Android / iOS 13+ / Windows / macOS / Linux。
  /// 两层兜底，保证任何平台都不会出现「保存失败 + 一串英文」：
  /// 1) 选中目录写入失败（如 Android 分区存储拒绝），自动改存免权限可写目录并提示；
  /// 2) 目录选择器本身不可用（极少数系统版本），直接写免权限可写目录。
  static Future<BackupResult> backup() async {
    String json;
    try {
      json = await buildBackupJson();
    } catch (e) {
      return BackupResult(ok: false, message: '读取数据失败：${_localized(e)}');
    }
    final fileName = 'ZYPlayer-backup-${_timestamp()}.json';

    // 1) 通过系统文件管理器选择保存目录（首选交互）。
    // getDirectoryPath 返回 String?：用户取消时通常返回 null 或空串。
    String? dirPath;
    var pickerFailed = false;
    try {
      dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择备份文件保存的目录',
      );
    } catch (e) {
      // 极少数平台不支持目录选择：标记后走兜底目录。
      pickerFailed = true;
    }

    if (!pickerFailed) {
      final target = dirPath?.trim() ?? '';
      if (target.isEmpty) {
        // 用户主动取消选择（getDirectoryPath 取消时返回 null 或空串）。
        return const BackupResult(ok: false, message: '已取消保存');
      }
      final res = await _writeJsonTo(Directory(target), fileName, json, '所选目录');
      if (res.ok) return res;
      // 选中目录写入失败（如系统拒绝）：退回免权限可写目录，保证备份不丢失。
      final fb = await _autoDir(json, fileName);
      if (fb.ok) {
        return BackupResult(
          ok: true,
          message: '所选目录无法写入，已改存到：${fb.path}',
          path: fb.path,
        );
      }
      return res;
    }

    // 2) 兜底：目录选择器不可用时，直接写入免权限的可写目录。
    return _autoDir(json, fileName);
  }

  /// 写入免权限可写目录（下载 / 应用文档目录），作为目录选择器不可用或
  /// 选中目录写入失败时的兜底，保证备份功能在任何平台都不会彻底失效。
  static Future<BackupResult> _autoDir(String json, String fileName) async {
    String label;
    Directory dir;
    try {
      if (Platform.isIOS) {
        dir = await getApplicationDocumentsDirectory();
        label = '应用文档目录（可在「文件」App 中查看）';
      } else {
        final downloads = await getDownloadsDirectory();
        dir = downloads ?? await getApplicationDocumentsDirectory();
        label = '下载文件夹';
      }
    } catch (e) {
      return BackupResult(ok: false, message: '无法定位保存目录：${_localized(e)}');
    }
    return _writeJsonTo(dir, fileName, json, label);
  }

  /// 把备份 JSON 写入指定目录，返回结果（含实际落盘路径）。
  ///
  /// [label] 用于提示文案里标注保存位置，便于用户查找文件。
  static Future<BackupResult> _writeJsonTo(
    Directory dir,
    String fileName,
    String json,
    String label,
  ) async {
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final path = '${dir.path}${Platform.pathSeparator}$fileName';
      await File(path).writeAsString(json, encoding: utf8);
      return BackupResult(ok: true, message: '已备份到：$path（$label）', path: path);
    } catch (e) {
      return BackupResult(ok: false, message: '保存失败：${_localized(e)}');
    }
  }

  /// 从备份文件恢复。覆盖式回写各命名空间，调用方需随后刷新内存状态。
  static Future<BackupResult> restore() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: false,
      );
    } catch (e) {
      return BackupResult(ok: false, message: '无法打开文件选择器：${_localized(e)}');
    }
    if (picked == null || picked.files.isEmpty) {
      return const BackupResult(ok: false, message: '已取消选择');
    }
    final path = picked.files.single.path;
    if (path == null) {
      return const BackupResult(ok: false, message: '文件无效');
    }

    Map<String, dynamic> payload;
    try {
      final content = await File(path).readAsString(encoding: utf8);
      final decoded = jsonDecode(content);
      if (decoded is! Map) throw const FormatException('不是有效的备份文件');
      payload = Map<String, dynamic>.from(decoded);
    } catch (e) {
      return BackupResult(ok: false, message: '文件解析失败：${_localized(e)}');
    }

    final data = payload['data'];
    if (data is! Map) {
      return const BackupResult(ok: false, message: '备份文件缺少数据段');
    }

    try {
      final db = ZyDatabase.instance;
      for (final ns in _namespaces) {
        final list = data[ns];
        if (list is! List) continue; // 缺省命名空间跳过，保持兼容
        await db.removeAll(ns);
        for (final item in list) {
          if (item is Map) {
            await db.put(ns, Map<String, dynamic>.from(item));
          }
        }
      }
    } catch (e) {
      return BackupResult(ok: false, message: '写入数据失败：${_localized(e)}');
    }
    return const BackupResult(ok: true, message: '恢复成功');
  }

  /// 备份文件名里用的时间戳：YYYYMMDD_HHMMSS。
  static String _timestamp() {
    final now = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p(now.month)}${p(now.day)}_${p(now.hour)}${p(now.minute)}${p(now.second)}';
  }

  /// 把常见的底层异常转成中文，避免把一串英文直接暴露给用户。
  ///
  /// 无法识别的异常仍原样返回，便于排查。
  static String _localized(Object e) {
    final s = e.toString();
    final lower = s.toLowerCase();
    if (s.contains('not supported on this platform')) {
      return '当前平台不支持该保存方式';
    }
    if (lower.contains('permission')) {
      return '没有写入权限';
    }
    if (lower.contains('no such file') ||
        lower.contains('cannot open') ||
        lower.contains('read-only')) {
      return '无法创建或写入文件';
    }
    return s;
  }
}
