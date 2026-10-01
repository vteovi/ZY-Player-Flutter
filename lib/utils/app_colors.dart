import 'package:flutter/material.dart';

/// 全局配色常量。
///
/// 深色模式以 **OLED 友好**为第一原则：页面、卡片、导航栏、AppBar 一律用
/// **纯黑 `#000000`** —— OLED 屏上这些像素完全不发光，最省电也最"黑"。
///
/// ⚠️ 需要区分层级时**不要靠"把底色提亮"**，改用 [darkOutline] 描边：
/// 描边只占极少像素，整体依然黑得下去；一提亮底色整屏就"发灰"了。
/// （例外：[darkSurface] 用于必须与纯黑底色分开的小元素，
/// 以及骨架屏 —— 骨架屏本来就是靠色块可见来表达"正在加载"。）
class AppColors {
  AppColors._();

  /// 品牌蓝（浅色模式的强调色）
  static const Color brand = Color(0xFF1E88E5);

  // -------------------------------------------------------------------------
  // 深色（纯黑体系）
  // -------------------------------------------------------------------------

  /// 页面 / 卡片 / 导航栏 / AppBar 底色 —— 真纯黑
  static const Color darkBg = Color(0xFF000000);

  /// 极暗抬升面：只用在"必须和纯黑底分开"的小元素上
  /// （封面占位、输入框、圆形按钮、底部弹层）。仍接近不发光。
  static const Color darkSurface = Color(0xFF0D0D0D);

  /// 分隔线 / 描边式的分区线
  static const Color darkDivider = Color(0xFF1F1F1F);

  /// 纯黑下的描边色（替代"提亮底色"来区分边界）
  static const Color darkOutline = Color(0x24FFFFFF);

  /// 次要文字 / 图标
  static const Color darkSubText = Color(0xFF9CA0A6);

  /// 骨架屏呼吸区间 —— 必须看得见，不能纯黑
  static const Color darkSkeletonLow = Color(0xFF141416);
  static const Color darkSkeletonHigh = Color(0xFF232327);

  /// 卡片上没有封面时的占位图标
  static const Color darkCoverIcon = Color(0xFF4A4A4E);

  // -------------------------------------------------------------------------
  // 浅色
  // -------------------------------------------------------------------------

  static const Color lightBg = Color(0xFFF8F8F8);
  static const Color lightSurface = Colors.white;
  static const Color lightDivider = Color(0xFFEDEDED);
  static const Color lightOutline = Color(0xFFEDEDED);
  static const Color lightSubText = Color(0xFF909399);
  static const Color lightSkeletonLow = Color(0xFFE7EAEE);
  static const Color lightSkeletonHigh = Color(0xFFF3F5F8);

  // -------------------------------------------------------------------------
  // 可用性检测语义色（深色下要够亮，浅色下要够深）
  // -------------------------------------------------------------------------

  static const Color okDark = Color(0xFF4ED08A);
  static const Color okLight = Color(0xFF158F63);
  static const Color warnDark = Color(0xFFE3A94A);
  static const Color warnLight = Color(0xFF9A6510);
  static const Color failDark = Color(0xFFE4736F);
  static const Color failLight = Color(0xFFC93A34);
  static const Color idleDark = Color(0xFF6E6E73);
  static const Color idleLight = Color(0xFFB4B8BE);
}
