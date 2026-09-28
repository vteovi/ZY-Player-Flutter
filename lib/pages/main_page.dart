import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../utils/toast.dart';
import 'film_page.dart';
import 'me_page.dart';
import 'star_page.dart';

/// 底部导航：首页 / 收藏 / 设置
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _index = 0;
  final _filmKey = GlobalKey<FilmPageState>();

  /// 首页「连按两次返回」的上一次时间点，null = 还没按过。
  /// 一旦离开首页就清空，避免在别的页按过之后回首页立刻被判定成第二次。
  DateTime? _lastBackAt;

  /// 两次返回的间隔上限，超过就重新提示
  static const Duration _exitWindow = Duration(seconds: 2);

  void _onTap(int index) {
    _lastBackAt = null;
    if (index == _index) return;
    setState(() => _index = index);
    if (index == 0) {
      // 视频源或青少年模式可能被改动过，按需刷新首页
      _filmKey.currentState?.reloadIfNeeded();
    } else {
      context.read<AppState>().refresh();
    }
  }

  /// 系统返回键（只在 MainPage 处于栈顶时才会走到这里 —— 详情/播放/源管理
  /// 这些页面压在它上面时，返回由那些页面自己处理）：
  /// - 不在首页 → 切回首页，不退出应用
  /// - 已在首页 → 2 秒内再按一次才真正退出，否则只提示
  void _onBackPressed() {
    if (_index != 0) {
      _onTap(0);
      return;
    }
    final now = DateTime.now();
    final last = _lastBackAt;
    if (last == null || now.difference(last) > _exitWindow) {
      _lastBackAt = now;
      showToast(context, '再按一次返回退出');
      return;
    }
    SystemNavigator.pop();
  }

  /// 宽屏（平板 / 桌面）阈值：超过则用左侧导航栏，否则底部导航
  static const double _wideThreshold = 600;

  List<NavigationRailDestination> get _railDestinations => const [
        NavigationRailDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: Text('首页'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.star_border),
          selectedIcon: Icon(Icons.star),
          label: Text('收藏'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('设置'),
        ),
      ];

  List<BottomNavigationBarItem> get _barItems => const [
        BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined), label: '首页'),
        BottomNavigationBarItem(icon: Icon(Icons.star_border), label: '收藏'),
        BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined), label: '设置'),
      ];

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= _wideThreshold;
    final body = IndexedStack(
      index: _index,
      children: [
        FilmPage(key: _filmKey),
        const StarPage(),
        const MePage(),
      ],
    );
    return PopScope(
      // 根路由始终拦下系统返回，改由 `_onBackPressed` 决定是切回首页还是退出
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _onBackPressed();
      },
      child: Scaffold(
        body: isWide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: _onTap,
                    labelType: NavigationRailLabelType.all,
                    destinations: _railDestinations,
                  ),
                  const VerticalDivider(thickness: 1, width: 1),
                  Expanded(child: body),
                ],
              )
            : body,
        bottomNavigationBar: isWide
            ? null
            : BottomNavigationBar(
                currentIndex: _index,
                onTap: _onTap,
                items: _barItems,
              ),
      ),
    );
  }
}
