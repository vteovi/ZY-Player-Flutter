import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/data_backup.dart';
import '../services/list_cache.dart';
import '../services/system_control.dart';
import '../services/update_service.dart';
import '../utils/file_pick.dart';
import '../utils/toast.dart';
import 'site_page.dart';
import 'star_page.dart';
import 'sync_page.dart';

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
      // 扩展名过滤走 FilePick：老系统 MIME 表不认 json/conf 时自动退回不过滤的选择器。
      result = await FilePick.pick(extensions: const ['json', 'txt', 'conf']);
    } catch (e) {
      if (!context.mounted) return;
      showToast(context, '无法打开文件选择器：$e', success: false);
      return;
    }
    if (result == null || result.files.isEmpty) return; // 用户取消

    // 优先用选择器直接返回的字节，取不到再按路径读（老系统上更稳）。
    Uint8List? raw = result.files.single.bytes;
    if (raw == null) {
      final path = result.files.single.path;
      if (path == null) {
        if (!context.mounted) return;
        showToast(context, '文件无效', success: false);
        return;
      }
      try {
        raw = await File(path).readAsBytes();
      } catch (e) {
        if (!context.mounted) return;
        showToast(context, '读取文件失败：$e', success: false);
        return;
      }
    }
    // 容错解码：源清单可能是 GBK 等非 UTF-8 编码，个别坏字节不该让整份文件读不进来
    final content = utf8.decode(raw, allowMalformed: true);

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
          _MenuItem(
            title: '设备同步',
            subtitle: '通过局域网在设备间同步视频源、配置、收藏与历史',
            onTap: () => _push(context, const SyncPage()),
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
          if (Platform.isAndroid)
            SwitchListTile(
              title: const Text('强制软件解码'),
              subtitle: const Text(
                  '部分机型硬解会报「播放失败」，开启后改用软件解码器（兼容性更好、略耗电），下次播放生效'),
              value: appState.config.forceSoftwareDecode,
              onChanged: (value) =>
                  context.read<AppState>().setForceSoftwareDecode(value),
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
          _VersionUpdateTile(onTap: () => _checkUpdate(context)),
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

  // --------------------------------------------------------------------------
  // 版本更新
  // --------------------------------------------------------------------------

  /// 防抖：检查 / 下载期间忽略重复点击。
  static bool _updating = false;

  /// 完整的更新流程：拉清单 → 比 versionCode → 提示 → 下载 → 调系统安装器。
  ///
  /// 关键点：比较基准取**已安装包**的 versionCode（原生 PackageManager），
  /// 而不是写死在 Dart 里的字符串——那样一旦忘记同步就会误判「已是最新」。
  Future<void> _checkUpdate(BuildContext context) async {
    if (_updating) return;
    if (!Platform.isAndroid) {
      showToast(context, '桌面端请到发布页下载新版本');
      return;
    }

    final appState = context.read<AppState>();
    _updating = true;

    final localCode = await SystemControl.appVersionCode();
    final localName = await SystemControl.appVersionName();
    if (!context.mounted) {
      _updating = false;
      return;
    }

    // 检查中对话框：网络差时最长要等 12 秒，没有反馈会被当成点了没反应。
    // 用 PopScope 挡住返回键 —— 这个框只能由下面的代码 pop，
    // 否则用户按返回关掉它之后，我们再 pop 就会把设置页也关掉。
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: _CheckingDialog(),
      ),
    );

    UpdateInfo? info;
    String? error;
    try {
      info = await UpdateService.fetchManifest(appState.config.updateUrl);
    } on UpdateException catch (e) {
      error = e.message;
    } catch (e) {
      error = '检查更新失败：$e';
    } finally {
      _updating = false;
    }

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关掉「检查中」

    if (info == null) {
      await _showUpdateError(context, error ?? '检查更新失败');
      return;
    }

    if (!UpdateService.isNewer(info,
        localCode: localCode, localName: localName)) {
      showToast(
        context,
        localName.isEmpty ? '当前已是最新版本' : '当前已是最新版本 $localName',
        success: true,
      );
      return;
    }

    await _showNewVersion(context, info, localName);
  }

  Future<void> _showNewVersion(
    BuildContext context,
    UpdateInfo info,
    String localName,
  ) async {
    final localLabel = localName.isEmpty ? '未知' : localName;
    final remoteLabel = info.versionCode > 0
        ? '${info.versionName} (${info.versionCode})'
        : info.versionName;

    // 返回值：true = 立即更新，false / null = 稍后或浏览器打开
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: !info.force,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 ${info.versionName}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('当前版本：$localLabel',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text('最新版本：$remoteLabel',
                  style: const TextStyle(fontSize: 13)),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text('更新内容',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 6),
                Text(info.notes, style: const TextStyle(fontSize: 13)),
              ],
              if (info.force) ...[
                const SizedBox(height: 14),
                const Text('此版本为必须更新，否则可能无法继续使用。',
                    style: TextStyle(
                        fontSize: 12, color: Color(0xFFFF4445))),
              ],
            ],
          ),
        ),
        actions: [
          if (!info.force)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('later'),
              child: const Text('稍后'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('browser'),
            child: const Text('浏览器下载'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('now'),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );

    if (!context.mounted) return;
    if (action == 'browser') {
      // App 内下载不动时的兜底：交给系统浏览器，用户自己下载安装
      final ok = await SystemControl.openUrl(info.apkUrl);
      if (!context.mounted) return;
      if (!ok) showToast(context, '打开浏览器失败，请长按复制下载地址');
      return;
    }
    if (action != 'now') return;
    await _downloadAndInstall(context, info);
  }

  Future<void> _downloadAndInstall(
    BuildContext context,
    UpdateInfo info,
  ) async {
    final progress = ValueNotifier<double>(0);
    var cancelled = false;

    // 进度框同样只能由下面的代码 pop（理由同上）
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _DownloadDialog(
          versionName: info.versionName,
          progress: progress,
          onCancel: () => cancelled = true,
        ),
      ),
    );

    File? file;
    String? error;
    try {
      file = await UpdateService.download(
        info,
        onProgress: (p) {
          if (!cancelled) progress.value = p;
        },
        isCancelled: () => cancelled,
      );
    } on UpdateException catch (e) {
      error = e.message;
    } catch (e) {
      error = '下载失败：$e';
    }

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关掉进度框

    if (cancelled) return;
    if (file == null) {
      await _showUpdateError(context, error ?? '下载失败');
      return;
    }

    final status = await SystemControl.installApk(file.path);
    if (!context.mounted) return;

    switch (status) {
      case 'ok':
        showToast(context, '已调起安装程序，请按提示完成安装', success: true);
        break;
      case 'no_permission':
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('需要安装权限'),
            content: const Text(
              '系统还没允许本应用安装应用。请在接下来的设置页里'
              '打开「允许安装应用 / 安装未知应用」，再回到设置页点一次「版本更新」。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('去设置'),
              ),
            ],
          ),
        );
        if (go == true) await SystemControl.openInstallPermissionSettings();
        break;
      case 'no_file':
        await _showUpdateError(context, '安装包文件不见了，请重新下载');
        break;
      default:
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('无法安装'),
            content: const Text(
              '已经下载完成，但系统没能打开安装界面。\n\n'
              '最常见的原因是当前安装包的签名与手机上已装版本不一致——'
              '比如一个是本地构建、一个是云端构建。这种情况请先卸载旧版再安装。',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
        break;
    }
  }

  Future<void> _showUpdateError(BuildContext context, String message) async {
    final edit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检查更新失败'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('设置更新地址'),
          ),
        ],
      ),
    );
    if (edit == true && context.mounted) {
      await _editUpdateUrl(context);
    }
  }

  Future<void> _editUpdateUrl(BuildContext context) async {
    final appState = context.read<AppState>();
    final url = await showDialog<String>(
      context: context,
      builder: (_) => _UpdateUrlDialog(
        initial: appState.config.updateUrl.isEmpty
            ? UpdateService.defaultManifestUrl
            : appState.config.updateUrl,
      ),
    );
    if (url == null || !context.mounted) return;
    await appState.setUpdateUrl(url == _UpdateUrlDialog.useDefault ? '' : url);
    if (!context.mounted) return;
    showToast(
      context,
      url == _UpdateUrlDialog.useDefault ? '已恢复默认更新地址' : '更新地址已保存',
      success: true,
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

/// 「版本更新」入口：副标题显示**已安装包**的真实版本号。
///
/// 走原生 PackageManager 读取，不再在 Dart 里手写版本号——之前这里是硬编码
/// 字符串，升版本时容易漏改，界面显示的版本会和实际 APK 对不上。
class _VersionUpdateTile extends StatefulWidget {
  final VoidCallback onTap;
  const _VersionUpdateTile({required this.onTap});

  @override
  State<_VersionUpdateTile> createState() => _VersionUpdateTileState();
}

class _VersionUpdateTileState extends State<_VersionUpdateTile> {
  String _label = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = await SystemControl.appVersionName();
    final code = await SystemControl.appVersionCode();
    if (!mounted) return;
    setState(() {
      if (name.isEmpty) {
        _label = '点击检查更新';
      } else if (code > 0) {
        _label = '$name ($code) · 点击检查更新';
      } else {
        _label = '$name · 点击检查更新';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('版本更新'),
      subtitle: Text(
        _label.isEmpty ? '读取版本号…' : _label,
        style: const TextStyle(fontSize: 12),
      ),
      onTap: widget.onTap,
    );
  }
}

/// 检查中的提示框（网络差时最长要等 12 秒，必须给反馈）
class _CheckingDialog extends StatelessWidget {
  const _CheckingDialog();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 14),
          Text('正在检查更新…'),
        ],
      ),
    );
  }
}

