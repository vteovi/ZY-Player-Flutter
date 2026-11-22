import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/app_colors.dart';
import '../utils/toast.dart';
import 'film_page.dart';
import 'me_page.dart';
import 'site_page.dart';
import 'star_page.dart';
import 'sync_page.dart';

/// 底部导航：首页 / 收藏 / 设置
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _index = 0;
  final _filmKey = GlobalKey<FilmPageState>();

  /// 收藏 / 历史两页的横向容器。首页与设置页都不参与滑动 ——
  /// 首页内部已有分类 TabBarView（会抢横向手势），设置页是一屏纵向列表，
  /// 跟着滑过去既没有意义、又多一份拖动时的绘制开销。
  final _pageController = PageController();

  /// 首页在导航里的下标；收藏/历史对应 PageView 的 index + 1。
  static const int _homeIndex = 0;
  static const int _starsIndex = 1;
  static const int _historyIndex = 2;
  static const int _settingsIndex = 3;

  /// 设置页是否已经建过。IndexedStack 会把所有子节点一次性建出来，
  /// 设置页有近千行、还带文件选择器等重组件，没必要开机就付这份钱，
  /// 首次点进设置时才构建，之后常驻保活。
  bool _settingsBuilt = false;

  /// 首页「连按两次返回」的上一次时间点，null = 还没按过。
  /// 一旦离开首页就清空，避免在别的页按过之后回首页立刻被判定成第二次。
  DateTime? _lastBackAt;

  /// 两次返回的间隔上限，超过就重新提示
  static const Duration _exitWindow = Duration(seconds: 2);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTap(int index) {
    _lastBackAt = null;
    if (index == _index) return;
    setState(() {
      _index = index;
      if (index == _settingsIndex) _settingsBuilt = true;
    });
    if (index == _homeIndex) {
      // 视频源可能被改动过，按需刷新首页
      _filmKey.currentState?.reloadIfNeeded();
    } else {
      _syncPageTo(index);
    }
    // 这里**不要**调 AppState.refresh()：它会重新读 4 张表、还会走一次原生
    // 通道（setForceSoftwareDecode），并连发 5 次 notifyListeners。收藏/历史
    // 在增删时就已经内存内更新并 notify 过，切页时再全量重载纯属白做，
    // 而且正好压在翻页动画那几帧上，滑动手感直接变卡。
  }

  /// 点导航切到某一页时把 PageView 拨过去。
  ///
  /// 只有收藏 / 历史在 PageView 里，首页与设置直接由 IndexedStack 切换。
  /// PageView 挂在 IndexedStack 里，从首页切过来时它这一帧才刚被布局，
  /// 直接 jump 可能还没有 viewport，所以放到下一帧再做。
  void _syncPageTo(int index) {
    if (index != _starsIndex && index != _historyIndex) return;
    final target = index - 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      final current = _pageController.page?.round();
      if (current == target) return;
      _pageController.jumpToPage(target);
    });
  }

  /// 左右滑动切页：反向同步底部导航的高亮。
  ///
  /// 只改选中项，不做数据刷新 —— 理由同 `_onTap`：翻页动画期间重载数据会掉帧。
  void _onPageChanged(int page) {
    final index = _starsIndex + page;
    if (index == _index) return;
    _lastBackAt = null;
    setState(() => _index = index);
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

  /// 导航选中态的胶囊底色：深色下用一档「不发光的暗蓝」，浅色下用淡蓝。
  /// 纯黑主题里不能靠提亮底色，选中感主要来自这块底色 + 加粗文字。
  static const Color _railIndicatorDark = Color(0xFF12314F);
  static const Color _railIndicatorLight = Color(0xFFE3F0FC);

  /// 未选中图标 / 文字的灰（与浅色模式原有配色一致）
  static const Color _railUnselected = Color(0xFF909399);

  /// 四个主导航项：首页 / 收藏 / 历史 / 设置。
  ///
  /// 底部 NavigationBar 与宽屏 NavigationRail 共用同一份定义，避免两边顺序
  /// 或文案不一致。选中态的胶囊底色、加粗标签在主题里配（`navigationBarTheme`），
  /// Rail 这边单独给 `indicatorColor` 与文字样式。
  static const List<NavigationDestination> _destinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: '首页',
    ),
    NavigationDestination(
      icon: Icon(Icons.star_border_rounded),
      selectedIcon: Icon(Icons.star_rounded),
      label: '收藏',
    ),
    NavigationDestination(
      icon: Icon(Icons.history_rounded),
      selectedIcon: Icon(Icons.history_rounded),
      label: '历史',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: '设置',
    ),
  ];

  /// NavigationRail 用同一份 destination（两者类型一致）
  List<NavigationRailDestination> get _railDestinations =>
      _destinations.map((d) {
        return NavigationRailDestination(
          icon: d.icon,
          selectedIcon: d.selectedIcon ?? d.icon,
          label: Text(d.label),
        );
      }).toList();

  /// 大屏（平板 / 桌面）左侧导航栏的快捷入口：视频源管理 + 设备同步。
  ///
  /// 这两项不属于底部 Tab，点了直接 push 对应页面（与设置页里的入口一致），
  /// `selectedIndex` 不变，返回后仍停在原来的分栏。
  Widget _buildRailShortcuts() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(height: 1, indent: 18, endIndent: 18),
        ),
        _RailShortcut(
          icon: Icons.dns_outlined,
          label: '源管理',
          tooltip: '视频源管理',
          onTap: () => _push(const SitePage()),
        ),
        const SizedBox(height: 2),
        _RailShortcut(
          icon: Icons.sync_alt_rounded,
          label: '设备同步',
          tooltip: '设备同步',
          onTap: () => _push(const SyncPage()),
        ),
      ],
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= _wideThreshold;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 三块内容：首页 / 收藏·历史（唯一可横滑的容器）/ 设置。
    // 用下标常量映射，别直接用导航下标 —— 导航有 4 项，IndexedStack 只有 3 块。
    final int stackIndex;
    if (_index == _homeIndex) {
      stackIndex = 0;
    } else if (_index == _settingsIndex) {
      stackIndex = 2;
    } else {
      stackIndex = 1;
    }
    final body = IndexedStack(
      index: stackIndex,
      children: [
        // IndexedStack 只是「不绘制」未选中的子树，里面的 Ticker 照样在跑。
        // 首页的骨架屏是 repeat(reverse) 的呼吸动画、加载条是 indeterminate，
        // 停在收藏/历史页时它们仍在每帧驱动重绘，滑动手势就会掉帧。
        // 用 TickerMode 把离开首页时的动画真正停掉。
        TickerMode(
          enabled: _index == _homeIndex,
          child: RepaintBoundary(child: FilmPage(key: _filmKey)),
        ),
        // 只有收藏 / 历史两页参与横滑。设置页是纵向长列表，跟着滑过去没有意义，
        // 而且拖动时多一页全屏绘制，低端机上那点余量就没了。
        PageView(
          controller: _pageController,
          onPageChanged: _onPageChanged,
          children: const [
            RepaintBoundary(child: _KeepAlive(child: StarPage(only: 0))),
            RepaintBoundary(child: _KeepAlive(child: StarPage(only: 1))),
          ],
        ),
        // 首次点进设置页才构建
        _settingsBuilt
            ? const RepaintBoundary(child: MePage())
            : const SizedBox.shrink(),
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
                    indicatorColor:
                        isDark ? _railIndicatorDark : _railIndicatorLight,
                    selectedIconTheme: IconThemeData(
                      size: 26,
                      color: isDark ? Colors.white : AppColors.brand,
                    ),
                    unselectedIconTheme: IconThemeData(
                      size: 24,
                      color: isDark ? Colors.white54 : _railUnselected,
                    ),
                    selectedLabelTextStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : AppColors.brand,
                    ),
                    unselectedLabelTextStyle: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : _railUnselected,
                    ),
                    destinations: _railDestinations,
                    trailing: _buildRailShortcuts(),
                  ),
                  const VerticalDivider(thickness: 1, width: 1),
                  Expanded(child: body),
                ],
              )
            : body,
        bottomNavigationBar: isWide
            ? null
            : NavigationBar(
                selectedIndex: _index,
                onDestinationSelected: _onTap,
                destinations: _destinations,
              ),
      ),
    );
  }
}

/// 给 PageView 的子页保活：滑走再滑回来时列表滚动位置、展开状态都还在。
///
/// PageView 默认只给实现了 `AutomaticKeepAliveClientMixin` 的子页保活，
/// StarPage / MePage 不涉及这个 mixin，不包一层每次切页都会重建。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 大屏导航栏里的快捷入口按钮：图标 + 小字，风格对齐 `NavigationRailDestination`
/// （图标在上、文字在下、整块可点），但点击只 push 页面、不改变选中项。
class _RailShortcut extends StatelessWidget {
  const _RailShortcut({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip ?? label,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
