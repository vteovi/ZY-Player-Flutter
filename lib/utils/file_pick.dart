import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// 打开系统文件选择器的兜底封装。
///
/// 背景：Android 原生 file_picker 会把 [FileType.custom] 的扩展名通过系统的
/// `MimeTypeMap` 映射成 MIME 类型来过滤；但老机型 / 定制 ROM 的 MIME 表里
/// 没有 `json`、`conf` 这类扩展名，映射结果为空，插件随即抛出
/// `PlatformException(FilePicker, Unsupported filter...)`，导致「恢复数据」「导入配置源」
/// 在文件选择器还没弹出时就失败（错误发生在启动系统选择器之前，所以下方重试对用户无感）。
///
/// 策略：先按扩展名精确过滤（能过滤的平台体验更好）；若被判定为不支持，则自动
/// 退回 [FileType.any]（不做任何 MIME 过滤）再选一次，由调用方读取内容后自行校验。
class FilePick {
  FilePick._();

  /// 与 file_picker 安卓端的错误码对应（原生端 TAG = "FilePicker"）。
  static const String _code = 'FilePicker';

  static Future<FilePickerResult?> pick({
    required List<String> extensions,
    bool allowMultiple = false,
    bool withData = true,
  }) async {
    try {
      return await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
        allowMultiple: allowMultiple,
        withData: withData,
      );
    } on PlatformException catch (e) {
      // 仅在“扩展名映射不出来”时退回；其它异常（无前台 Activity 等）照常上抛。
      final msg = (e.message ?? '').toLowerCase();
      final unsupported =
          e.code == _code || msg.contains('unsupported filter');
      if (!unsupported) rethrow;
      return FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: allowMultiple,
        withData: withData,
      );
    }
  }
}
