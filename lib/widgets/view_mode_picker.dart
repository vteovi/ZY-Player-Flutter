import 'package:flutter/material.dart';

import '../models/video.dart';
import '../utils/app_colors.dart';

/// 三种卡片显示模式的底部选择弹层 —— 首页顶栏按钮**长按**、设置页
/// 「卡片显示模式」共用同一份实现。
///
/// 抽出来的理由很实际：图标、文案、勾选态在两处必须完全一致，各写一份
/// 迟早会漂移（改了一处忘了另一处，用户看到两套说法）。
///
/// 返回值：用户选中的模式；直接关掉弹层返回 null，调用方据此跳过写入。
Future<ViewMode?> showViewModePicker(
  BuildContext context, {
  required ViewMode current,
}) {
  return showModalBottomSheet<ViewMode>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
      final accent = isDark ? AppColors.brandFillDark : AppColors.brandFill;
      final sub = isDark ? AppColors.darkSubText : AppColors.lightSubText;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(
                '卡片显示模式',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF1F1F1F),
                ),
              ),
            ),
            for (final mode in ViewMode.values)
              ListTile(
                leading: Icon(viewModeIcon(mode), size: 22, color: sub),
                title: Text(mode.label, style: const TextStyle(fontSize: 15)),
                subtitle: Text(
                  viewModeDescription(mode),
                  style: TextStyle(fontSize: 12, height: 1.35, color: sub),
                ),
                trailing: mode == current
                    ? Icon(Icons.check_rounded, size: 20, color: accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(mode),
              ),
            const SizedBox(height: 6),
          ],
        ),
      );
    },
  );
}

/// 模式对应的图标。顶栏按钮显示的是**点下去会变成什么**，也复用这张表。
IconData viewModeIcon(ViewMode mode) => switch (mode) {
      ViewMode.portrait => Icons.grid_view_rounded,
      ViewMode.landscape => Icons.view_agenda_rounded,
      ViewMode.waterfall => Icons.view_quilt_rounded,
    };

/// 一句话说明，写在每个选项下面。
String viewModeDescription(ViewMode mode) => switch (mode) {
      ViewMode.portrait => '列数随屏幕宽度变，海报统一竖版比例（默认）',
      ViewMode.landscape => '左图右文，手机竖屏每行一个、平板多列',
      ViewMode.waterfall => '按海报原始比例排，不等高也不裁切',
    };
