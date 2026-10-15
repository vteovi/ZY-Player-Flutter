import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/data_backup.dart';
import '../services/list_cache.dart';
import '../utils/toast.dart';
import 'site_page.dart';
import 'star_page.dart';

/// 「设置」：播放相关开关 + 数据入口 + 清理/重置
class MePage extends StatelessWidget {
  const MePage({super.key});

  /// 通用的二次确认对话框：红底「确定」+「取消」，返回是否确认。
  Future<bool> _confirmClear(
    BuildContext context,
    String title,
    String content,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF4445),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  Future<void> _clearHistory(BuildContext context) async {
    final confirmed = await _confirmClear(
      context,
      '清空播放记录',
      '确定要清空所有播放记录吗？此操作不可恢复。',
    );
    if (!confirmed) return;
    final ok = await context.read<AppState>().clearHistories();
    if (!context.mounted) return;
    showToast(context, ok ? '清空播放数据成功' : '清空播放数据失败', success: ok);
  }

  Future<void> _clearStar(BuildContext context) async {
    final confirmed = await _confirmClear(
      context,
      '清空收藏夹',
      '确定要清空收藏夹中的所有内容吗？此操作不可恢复。',
    );
    if (!confirmed) return;
    final ok = await context.read<AppState>().clearStars();
    if (!context.mounted) return;
    showToast(context, ok ? '清空收藏夹数据成功' : '清空收藏夹数据失败', success: ok);
  }

