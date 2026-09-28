import 'package:flutter/services.dart';

/// 系统亮度与媒体音量的读写，原生侧（Android）实现。
///
/// - 亮度：改的是当前 Activity 窗口的 `screenBrightness`，**不写系统设置**，
///   退出播放页/应用后自动恢复，这也是各家播放器的通行做法。
/// - 音量：直接调 `AudioManager.STREAM_MUSIC`，与侧边音量键同一通道。
///
/// 所有方法在失败时都静默降级（返回默认值 / 忽略），保证播放页不会因为
/// 原生通道异常而崩掉——比如跑在不支持通道的平台上时。
class SystemControl {
  SystemControl._();

  static const MethodChannel _channel = MethodChannel('com.zy.player/system');

  /// 当前亮度，0.0 ~ 1.0。读不到时返回 0.5。
  static Future<double> brightness() async {
    try {
      final value = await _channel.invokeMethod<double>('getBrightness');
      return _clamp(value ?? 0.5);
    } catch (_) {
      return 0.5;
    }
  }

  static Future<void> setBrightness(double value) async {
    try {
      await _channel.invokeMethod<void>(
        'setBrightness',
        <String, dynamic>{'value': _clamp(value)},
      );
    } catch (_) {
      // 忽略：亮度调不了不应该影响播放
    }
  }

  /// 当前媒体音量，0.0 ~ 1.0。读不到时返回 0.5。
  static Future<double> volume() async {
    try {
      final value = await _channel.invokeMethod<double>('getVolume');
      return _clamp(value ?? 0.5);
    } catch (_) {
      return 0.5;
    }
  }

  static Future<void> setVolume(double value) async {
    try {
      await _channel.invokeMethod<void>(
        'setVolume',
        <String, dynamic>{'value': _clamp(value)},
      );
    } catch (_) {
      // 忽略
    }
  }

  /// Android API 等级（`Build.VERSION.SDK_INT`）。仅用于播放页的诊断信息，
  /// 读不到时返回 0。
  static Future<int> androidSdkInt() async {
    try {
      return await _channel.invokeMethod<int>('getSdkInt') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 调起第三方播放器播放 [url]，返回原生侧给的状态码：
  ///
  /// - `ok`：已经弹出选择器 / 直接进入播放器
  /// - `no_url`：地址为空
  /// - `no_app`：设备上没有能处理这个地址的应用
  /// - `error`：调起过程中抛异常
  ///
  /// 走自写通道而不引 `url_launcher`：后者是「浏览器式」的 ACTION_VIEW，
  /// m3u8 直链在多数机型上只会弹浏览器，用户要的是「选播放器」。
  static Future<String> openWithExternalPlayer({
    required String url,
    String title = '',
  }) async {
    if (url.isEmpty) return 'no_url';
    try {
      final status = await _channel.invokeMethod<String>(
        'openWithExternalPlayer',
        <String, dynamic>{'url': url, 'title': title},
      );
      return status ?? 'error';
    } catch (_) {
      return 'error';
    }
  }

  static double _clamp(double value) {
    if (value.isNaN) return 0;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }
}
