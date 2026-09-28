import 'package:flutter/services.dart';

/// 播放器的网络统计：全屏时右上角显示的「实时下载速度 / 码率」。
///
/// 数据来自 ExoPlayer 自己的带宽计（`DefaultBandwidthMeter`）与
/// 当前视频轨的 `Format.bitrate`，由 fork 出来的 `video_player_android`
/// 通过一条**独立的** MethodChannel 暴露出来
/// （见插件里的 `VideoPlayerPlugin.NETWORK_STATS_CHANNEL`；没有走 Pigeon 那套
/// 代码生成接口，避免手改生成产物）。
///
/// 拿不到数据（插件没注册通道、播放器已释放、非 Android 平台）时一律返回 null，
/// 由调用方静默降级 —— 这只是一个锦上添花的信息展示，不能影响播放。
class PlayerNetworkStats {
  /// 下载速度估算，bit/s
  final double speedBps;

  /// 当前视频轨码率，bit/s；源没提供时为 0
  final double bitrateBps;

  /// 距上一次带宽采样过了多久（毫秒）。缓冲已满时播放器不再下载，
  /// 这个值会一直涨 —— 说明 [speedBps] 是「上次的速度」而不是此刻的。
  final int idleMs;

  /// 此刻是否真的有网络请求在跑
  final bool active;

  const PlayerNetworkStats({
    required this.speedBps,
    required this.bitrateBps,
    required this.idleMs,
    required this.active,
  });

  /// 速度是否是新鲜的（3 秒内有过采样）
  bool get fresh => idleMs < 3000;

  factory PlayerNetworkStats.fromMap(Map<dynamic, dynamic> map) {
    double toDouble(Object? value) => value is num ? value.toDouble() : 0;
    final idle = map['idleMs'];
    return PlayerNetworkStats(
      speedBps: toDouble(map['speedBps']),
      bitrateBps: toDouble(map['bitrateBps']),
      idleMs: idle is num ? idle.toInt() : 1 << 30,
      active: map['active'] == true,
    );
  }
}

/// 查询播放器网络统计的入口（静态方法，无需实例）
class VideoNetworkStats {
  VideoNetworkStats._();

  static const MethodChannel _channel =
      MethodChannel('com.zy.player/video_network_stats');

  /// 查询某个播放器的网络统计，拿不到返回 null。
  ///
  /// [playerId] 传 `VideoPlayerController.playerId`：texture 路径下插件
  /// （`AndroidVideoPlayer.create`）返回给 Dart 的就是它自己的 playerId，
  /// 所以能直接对上 `VideoPlayerPlugin.videoPlayers` 里的实例。
  static Future<PlayerNetworkStats?> get(int playerId) async {
    if (playerId < 0) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getNetworkStats',
        <String, dynamic>{'playerId': playerId},
      );
      if (result == null) return null;
      return PlayerNetworkStats.fromMap(result);
    } catch (_) {
      // 通道没注册 / 播放器已释放：静默降级
      return null;
    }
  }

  /// bit/s → 「2.35 MB/s」这类速度文本
  static String formatSpeed(double bps) {
    if (bps <= 0) return '0 KB/s';
    final bytes = bps / 8;
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB/s';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytes.toStringAsFixed(0)} B/s';
  }

  /// bit/s → 「1.80 Mbps」这类码率文本
  static String formatBitrate(double bps) {
    if (bps <= 0) return '—';
    if (bps >= 1000 * 1000) {
      return '${(bps / 1000 / 1000).toStringAsFixed(2)} Mbps';
    }
    return '${(bps / 1000).toStringAsFixed(0)} Kbps';
  }
}
