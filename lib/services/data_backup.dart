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
/// - 备份：Windows 直接写到「下载」文件夹；Android / iOS 走系统文件选择器（SAF），
///   用户可导航到 Download，无需任何存储权限。
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

  /// 备份到本地文件。优先写到下载文件夹；不可写时改用系统选择器。
  static Future<BackupResult> backup() async {
    String json;
    try {
      json = await buildBackupJson();
    } catch (e) {
      return BackupResult(ok: false, message: '读取数据失败：$e');
    }
    final fileName = 'ZYPlayer-backup-${_timestamp()}.json';

    // Windows：下载文件夹可直接写，无需权限，自动落盘体验最好。
    if (Platform.isWindows) {
      try {
        final dir = await getDownloadsDirectory();
        if (dir != null) {
          final path = '${dir.path}\\$fileName';
          await File(path).writeAsString(json, encoding: utf8);
          return BackupResult(ok: true, message: '已备份到：$path', path: path);
        }
      } catch (_) {
        // 落到下面的选择器兜底
      }
    }

    // Android / iOS / 兜底：系统文件选择器（SAF），用户可导航到 Download。
    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: '选择备份文件保存位置（建议选 Download 文件夹）',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (result == null) {
        return const BackupResult(ok: false, message: '已取消保存');
      }
      await File(result).writeAsString(json, encoding: utf8);
      return BackupResult(ok: true, message: '已备份到：$result', path: result);
    } catch (e) {
      return BackupResult(ok: false, message: '保存失败：$e');
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
      return BackupResult(ok: false, message: '无法打开文件选择器：$e');
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
      return BackupResult(ok: false, message: '文件解析失败：$e');
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
      return BackupResult(ok: false, message: '写入数据失败：$e');
    }
    return const BackupResult(ok: true, message: '恢复成功');
  }

  /// 备份文件名里用的时间戳：YYYYMMDD_HHMMSS。
  static String _timestamp() {
    final now = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p(now.month)}${p(now.day)}_${p(now.hour)}${p(now.minute)}${p(now.second)}';
  }
}
