import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pages/main_page.dart';
import 'providers/app_state.dart';
import 'navigator_key.dart';
import 'utils/app_colors.dart';
import 'utils/constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    // Windows 桌面播放：fvp（内置 FFmpeg，支持 HLS/m3u8）实现 video_player
    // 平台接口；仅注册 Windows，Android 仍走 fork 的 ExoPlayer 实现。
    fvp.registerWith(options: {'platforms': ['windows']});
    // 封面缓存（flutter_cache_manager）底层 sqflite 官方无 Windows 实现，
    // 切到 FFI（sqlite3）工厂。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const ZyPlayerApp());
}

class ZyPlayerApp extends StatelessWidget {
  const ZyPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..bootstrap(),
      child: const _AppRoot(),
    );
  }
}

/// 监听配置里的主题模式，实时切换浅色 / 深色 / 跟随系统
class _AppRoot extends StatelessWidget {
  const _AppRoot();

  static const _themeModeMap = {
    'system': ThemeMode.system,
    'light': ThemeMode.light,
    'dark': ThemeMode.dark,
  };

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<AppState>().config.themeMode;
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: _themeModeMap[mode] ?? ThemeMode.system,
      // 直接进主页：原生 LaunchTheme 已是纯色背景（drawable-v21 跟随系统深浅），
      // 去掉 Flutter 层的 logo+转圈开屏，原生背景 → 主页内容 无缝衔接。
      home: const MainPage(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: brightness,
    );
    // 深色模式把 surface 系列一并压到纯黑：M3 的对话框 / 底部弹层 / 菜单 /
    // Chip 等默认都从 colorScheme.surface 取底色，不覆盖的话会从纯黑页面上
    // 冒出一堆灰面板，OLED 上很扎眼。
    // 需要层级的用 surfaceContainerHigh 那一档（极暗灰），或靠描边。
    final scheme = isDark
        ? base.copyWith(
            surface: AppColors.darkBg,
            surfaceContainerLowest: AppColors.darkBg,
            surfaceContainerLow: AppColors.darkBg,
            surfaceContainer: AppColors.darkBg,
            surfaceContainerHigh: AppColors.darkSurface,
            surfaceContainerHighest: AppColors.darkSurface,
            outlineVariant: AppColors.darkOutline,
          )
        : base;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? AppColors.darkBg : AppColors.lightBg,
      dividerColor: isDark ? AppColors.darkDivider : AppColors.lightDivider,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? AppColors.darkBg : Colors.white,
        foregroundColor: isDark ? Colors.white : const Color(0xFF303133),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isDark ? AppColors.darkBg : Colors.white,
        selectedItemColor: isDark ? Colors.white : const Color(0xFF303133),
        unselectedItemColor:
            isDark ? Colors.white70 : const Color(0xFF909399),
        type: BottomNavigationBarType.fixed,
      ),
      cardTheme: CardThemeData(
        color: isDark ? AppColors.darkBg : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? AppColors.darkDivider : AppColors.lightDivider,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? AppColors.darkSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? AppColors.darkSurface : Colors.white,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: isDark ? AppColors.darkSubText : null,
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: isDark ? AppColors.darkDivider : const Color(0xFFEDEDED),
      ),
    );
  }
}
