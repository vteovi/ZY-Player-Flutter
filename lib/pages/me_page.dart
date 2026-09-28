import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../utils/toast.dart';
import 'history_page.dart';
import 'site_page.dart';

/// 「设置」：播放相关开关 + 数据入口 + 清理/重置
class MePage extends StatelessWidget {
  const MePage({super.key});

  Future<void> _clearHistory(BuildContext context) async {
    final ok = await context.read<AppState>().clearHistories();
    if (!context.mounted) return;
    showToast(context, ok ? '清空播放数据成功' : '清空播放数据失败', success: ok);
  }

  Future<void> _clearStar(BuildContext context) async {
    final ok = await context.read<AppState>().clearStars();
    if (!context.mounted) return;
    showToast(context, ok ? '清空收藏夹数据成功' : '清空收藏夹数据失败', success: ok);
  }

  Future<void> _resetApp(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置软件'),
        content: const Text(
            '重置软件会清空：收藏夹数据，历史记录，导入的视频源等。恢复默认设置，以及默认的视频源。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!context.mounted) return;
    await context.read<AppState>().resetApp();
    if (!context.mounted) return;
    showToast(context, '软件重置成功');
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// 长按加速倍率：弹窗单选 2.0 / 4.0 / 8.0，默认 2.0。
  /// 全屏播放时长按画面即按所选倍率加速，松手恢复正常速度。
  Future<void> _showLongPressRatePicker(BuildContext context) async {
    final options = [2.0, 4.0, 8.0];
    final current = context.read<AppState>().config.playerLongPressRate;
    final picked = await showDialog<double>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('长按加速倍率'),
        children: [
          for (final rate in options)
            RadioListTile<double>(
              title: Text('${rate.toStringAsFixed(1)} 倍'),
              value: rate,
              groupValue: current,
              onChanged: (value) => Navigator.of(dialogContext).pop(value),
            ),
        ],
      ),
    );
    if (picked != null && context.mounted) {
      await context.read<AppState>().setPlayerLongPressRate(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          const Center(
            child: Image(
              image: AssetImage('assets/images/logo.png'),
              width: 110,
            ),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              'ZY Player APP',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 16),
          _MenuItem(
            title: '播放记录',
            subtitle: '记录播放历史',
            onTap: () => _push(context, const HistoryPage()),
          ),
          _MenuItem(
            title: '视频源管理',
            subtitle: '管理视频源数据',
            onTap: () => _push(context, const SitePage()),
          ),
          SwitchListTile(
            title: const Text('显示实时下载速度'),
            subtitle: const Text('全屏播放时在右上角显示实时网速'),
            value: appState.config.showSpeed,
            onChanged: (value) => context.read<AppState>().setShowSpeed(value),
          ),
          ListTile(
            title: const Text('长按加速倍率'),
            subtitle: Text(
              '全屏播放时长按画面可加速，当前：${appState.config.playerLongPressRate.toStringAsFixed(1)} 倍',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showLongPressRatePicker(context),
          ),
          _MenuItem(
            title: '清空播放记录',
            subtitle: '清空播放记录数据',
            onTap: () => _clearHistory(context),
          ),
          _MenuItem(
            title: '清空收藏夹',
            subtitle: '清空收藏夹数据',
            onTap: () => _clearStar(context),
          ),
          _MenuItem(
            title: '重置软件',
            subtitle: '清空所有数据, 慎点',
            titleColor: const Color(0xFFFF4445),
            onTap: () => _resetApp(context),
          ),
          _MenuItem(
            title: '版本更新',
            subtitle: '1.0.0',
            onTap: () => showToast(context, '当前已是最新版本'),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '所有资源来自网上, 该软件不参与任何制作, 上传, 储存等内容, 禁止传播违法资源. '
              '该软件仅供学习参考, 请于安装后24小时内删除.',
              style: TextStyle(color: Color(0xFFFF4445), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color? titleColor;
  final VoidCallback onTap;

  const _MenuItem({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: TextStyle(color: titleColor)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onTap: onTap,
    );
  }
}
