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

  /// 备份到本地文件。
  ///
  /// 各平台都尽量写入「无需权限」的可写目录，避免依赖 file_picker 的 saveFile
  /// （该 API 仅在 Android 受支持，桌面 / iOS 会直接抛出英文异常，正是此前
  /// 「保存失败 + 一串英文」的根因）：
  /// - Android：优先弹系统选择器（SAF）让用户选位置；若返回的是 content URI
  ///   或写入失败，则退回应用外部存储目录下的 ZYPlayer 子目录（免权限、文件管理器可访问）。
  /// - Windows / Linux / macOS：下载文件夹（取不到则退回应用文档目录）。
  /// - iOS：应用文档目录（可用「文件」App 访问）。
  static Future<BackupResult> backup() async {
    String json;
    try {
      json = await buildBackupJson();
    } catch (e) {
      return BackupResult(ok: false, message: '读取数据失败：${_localized(e)}');
    }
    final fileName = 'ZYPlayer-backup-${_timestamp()}.json';

    // Android：系统选择器优先，取消 / 失败后再决定兜底。
    if (Platform.isAndroid) {
      try {
        final result = await FilePicker.platform.saveFile(
          dialogTitle: '选择备份保存位置（建议选 Download 文件夹）',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        if (result == null) {
          return const BackupResult(ok: false, message: '已取消保存');
        }
        // 部分 Android 版本 saveFile 返回 content:// URI，dart:io 无法直接写
        if (result.startsWith('content:')) {
          throw const FileSystemException('unsupported content uri');
        }
        await File(result).writeAsString(json, encoding: utf8);
        return BackupResult(ok: true, message: '已备份到：$result', path: result);
      } catch (e) {
        // 落到下面的应用目录兜底（用户主动取消已提前 return，不会到这里）
      }
    }

    // 兜底 / 桌面 / iOS：直接写入免权限的可写目录。
    Directory? dir;
    String label;
    try {
      if (Platform.isIOS) {
        dir = await getApplicationDocumentsDirectory();
        label = '应用文档目录（可在「文件」App 中查看）';
      } else if (Platform.isAndroid) {
        final ext = await getExternalStorageDirectory();
        dir = ext == null
            ? null
            : Directory('${ext.path}${Platform.pathSeparator}ZYPlayer');
        label = '应用文件夹 ZYPlayer（文件管理器可访问）';
      } else {
        dir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        label = '下载文件夹';
      }
    } catch (e) {
      return BackupResult(ok: false, message: '无法定位保存目录：${_localized(e)}');
    }

    if (dir == null) {
      return const BackupResult(ok: false, message: '无法定位可写目录');
    }

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
