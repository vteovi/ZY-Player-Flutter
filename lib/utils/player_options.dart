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
/// 与手机竖屏（9:16 / 10:16）。
class PlayerAspects {
  PlayerAspects._();

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

  static AspectOption byKey(String? key) => all.firstWhere(
        (e) => e.key == key,
        orElse: () => all.first,
      );
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
