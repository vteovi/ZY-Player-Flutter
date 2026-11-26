import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/data_backup.dart';
import '../services/list_cache.dart';
import '../services/system_control.dart';
import '../services/update_service.dart';
import '../utils/app_colors.dart';
import '../utils/toast.dart';
import '../widgets/view_mode_picker.dart';
import 'site_page.dart';
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

  /// 外部播放器（Android）：默认「系统分享」每次弹选择器；指定某个应用后，
  /// 所有「外部播放」入口都直接调起它，不用再选。
  Widget _buildAndroidExternalPlayerTile(BuildContext context) {
    final cfg = context.watch<AppState>().config;
    final package = cfg.externalPlayerPackage;
    final name = cfg.externalPlayerLabel.isEmpty ? package : cfg.externalPlayerLabel;
    return _SettingsTile(
      icon: Icons.play_circle_outline,
      title: '外部播放器',
      subtitle: package.isEmpty
          ? '系统分享：每次点外部播放时选择应用'
          : '$name · 点外部播放直接调起',
      onTap: () => _pickAndroidExternalPlayer(context),
    );
  }

  Future<void> _pickAndroidExternalPlayer(BuildContext context) async {
    final cfg = context.read<AppState>().config;
    final picked = await showDialog<ExternalPlayerInfo>(
      context: context,
      builder: (_) => _ExternalPlayerPicker(
        currentPackage: cfg.externalPlayerPackage,
        currentLabel: cfg.externalPlayerLabel,
      ),
    );
    if (picked == null || !context.mounted) return;
    await context.read<AppState>().setExternalPlayer(picked.package, picked.label);
    if (!context.mounted) return;
    showToast(
      context,
      picked.package.isEmpty
          ? '已恢复系统分享'
          : '外部播放器已设为 ${picked.label}',
    );
  }

  /// 自定义播放器（PC / Windows 专属）：用文件选择器选一个 .exe，
  /// 之后「外部播放」会直接启动它而不是自动查找已安装的播放器。
  Widget _buildExternalPlayerTile(BuildContext context) {
    final path = context.watch<AppState>().config.externalPlayerPath;
    return _SettingsTile(
      icon: Icons.open_in_new,
      title: '自定义播放器（PC）',
      subtitle: path.isEmpty
          ? '未设置，将自动查找已安装的播放器（PotPlayer / VLC 等）'
          : path,
      subtitleMaxLines: 2,
      trailing: path.isEmpty
          ? null
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

  /// 卡片显示模式：竖向 / 横向 / 瀑布流三选一，选完立即生效。
  ///
  /// 以前是「横向卡片」和「瀑布流」两个独立开关，得靠优先级（瀑布流 > 横向）
  /// 决定谁生效，用户容易配出两个都开的困惑状态；这里收成一个单选。
  /// 弹层与首页顶栏按钮**长按**共用同一个实现，两处文案不会漂。
  Future<void> _pickViewMode(BuildContext context) async {
    final app = context.read<AppState>();
    final picked =
        await showViewModePicker(context, current: app.config.viewMode);
    if (picked != null) await app.setViewMode(picked);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final cfg = appState.config;
    final merged = cfg.mergeRecords;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // 平板 / 桌面下不把每一行拉满整屏：限宽居中，阅读动线短，也不会
      // 出现「标题在左、开关在屏幕另一端」的割裂感。
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              // ---------------------------------------------------------------
              // 日常入口：看、找、同步
              // ---------------------------------------------------------------
              _SettingsSection(
                title: '内容与数据',
                children: [
                  _SettingsTile(
                    icon: Icons.dns_outlined,
                    title: '视频源管理',
                    subtitle: '增删、排序、检测；导入导出配置也在这里',
                    onTap: () => _push(context, const SitePage()),
                  ),
                  _SettingsTile(
                    icon: Icons.devices,
                    title: '设备同步',
                    subtitle: '局域网内同步视频源、配置、收藏与历史',
                    onTap: () => _push(context, const SyncPage()),
                  ),
                ],
              ),
              // ---------------------------------------------------------------
              // 播放
              // ---------------------------------------------------------------
              _SettingsSection(
                title: '播放',
                children: [
                  _SettingsTile(
                    icon: Icons.fast_forward,
                    title: '长按加速倍率',
                    subtitle:
                        '全屏时长按画面加速，当前 ${cfg.playerLongPressRate.toStringAsFixed(1)} 倍',
                    onTap: () => _showLongPressRatePicker(context),
                  ),
                  _SwitchTile(
                    icon: Icons.speed,
                    title: '显示实时下载速度',
                    subtitle: '全屏播放时在右上角显示实时网速',
                    value: cfg.showSpeed,
                    onChanged: (v) =>
                        context.read<AppState>().setShowSpeed(v),
                  ),
                  if (Platform.isAndroid)
                    _SwitchTile(
                      icon: Icons.memory,
                      title: '强制软件解码',
                      subtitle: '硬解报「播放失败」的机型打开它，下次播放生效',
                      value: cfg.forceSoftwareDecode,
                      onChanged: (v) =>
                          context.read<AppState>().setForceSoftwareDecode(v),
                    ),
                  if (Platform.isAndroid) _buildAndroidExternalPlayerTile(context),
                  if (Platform.isWindows) _buildExternalPlayerTile(context),
                ],
              ),
              // ---------------------------------------------------------------
              // 外观与布局
              // ---------------------------------------------------------------
              _SettingsSection(
                title: '外观与布局',
                children: [
                  _SettingsTile(
                    icon: Icons.dark_mode_outlined,
                    title: '主题模式',
                    subtitle: '当前：${const {
                      'system': '跟随系统',
                      'light': '浅色',
                      'dark': '深色',
                    }[cfg.themeMode] ?? '跟随系统'}',
                    onTap: () => _showThemeModePicker(context),
                  ),
                  _SettingsTile(
                    icon: Icons.view_quilt_outlined,
                    title: '卡片显示模式',
                    subtitle: '当前：${cfg.viewMode.label}',
                    onTap: () => _pickViewMode(context),
                  ),
                  _SwitchTile(
                    icon: Icons.swap_horiz,
                    title: '显示视图切换按钮',
                    subtitle: '首页顶栏的模式按钮：点一下循环切换，长按直接选',
                    value: cfg.showViewToggle,
                    onChanged: (v) =>
                        context.read<AppState>().setShowViewToggle(v),
                  ),
                  _SwitchTile(
                    icon: Icons.call_merge,
                    title: '收藏与历史合并',
                    subtitle: merged
                        ? '导航栏：首页 / 我的 / 设置，收藏与历史是「我的」页的两栏'
                        : '导航栏：首页 / 收藏 / 历史 / 设置，各自独立一页',
                    value: cfg.mergeRecords,
                    onChanged: (v) =>
                        context.read<AppState>().setMergeRecords(v),
                  ),
                ],
              ),
              // ---------------------------------------------------------------
              // 备份
              // ---------------------------------------------------------------
              _SettingsSection(
                title: '备份与恢复',
                children: [
                  _SettingsTile(
                    icon: Icons.backup_outlined,
                    title: '备份数据',
                    subtitle: '视频源、播放记录、收藏夹、设置项打包成文件',
                    onTap: () => _backupData(context),
                  ),
                  _SettingsTile(
                    icon: Icons.restore,
                    title: '恢复数据',
                    subtitle: '从备份文件恢复，会覆盖当前全部数据',
                    onTap: () => _restoreData(context),
                  ),
                ],
              ),
              // ---------------------------------------------------------------
              // 清理（危险操作归一堆，红字统一在最后）
              // ---------------------------------------------------------------
              _SettingsSection(
                title: '清理与重置',
                children: [
                  _SettingsTile(
                    icon: Icons.cleaning_services_outlined,
                    title: '清除片单缓存',
                    subtitle: '只清分类列表的本地缓存，封面不受影响',
                    onTap: () => _clearListCache(context),
                  ),
                  _SettingsTile(
                    icon: Icons.delete_sweep_outlined,
                    title: '清空播放记录',
                    subtitle: '清掉全部观看进度，不可恢复',
                    onTap: () => _clearHistory(context),
                  ),
                  _SettingsTile(
                    icon: Icons.favorite_border,
                    title: '清空收藏夹',
                    subtitle: '清掉全部收藏，不可恢复',
                    onTap: () => _clearStar(context),
                  ),
                  _SettingsTile(
                    icon: Icons.restart_alt,
                    title: '重置软件',
                    subtitle: '收藏、历史、视频源、设置全部回到初始状态',
                    titleColor: const Color(0xFFFF4445),
                    onTap: () => _resetApp(context),
                  ),
                ],
              ),
              // ---------------------------------------------------------------
              // 关于
              // ---------------------------------------------------------------
              _SettingsSection(
                title: '关于',
                children: [
                  _VersionUpdateTile(onTap: () => _checkUpdate(context)),
                ],
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(28, 16, 28, 8),
                child: Text(
                  '所有资源来自网上，该软件不参与任何制作、上传、储存等内容，禁止传播违法资源。'
                  '该软件仅供学习参考，请于安装后 24 小时内删除。',
                  style: TextStyle(color: Color(0xFFFF4445), fontSize: 11, height: 1.5),
                ),
              ),
            ],
          ),
        ),
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

