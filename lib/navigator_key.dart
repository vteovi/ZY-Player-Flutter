import 'package:flutter/material.dart';

/// 全局导航键。
///
/// 「应用内小窗」悬浮时播放页会被 pop，小窗（OverlayEntry）里的「点开续播」
/// 需要跨路由重新 push 一个播放页，而那时原播放页的 context 已失效，
/// 所以统一走这个根导航键来跳转。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
