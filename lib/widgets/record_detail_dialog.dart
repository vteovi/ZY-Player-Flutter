import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../pages/detail_page.dart';
import '../providers/app_state.dart';
import '../services/system_control.dart';
import '../utils/app_colors.dart';
import '../utils/image_cache.dart';
import '../utils/toast.dart';

/// 收藏 / 历史条目的「外部播放」：有地址直接甩给外部播放器；没地址（收藏
/// 条目常见）则跳详情页并自动弹「选择集数 · 外部播放」，让用户选完即播。
Future<void> openRecordExternally(BuildContext context, RecordItem item) async {
  if (item.url.isNotEmpty) {
    final config = context.read<AppState>().config;
    final status = await SystemControl.openWithExternalPlayer(
      url: item.url,
      title: item.name,
      customPath: config.externalPlayerPath,
      package: config.externalPlayerPackage,
    );
    if (!context.mounted) return;
    switch (status) {
      case 'no_app':
        showToast(context, '没找到能播放该地址的播放器', success: false);
      case 'no_player':
        showToast(context, '所选播放器打不开该地址，请到设置重新选择', success: false);
      case 'no_url':
        showToast(context, '没有可播放的地址', success: false);
      case 'error':
        showToast(context, '调起外部播放失败', success: false);
      default:
        break;
    }
    return;
  }
  // 没有播放地址：回详情页重新取选集列表并直接弹外部播放选集
  final parts = context.read<AppState>().resolveRecordKey(item.key);
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DetailPage(
        siteKey: parts[0],
        videoId: parts[1],
        autoExternal: true,
      ),
    ),
  );
}

/// 从收藏 / 历史条目打开详情页（普通入口）。
void openRecordDetail(BuildContext context, RecordItem item) {
  final parts = context.read<AppState>().resolveRecordKey(item.key);
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DetailPage(siteKey: parts[0], videoId: parts[1]),
    ),
  );
}

/// 收藏 / 历史卡片「查看详情」用的公共对话框。
///
/// 记录里其实存了完整元数据（片名、封面、类型、年份、地区、语言、导演、
/// 演员、简介）以及播放信息（最近集名、地址、进度、写入时间），但列表卡片
/// 只显示冰山一角。这里把已存的信息一次摊开，重点是把**完整播放链接**给出
/// 来并能一键复制 —— 收藏条目通常没存地址，那种情况下明确提示去选集。
///
/// 三个入口（独立收藏页 / 独立历史页 / 合并页两个 Tab）共用这一个组件，
/// 避免同一份布局复制三遍。外部播放与打开详情由调用方传回调，因为它们要
/// 用到页面自己的 Navigator。
Future<void> showRecordDetailDialog({
  required BuildContext context,
  required RecordItem item,
  required VoidCallback onExternalPlay,
  required VoidCallback onOpenDetail,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RecordDetailDialog(
      item: item,
      onExternalPlay: onExternalPlay,
      onOpenDetail: onOpenDetail,
    ),
  );
}

class _RecordDetailDialog extends StatelessWidget {
  final RecordItem item;
  final VoidCallback onExternalPlay;
  final VoidCallback onOpenDetail;