/// 设置项分组：小标题 + 圆角卡片，组内自动补分隔线。
///
/// 深色模式遵守本项目的 OLED 约定 —— 卡片底色仍是纯黑，只用 1px 描边划边界，
/// **不靠提亮底色**分层（一提亮整屏就发灰）。
class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  /// 分隔线缩进到文字起点：16(卡片内边距) + 40(图标占位) + 16(图文间距)
  static const double _dividerIndent = 72;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
          height: 1,
          thickness: 1,
          indent: _dividerIndent,
          endIndent: 16,
          color: isDark ? AppColors.darkDivider : AppColors.lightDivider,
        ));
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
                color: isDark ? AppColors.darkSubText : AppColors.lightSubText,
              ),
            ),
          ),
          // 用 Material 的 shape 画描边：描边在底色之上、子内容之下，
          // 子内容透明就不会把它盖掉；clipBehavior 同时把点击涟漪裁进圆角。
          Material(
            color: isDark ? AppColors.darkBg : AppColors.lightSurface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: isDark ? AppColors.darkOutline : AppColors.lightOutline,
              ),
            ),
            child: Column(children: rows),
          ),
        ],
      ),
    );
  }
}

/// 可点设置行。图标统一走次级色，靠它把整页左侧的视觉节奏对齐。
class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final int subtitleMaxLines;
  final Color? titleColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.subtitleMaxLines = 2,
    this.titleColor,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sub = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    return ListTile(
      leading: Icon(icon, size: 22, color: titleColor ?? sub),
      title: Text(title, style: TextStyle(fontSize: 15, color: titleColor)),
      subtitle: Text(
        subtitle,
        maxLines: subtitleMaxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, height: 1.35, color: sub),
      ),
      trailing: trailing ??
          (onTap == null
              ? null
              : Icon(Icons.chevron_right, size: 20, color: sub)),
      onTap: onTap,
    );
  }
}

