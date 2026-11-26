import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../pages/detail_page.dart';
import '../providers/app_state.dart';
import '../services/system_control.dart';
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
