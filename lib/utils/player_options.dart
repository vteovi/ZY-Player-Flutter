import 'package:flutter/widgets.dart';

/// 画面比例选项。
///
/// [ratio] 为 null 表示「自适应」，即跟随视频自身的原始比例。
class AspectOption {
  /// 存库用的 key
  final String key;

  /// 按钮上显示的文字
  final String label;

  /// 目标宽高比，null = 自适应
  final double? ratio;

  const AspectOption(this.key, this.label, this.ratio);
}

/// 画面大小（填充方式）选项，映射到 [BoxFit]。
class ScaleOption {
  final String key;

  /// 按钮上显示的文字
  final String label;

  /// 交给 FittedBox 的适配方式
  final BoxFit fit;

  /// 展开面板里的一句说明
  final String desc;

  const ScaleOption(this.key, this.label, this.fit, this.desc);
}

/// 常见画面比例。含横屏（16:9 / 16:10 / 21:9）、方形（1:1）
/// 与手机竖屏（9:16 / 10:16），以及用户自定义比例。
class PlayerAspects {
  PlayerAspects._();

  /// 自定义比例的存库 key。实际比例另存在 `AppConfig.playerCustomAspect`。
  static const String customKey = 'custom';

  /// 自定义比例的取值范围：1:5 ~ 5:1，超出基本不是正常视频画面
  static const double minRatio = 0.2;
  static const double maxRatio = 5.0;

  static const List<AspectOption> all = <AspectOption>[
    AspectOption('auto', '自适应', null),
    AspectOption('16:9', '16:9', 16 / 9),
    AspectOption('16:10', '16:10', 16 / 10),
    AspectOption('4:3', '4:3', 4 / 3),
    AspectOption('1:1', '1:1', 1),
    AspectOption('3:4', '3:4', 3 / 4),
    AspectOption('9:16', '9:16', 9 / 16),
    AspectOption('10:16', '10:16', 10 / 16),
    AspectOption('21:9', '21:9', 21 / 9),
  ];

  static bool isValidRatio(double ratio) =>
      ratio.isFinite && ratio >= minRatio && ratio <= maxRatio;

  /// 解析用户输入：支持 `21:9`、`2.35:1`、`2.35`（全角冒号也兼容）。
  /// 无效或超出范围返回 null。
  static double? parseRatio(String raw) {
    final parts = parseParts(raw);
    if (parts == null) return null;
    final ratio = parts.$1 / parts.$2;
    return isValidRatio(ratio) ? ratio : null;
  }

  /// 解析成 (宽, 高) 两段，供编辑对话框回填；无效返回 null。
  static (double, double)? parseParts(String raw) {
    final s = raw.trim().replaceAll('：', ':');
    if (s.isEmpty) return null;
    if (s.contains(':')) {
      final p = s.split(':');
      if (p.length != 2) return null;
      final w = double.tryParse(p[0].trim());
      final h = double.tryParse(p[1].trim());
      if (w == null || h == null || w <= 0 || h <= 0) return null;
      return (w, h);
    }
    final r = double.tryParse(s);
    if (r == null || r <= 0) return null;
    return (r, 1);
  }

  /// 由比例生成自定义选项。
  /// [label] 传入用户原始输入（如 `21:9`），不传则按比例反推最简形式。
  static AspectOption custom(double ratio, {String? label}) =>
      AspectOption(customKey, label ?? labelOf(ratio), ratio);

  /// 比例转标签：优先化成小整数比（21/9 → 21:9），实在化不整就保留两位小数。
  static String labelOf(double ratio) {
    for (var h = 1; h <= 16; h++) {
      final w = ratio * h;
      final rounded = w.roundToDouble();
      if (rounded > 0 && (w - rounded).abs() < 0.0005) {
        var wi = rounded.toInt();
        var hi = h;
        final g = _gcd(wi, hi);
        return '${wi ~/ g}:${hi ~/ g}';
      }
    }
    final s = ratio.toStringAsFixed(2);
    return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
  }

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  /// 按 key 取选项。key 为 [customKey] 时必须带有效比例，否则退回「自适应」。
  /// [customLabel] 是存库的原始比例文本（如 `21:9`），用于保持用户输入的样子。
  static AspectOption byKey(
    String? key, {
    double? customRatio,
    String? customLabel,
  }) {
    if (key == customKey && customRatio != null && isValidRatio(customRatio)) {
      final label = (customLabel ?? '').trim();
      return custom(customRatio, label: label.isEmpty ? null : label);
    }
    return all.firstWhere(
      (e) => e.key == key,
      orElse: () => all.first,
    );
  }
}

/// 画面大小 / 填充方式。
class PlayerScales {
  PlayerScales._();

  static const List<ScaleOption> all = <ScaleOption>[
    ScaleOption('fit', '适配屏幕', BoxFit.contain, '完整显示整个画面，可能留黑边'),
    ScaleOption('cover', '填充', BoxFit.cover, '铺满整个区域，可能裁掉画面边缘'),
    ScaleOption('fill', '拉伸', BoxFit.fill, '强行拉伸铺满，画面比例会变形'),
    ScaleOption('original', '原始', BoxFit.scaleDown, '按原始尺寸显示，不放大'),
  ];

  static ScaleOption byKey(String? key) => all.firstWhere(
        (e) => e.key == key,
        orElse: () => all.first,
      );
}