/// 开关设置行。`secondary` 在开关对侧（默认左侧），正好当图标位。
class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sub = isDark ? AppColors.darkSubText : AppColors.lightSubText;
    return SwitchListTile(
      secondary: Icon(icon, size: 22, color: sub),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, height: 1.35, color: sub),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// 选择 Android 外部播放器：第一项是「系统分享」（每次弹选择器），
/// 后面是原生查到的、能接住视频地址的应用。点一项即选中并返回。
class _ExternalPlayerPicker extends StatefulWidget {
  final String currentPackage;
  final String currentLabel;

  const _ExternalPlayerPicker({
    required this.currentPackage,
    required this.currentLabel,
  });

  @override
  State<_ExternalPlayerPicker> createState() => _ExternalPlayerPickerState();
}

class _ExternalPlayerPickerState extends State<_ExternalPlayerPicker> {
  List<ExternalPlayerInfo> _players = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final players = await SystemControl.listExternalPlayers();
    if (!mounted) return;
    setState(() {
      _players = players;
      _loading = false;
    });
  }

  void _select(ExternalPlayerInfo info) => Navigator.of(context).pop(info);

  /// 自己画单选圆点：项目里老的 RadioListTile.groupValue 已被 SDK 标弃用，
  /// 这里不需要 RadioGroup 的复杂语义，看见勾、点一下就返回即可。
  Widget _option({
    required String value,
    required String title,
    required String subtitle,
    required ExternalPlayerInfo result,
  }) {
    final checked = widget.currentPackage == value;
    return ListTile(
      leading: Icon(
        checked ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 20,
        color: checked ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () => _select(result),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.currentPackage;
    final rows = <Widget>[
      _option(
        value: '',
        title: '系统分享',
        subtitle: '每次点外部播放时弹出系统选择器',
        result: const ExternalPlayerInfo(package: '', label: '系统分享'),
      ),
    ];

    // 之前选的应用如果卸载了，查询列表里不会有它；仍留一项让用户能看见
    // 「当前选的是谁」并显式改回系统分享，而不是莫名其妙地只剩系统分享。
    if (!_loading &&
        selected.isNotEmpty &&
        !_players.any((p) => p.package == selected)) {
      final label =
          widget.currentLabel.isEmpty ? selected : widget.currentLabel;
      rows.add(
        _option(
          value: selected,
          title: label,
          subtitle: '当前选择 · 设备上没找到，可能已卸载',
          result: ExternalPlayerInfo(package: selected, label: label),
        ),
      );
    }

    for (final player in _players) {
      rows.add(
        _option(
          value: player.package,
          title: player.label,
          subtitle: player.package,
          result: player,
        ),
      );
    }

    return AlertDialog(
      title: const Text('外部播放器'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: rows),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
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
    return _SettingsTile(
      icon: Icons.system_update_alt,
      title: '版本更新',
      subtitle: _label.isEmpty ? '读取版本号…' : _label,
      subtitleMaxLines: 1,
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
