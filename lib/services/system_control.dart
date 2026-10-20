import 'dart:io';

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
  /// [customPath] 是用户在设置里指定的播放器可执行文件路径（Windows 专属）。
  /// 非空且文件存在时优先用它启动；为空则走自动查找（Windows）/ 系统选择器（Android）。
  ///
  /// 走自写通道而不引 `url_launcher`：后者是「浏览器式」的 ACTION_VIEW，
  /// m3u8 直链在多数机型上只会弹浏览器，用户要的是「选播放器」。
  static Future<String> openWithExternalPlayer({
    required String url,
    String title = '',
    String? customPath,
  }) async {
    if (url.isEmpty) return 'no_url';
    if (Platform.isWindows) {
      return _openExternalWindows(url, customPath: customPath);
    }
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

  /// Windows 上常见的视频播放器可执行文件名与固定安装路径。
  /// 源地址多是 m3u8，浏览器播不了，所以优先找真正的播放器。
  static const List<String> _winPlayerExes = [
    'PotPlayerMini64.exe',
    'PotPlayerMini.exe',
    'vlc.exe',
    'mpv.exe',
    'mpc-hc64.exe',
    'mpc-hc.exe',
  ];

  static const List<String> _winPlayerFixedPaths = [
    r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
    r'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini64.exe',
    r'C:\Program Files\VideoLAN\VLC\vlc.exe',
    r'C:\Program Files (x86)\VideoLAN\VLC\vlc.exe',
  ];

  /// Windows：①用户指定的播放器路径优先（文件存在时）；②注册表 App Paths / 固定路径
  /// 找已装播放器，直接带 URL 启动；③找不到就 explorer 交给系统默认关联
  /// （没有关联时系统自己弹「打开方式」）。
  ///
  /// [customPath] 非空且文件存在时，直接启动它并带上 [url]；启动失败直接返回
  /// `error`（用户明确选了某个播放器，不应再静默回退到别的）。
  /// 若指定的文件不存在，则忽略该设置、继续走自动查找。
  static Future<String> _openExternalWindows(
    String url, {
    String? customPath,
  }) async {
    if (customPath != null && customPath.trim().isNotEmpty) {
      final path = customPath.trim();
      if (File(path).existsSync()) {
        try {
          await Process.start(path, [url], mode: ProcessStartMode.detached);
          return 'ok';
        } catch (_) {
          return 'error';
        }
      }
      // 指定了但文件不存在：忽略该设置，继续走下面的自动查找
    }
    for (final exe in _winPlayerExes) {
      final path = await _resolveAppPath(exe);
      if (path == null) continue;
      try {
        await Process.start(path, [url], mode: ProcessStartMode.detached);
        return 'ok';
      } catch (_) {
        // 注册表里的路径可能已失效，继续试下一个
      }
    }
    for (final path in _winPlayerFixedPaths) {
      if (!File(path).existsSync()) continue;
      try {
        await Process.start(path, [url], mode: ProcessStartMode.detached);
        return 'ok';
      } catch (_) {
        // 文件可能存在但启动失败，继续
      }
    }
    try {
      await Process.start('explorer.exe', [url],
          mode: ProcessStartMode.detached);
      return 'ok';
    } catch (_) {
      return 'error';
    }
  }

  /// 在注册表 App Paths（HKLM + HKCU）里查 [exe] 的真实安装路径。
  static Future<String?> _resolveAppPath(String exe) async {
    const roots = [
      r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
      r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
    ];
    for (final root in roots) {
      try {
        final result = await Process.run(
          'reg',
          ['query', '$root\\$exe', '/ve'],
          // reg.exe 输出用的是系统 OEM 代码页（中文系统 = GBK），用 systemEncoding 解
          stdoutEncoding: systemEncoding,
        ).timeout(const Duration(seconds: 3));
        if (result.exitCode != 0) continue;
        final match =
            RegExp(r'REG_SZ\s+(.+\.exe)', caseSensitive: false)
                .firstMatch(result.stdout.toString());
        if (match == null) continue;
        // App Paths 的默认值可能带引号存储（如 "C:\My Program\PotPlayer\...exe"）
        final path =
            match.group(1)!.trim().replaceAll('"', '').trim();
        if (path.isEmpty || !File(path).existsSync()) continue;
        return path;
      } catch (_) {
        // reg 不可用 / 超时：忽略，继续查下一个根
      }
    }
    return null;
  }

  /// 播放时保持屏幕常亮。开启会给当前窗口加 FLAG_KEEP_SCREEN_ON，
  /// 关闭（暂停 / 退出播放页）则清掉。失败静默降级。
  static Future<void> setKeepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod<void>(
        'setKeepScreenOn',
        <String, dynamic>{'value': on},
      );
    } catch (_) {
      // 忽略
    }
  }

  /// 强制使用软件解码器播放（仅 Android 生效）。
  ///
  /// 设置后写到原生静态开关 `PlaybackConfig.forceSoftwareDecode`，ExoPlayer
  /// 下次构建时按它选择「软件优先」的 MediaCodecSelector。用于兼容部分机型
  /// 硬解 H.264 High Profile/1080p 抛 MediaCodecVideoRenderer error 的情况。
  /// 失败静默降级——通道异常不应影响播放。
  static Future<void> setForceSoftwareDecode(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(
        'setForceSoftwareDecode',
        <String, dynamic>{'value': on},
      );
    } catch (_) {
      // 忽略
    }
  }

  static double _clamp(double value) {
    if (value.isNaN) return 0;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }
}