/// 下载进度框。
///
/// 点「取消」只在内部置标记、**不自己 pop**：关闭对话框统一由调用方在
/// 下载真正结束后做，否则会和调用方的 pop 叠加，多关一层把设置页也关掉。
class _DownloadDialog extends StatefulWidget {
  final String versionName;
  final ValueNotifier<double> progress;
  final VoidCallback onCancel;

  const _DownloadDialog({
    required this.versionName,
    required this.progress,
    required this.onCancel,
  });

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  bool _cancelling = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('正在下载 ${widget.versionName}'),
      content: ValueListenableBuilder<double>(
        valueListenable: widget.progress,
        builder: (context, value, _) {
          final percent = (value * 100).clamp(0, 100).toStringAsFixed(0);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                // 服务器没给 Content-Length 时 value 恒为 0，此时用不确定进度条
                value: value > 0 ? value : null,
              ),
              const SizedBox(height: 10),
              Text(
                _cancelling
                    ? '正在取消…'
                    : (value > 0 ? '$percent%' : '正在连接…'),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: _cancelling
              ? null
              : () {
                  setState(() => _cancelling = true);
                  widget.onCancel();
                },
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 编辑更新清单地址。留空 / 点「恢复默认」回到内置地址。
class _UpdateUrlDialog extends StatefulWidget {
  /// 返回这个哨兵值表示「恢复默认」，避免和用户输入的空串混淆
  static const String useDefault = '__use_default__';

  final String initial;

  const _UpdateUrlDialog({required this.initial});

  @override
  State<_UpdateUrlDialog> createState() => _UpdateUrlDialogState();
}

class _UpdateUrlDialogState extends State<_UpdateUrlDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('更新清单地址'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '填写 update.json 的完整地址；点「恢复默认」使用内置地址。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_UpdateUrlDialog.useDefault),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