  const _RecordDetailDialog({
    required this.item,
    required this.onExternalPlay,
    required this.onOpenDetail,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subColor =
        isDark ? AppColors.darkSubText : AppColors.lightSubText;
    // 站点名从 key 拆出 siteKey 再反查；源被删掉时 site 为 null，不显示这一行
    final parts = context.read<AppState>().resolveRecordKey(item.key);
    final site = context.read<AppState>().siteOf(parts[0]);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('查看详情',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _buildHead(context, subColor, site?.name ?? '', isDark),
                const SizedBox(height: 12),
                _buildMeta(context, subColor),
                const SizedBox(height: 10),
                _buildPlayInfo(context, subColor, isDark),
                const SizedBox(height: 14),
                _buildActions(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHead(
      BuildContext context, Color subColor, String siteName, bool isDark) {
    final name = item.name.isNotEmpty ? item.name : '未命名影片';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: item.pic.isEmpty
              ? Container(
                  width: 56,
                  height: 78,
                  color: isDark ? AppColors.darkSurface : AppColors.lightBg,
                  alignment: Alignment.center,
                  child: Icon(Icons.movie_outlined,
                      size: 26, color: AppColors.darkCoverIcon),
                )
              : CachedNetworkImage(
                  imageUrl: item.pic,
                  cacheManager: AppImageCache.instance,
                  width: 56,
                  height: 78,
                  fit: BoxFit.cover,
                  memCacheWidth: 240,
                  placeholder: (_, __) => Container(
                    width: 56,
                    height: 78,
                    color: isDark ? AppColors.darkSurface : AppColors.lightBg,
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 56,
                    height: 78,
                    color: isDark ? AppColors.darkSurface : AppColors.lightBg,
                    alignment: Alignment.center,
                    child: Icon(Icons.broken_image_outlined,
                        size: 22, color: AppColors.darkCoverIcon),
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              if (siteName.isNotEmpty)
                Text('来源：$siteName',
                    style: TextStyle(fontSize: 12, color: subColor)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMeta(BuildContext context, Color subColor) {
    final meta = <String>[
      if (item.type.isNotEmpty) item.type,
      if (item.year.isNotEmpty) item.year,
      if (item.area.isNotEmpty) item.area,
      if (item.lang.isNotEmpty) item.lang,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (meta.isNotEmpty)
          Text(meta.join(' · '), style: TextStyle(fontSize: 12, color: subColor)),
        if (item.director.isNotEmpty || item.actor.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            [
              if (item.director.isNotEmpty) '导演 ${item.director}',
              if (item.actor.isNotEmpty) '主演 ${item.actor}',
            ].join('    '),
            style: TextStyle(fontSize: 12, color: subColor),
          ),
        ],
        if (item.des.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            item.des,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: subColor, height: 1.5),
          ),
        ],
      ],
    );
  }

  Widget _buildPlayInfo(BuildContext context, Color subColor, bool isDark) {
    final total = item.duration;
    final progress = total > 0
        ? '${_fmtTime(item.currentTime)} / ${_fmtTime(total)}'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 10),
        Text('播放信息',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (item.label.isNotEmpty)
          _infoRow('最近观看', item.label, subColor),
        if (progress.isNotEmpty)
          _infoRow('播放进度', progress, subColor),
        if (item.ts > 0)
          _infoRow('记录时间', _fmtTs(item.ts), subColor),
        const SizedBox(height: 8),
        Text('播放链接', style: TextStyle(fontSize: 12, color: subColor)),
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightBg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: item.url.isEmpty
              ? Text('这条记录没有保存播放地址，可在详情页选集后播放',
                  style: TextStyle(fontSize: 12, color: subColor))
              : Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: () => _copy(context, item.url, '播放链接'),
                      child: const Text('复制'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value, Color subColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 60, child: Text(label, style: TextStyle(fontSize: 12, color: subColor))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  /// 跳转类按钮先关掉本对话框再执行回调，否则新页面 push 上去后
  /// 对话框还压在最上层，按一次返回才看得到新页面。
  void _closeThen(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  Widget _buildActions(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        OutlinedButton.icon(
          onPressed: () => _copy(context, item.name.trim(), '影片名称'),
          icon: const Icon(Icons.copy_all_outlined, size: 16),
          label: const Text('复制片名'),
        ),
        OutlinedButton.icon(
          onPressed: () => _closeThen(context, onExternalPlay),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('外部播放'),
        ),
        OutlinedButton.icon(
          onPressed: () => _closeThen(context, onOpenDetail),
          icon: const Icon(Icons.info_outline, size: 16),
          label: const Text('打开详情'),
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context, String text, String what) async {
    if (text.isEmpty) {
      showToast(context, '没有可复制的$what', success: false);
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.mediumImpact();
    if (context.mounted) showToast(context, '已复制$what：$text');
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _fmtTime(double seconds) {
    final s = math.max(0, seconds).round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return h > 0
        ? '${_two(h)}:${_two(m)}:${_two(sec)}'
        : '${_two(m)}:${_two(sec)}';
  }

  static String _fmtTs(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} '
        '${_two(dt.hour)}:${_two(dt.minute)}';
  }
}
