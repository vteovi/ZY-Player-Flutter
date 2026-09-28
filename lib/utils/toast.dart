import 'package:flutter/material.dart';

/// 轻提示（对应 uni-app 版 u-toast）
void showToast(BuildContext context, String message, {bool success = true}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: success ? null : Colors.orange,
      duration: const Duration(milliseconds: 1500),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