  /// 清除所有分类片单的本地缓存（数据层，与封面图片缓存无关）。
  /// 清除后打开分类会重新从网络加载一次；已缓存的封面不受影响。
  Future<void> _clearListCache(BuildContext context) async {
    final confirmed = await _confirmClear(
      context,
      '清除片单缓存',
      '确定要清除所有分类片单的本地缓存吗？清除后打开分类会重新从网络加载一次，已缓存的封面不受影响。',
    );
    if (!confirmed) return;
    await ListCache.clearAll();
    if (!context.mounted) return;
    showToast(context, '已清除片单缓存');
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

  /// 备份数据：视频源、播放记录、收藏夹、设置项。
  Future<void> _backupData(BuildContext context) async {
    final result = await DataBackup.backup();
    if (!context.mounted) return;
    showToast(context, result.message, success: result.ok);
  }

  /// 从备份文件恢复数据（覆盖式），恢复后刷新内存状态。
  Future<void> _restoreData(BuildContext context) async {
    final confirmed = await _confirmClear(
      context,
      '恢复备份',
      '恢复将覆盖当前的视频源、播放记录、收藏夹和设置项，确定继续吗？',
    );
    if (!confirmed) return;
    final result = await DataBackup.restore();
    if (!context.mounted) return;
    if (result.ok) {
      await context.read<AppState>().reloadAll();
    }
    if (!context.mounted) return;
    showToast(context, result.message, success: result.ok);
  }

  /// 从本地 JSON 文件导入 TVBox / ZYFun 配置（合并导入，保留现有源）。
  Future<void> _importConfigFile(BuildContext context) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'conf'],
        allowMultiple: false,
      );
    } catch (e) {
      if (!context.mounted) return;
      showToast(context, '无法打开文件选择器：$e', success: false);
      return;
    }
    if (result == null || result.files.isEmpty) return; // 用户取消
    final path = result.files.single.path;
    if (path == null) return;

    String content;
    try {
      // 容错解码：源清单可能是 GBK 等非 UTF-8 编码，个别坏字节不该让整份文件读不进来
      final bytes = await File(path).readAsBytes();
      content = utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      if (!context.mounted) return;
      showToast(context, '读取文件失败：$e', success: false);
      return;
    }

    final summary =
        await context.read<AppState>().importSitesFromContent(content);
    if (!context.mounted) return;

    if (!summary.ok) {
      showToast(context, '导入失败：${summary.message}', success: false);
      return;
    }
    final fmt = summary.format == 'zyfun'
        ? 'ZYFun'
        : summary.format == 'tvbox'
            ? 'TVBox'
            : '配置';
    final parts = ['导入$fmt 成功：新增 ${summary.added} 个'];
    if (summary.updated > 0) parts.add('更新 ${summary.updated} 个');
    if (summary.skipped > 0) {
      parts.add('跳过 ${summary.skipped} 个需插件的源');
    }
    showToast(context, parts.join('，'), success: true);
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

  /// 自定义播放器（PC / Windows 专属）：用文件选择器选一个 .exe，
  /// 之后「外部播放」会直接启动它而不是自动查找已安装的播放器。
  Widget _buildExternalPlayerTile(BuildContext context) {
    final path = context.watch<AppState>().config.externalPlayerPath;
    final fileName = path.isNotEmpty
        ? path.split(RegExp(r'[\\/]')).last
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 2),
          child: Text(
            '自定义播放器（PC）',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        ListTile(
          title: const Text('播放器路径'),
          subtitle: Text(
            path.isEmpty
                ? '未设置，将自动查找已安装的播放器（PotPlayer / VLC 等）'
                : (fileName ?? path),
          ),
          trailing: path.isEmpty
              ? const Icon(Icons.chevron_right)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _testExternalPlayer(context, path),
                      child: const Text('测试'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      tooltip: '清除',
                      onPressed: () => _clearExternalPlayer(context),
                    ),
                  ],
                ),
          onTap: () => _pickExternalPlayer(context),
        ),
        if (path.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              path,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
      ],
    );
  }

  /// 选择播放器可执行文件：只接受 .exe，并校验文件存在。
  Future<void> _pickExternalPlayer(BuildContext context) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['exe'],
        allowMultiple: false,
      );
    } catch (e) {
      if (!context.mounted) return;
      showToast(context, '无法打开文件选择器：$e', success: false);
      return;
    }
    if (result == null || result.files.isEmpty) return; // 用户取消
    final picked = result.files.single.path;
    if (picked == null || picked.isEmpty) return;
    if (!picked.toLowerCase().endsWith('.exe')) {
      if (!context.mounted) return;
      showToast(context, '请选择 .exe 播放器程序', success: false);
      return;
    }
    if (!File(picked).existsSync()) {
      if (!context.mounted) return;
      showToast(context, '文件不存在：$picked', success: false);
      return;
    }
    await context.read<AppState>().setExternalPlayerPath(picked);
    if (!context.mounted) return;
    showToast(context, '已设置自定义播放器');
  }

  /// 清除已设置的播放器路径，恢复到自动查找。
  Future<void> _clearExternalPlayer(BuildContext context) async {
    await context.read<AppState>().setExternalPlayerPath('');
    if (!context.mounted) return;
    showToast(context, '已清除自定义播放器路径');
  }

  /// 用指定路径空启动一次播放器，确认路径可用（不传播放地址）。
  Future<void> _testExternalPlayer(BuildContext context, String path) async {
    try {
      await Process.start(path, [], mode: ProcessStartMode.detached);
      if (!context.mounted) return;
      showToast(context, '已尝试启动播放器');
    } catch (e) {
      if (!context.mounted) return;
      showToast(context, '启动失败：$e', success: false);
    }
  }

  /// 主题模式：弹窗单选 跟随系统 / 浅色 / 深色，默认跟随系统。
  /// 选择后写入设置，home 处的 _AppRoot 实时切换 light / dark / system 主题。
  Future<void> _showThemeModePicker(BuildContext context) async {
    const options = [
      ('system', '跟随系统'),
      ('light', '浅色'),
      ('dark', '深色'),
    ];
    final current = context.read<AppState>().config.themeMode;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('主题模式'),
        children: [
          for (final (value, label) in options)
            RadioListTile<String>(
              title: Text(label),
              value: value,
              groupValue: current,
              onChanged: (v) => Navigator.of(dialogContext).pop(v),
            ),
        ],
      ),
    );
    if (picked != null && context.mounted) {
      await context.read<AppState>().setThemeMode(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _MenuItem(
            title: '播放记录',
            subtitle: '记录播放历史',
            onTap: () => _push(context, const StarPage(initialTab: 1)),
          ),
          _MenuItem(
            title: '视频源管理',
            subtitle: '管理视频源数据',
            onTap: () => _push(context, const SitePage()),
          ),
          _MenuItem(
            title: '导入配置源 (TVBox / ZYFun)',
            subtitle: '从本地 JSON 文件导入视频源（合并，保留现有源）',
            onTap: () => _importConfigFile(context),
          ),
          _MenuItem(
            title: '备份数据',
            subtitle: '备份视频源、播放记录、收藏夹、设置项到文件',
            onTap: () => _backupData(context),
          ),
          _MenuItem(
            title: '恢复数据',
            subtitle: '从备份文件恢复（覆盖当前数据）',
            onTap: () => _restoreData(context),
          ),
          SwitchListTile(
            title: const Text('横向卡片模式'),
            subtitle: const Text(
                '开启后海报横版显示（图上文下），竖屏手机每行一个，平板自适应多列'),
            value: appState.config.landscapeCard,
            onChanged: (value) =>
                context.read<AppState>().setLandscapeCard(value),
          ),
          SwitchListTile(
            title: const Text('显示实时下载速度'),
            subtitle: const Text('全屏播放时在右上角显示实时网速'),
            value: appState.config.showSpeed,
            onChanged: (value) => context.read<AppState>().setShowSpeed(value),
          ),
          if (Platform.isWindows) _buildExternalPlayerTile(context),
          ListTile(
            title: const Text('长按加速倍率'),
            subtitle: Text(
              '全屏播放时长按画面可加速，当前：${appState.config.playerLongPressRate.toStringAsFixed(1)} 倍',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showLongPressRatePicker(context),
          ),
          ListTile(
            title: const Text('主题模式'),
            subtitle: Text(
              '当前：${const {
                'system': '跟随系统',
                'light': '浅色',
                'dark': '深色',
              }[appState.config.themeMode] ?? '跟随系统'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showThemeModePicker(context),
          ),
          _MenuItem(
            title: '清除片单缓存',
            subtitle: '清除分类片单的本地缓存（封面不受影响）',
            onTap: () => _clearListCache(context),
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
            subtitle: '1.9.2',
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
