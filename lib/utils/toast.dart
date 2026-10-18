import 'package:flutter/material.dart';

/// 轻提示（对应 uni-app 版 u-toast）
///
/// [duration] 默认 1.5 秒；需要让用户看清较长结果（导入统计等）时传长一点。
void showToast(
  BuildContext context,
  String message, {
  bool success = true,
  Duration duration = const Duration(milliseconds: 1500),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: success ? null : Colors.orange,
      duration: duration,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
