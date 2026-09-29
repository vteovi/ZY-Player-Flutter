import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pages/main_page.dart';
import 'providers/app_state.dart';
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
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: _themeModeMap[mode] ?? ThemeMode.system,
      home: const AppBootstrap(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    const seed = Color(0xFF1E88E5);
    final colorScheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF8F8F8),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        foregroundColor: isDark ? Colors.white : const Color(0xFF303133),
        surfaceTintColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        selectedItemColor: isDark ? Colors.white : const Color(0xFF303133),
        unselectedItemColor:
            isDark ? Colors.white70 : const Color(0xFF909399),
        type: BottomNavigationBarType.fixed,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        surfaceTintColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      ),
    );
  }
}

/// 启动页：等待本地数据库初始化完成
class AppBootstrap extends StatelessWidget {
  const AppBootstrap({super.key});

  @override
  Widget build(BuildContext context) {
    final ready = context.select<AppState, bool>((s) => s.ready);
    if (!ready) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image(image: AssetImage('assets/images/logo.png'), width: 120),
              SizedBox(height: 24),
              CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }
    return const MainPage();
  }
}
