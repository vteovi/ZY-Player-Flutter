import 'package:flutter/material.dart';

/// 空数据/错误占位
class EmptyHint extends StatelessWidget {
  final String message;
  final IconData icon;
  final String? actionText;
  final VoidCallback? onAction;

  const EmptyHint({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionText,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: const Color(0xFFC0C4CC)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF909399)),
            ),
            if (actionText != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onAction, child: Text(actionText!)),
            ],
          ],
        ),
      ),
    );
  }
}

// 注：原 uni-app 版的「全屏半透明黑遮罩 + 转圈」（u-mask + u-loading）已移除。
// 它会把整块区域压暗，而首次进分栏 / 换源时底下本来就是空白，
// 表现就是「切一下整页变灰」，观感很差。列表类加载一律改用骨架屏
// （见 widgets/video_grid.dart 的 VideoGridSkeleton）。

/// 底部弹出的单选列表（对应 uni-app 版的 u-select）
Future<T?> showPicker<T>({
  required BuildContext context,
  required String title,
  required List<T> items,
  required String Function(T item) labelBuilder,
  T? selected,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 16),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isSelected =
                      selected != null && item == selected;
                  return ListTile(
                    title: Text(labelBuilder(item)),
                    trailing: isSelected
                        ? const Icon(Icons.check, color: Color(0xFF1E88E5))
                        : null,
                    onTap: () => Navigator.of(context).pop(item),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
