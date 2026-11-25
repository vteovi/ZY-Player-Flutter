import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../utils/toast.dart';
import 'film_page.dart';
import 'history_page.dart';
import 'me_page.dart';
import 'records_page.dart';
import 'site_page.dart';
import 'star_page.dart';
import 'sync_page.dart';

/// 底部导航。项数由设置项「收藏与历史合并」决定：
/// - 关闭（默认）：首页 / 收藏 / 历史 / 设置，四个独立页面
/// - 开启：首页 / 我的 / 设置，「我的」进去是带两个分栏的合并页
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  /// 逻辑槽位：0 = 首页，1 = 收藏，2 = 历史，3 = 设置。
  ///
  /// 存的不是物理下标 —— 合并模式下没有独立的「历史」项，槽位 2 会落到
  /// 合并页上（与 1 同一页）。这样在设置里拨动开关时，停在「历史」的用户
  /// 不会被弹回首页。
  int _slot = 0;

  final _filmKey = GlobalKey<FilmPageState>();

  /// 首页「连按两次返回」的上一次时间点，null = 还没按过。
  /// 一旦离开首页就清空，避免在别的页按过之后回首页立刻被判定成第二次。
  DateTime? _lastBackAt;

  /// 两次返回的间隔上限，超过就重新提示
  static const Duration _exitWindow = Duration(seconds: 2);

  /// 宽屏（平板 / 桌面）阈值：超过则用左侧导航栏，否则底部导航
  static const double _wideThreshold = 600;

  // --------------------------------------------------------------------------
  // 槽位 ↔ 物理下标
  // --------------------------------------------------------------------------

  /// 物理下标 → 逻辑槽位
  static int _slotOf(int physicalIndex, bool merge) {
    if (physicalIndex == 0) return 0;
    if (merge) {
      // 合并：[首页, 我的, 设置]
      return physicalIndex == 2 ? 3 : 1;
    }
    // 分开：[首页, 收藏, 历史, 设置]
    return physicalIndex;
  }

  /// 逻辑槽位 → 物理下标
  static int _indexOf(int slot, bool merge) {
    if (slot == 0) return 0;
    if (merge) return slot == 3 ? 2 : 1;
    return slot;
  }

  // --------------------------------------------------------------------------
  // 交互
  // --------------------------------------------------------------------------

  void _onTap(int physicalIndex, bool merge) {
    final slot = _slotOf(physicalIndex, merge);
    _lastBackAt = null;
    if (slot == _slot) return;
    setState(() => _slot = slot);
    if (slot == 0) {
      // 视频源可能被改动过，按需刷新首页
      _filmKey.currentState?.reloadIfNeeded();
    } else {
      context.read<AppState>().refresh();
    }
  }

  /// 系统返回键（只在 MainPage 处于栈顶时才会走到这里 —— 详情/播放/源管理
  /// 这些页面压在它上面时，返回由那些页面自己处理）：
  /// - 不在首页 → 切回首页，不退出应用
  /// - 已在首页 → 2 秒内再按一次才真正退出，否则只提示
  void _onBackPressed(bool merge) {
    if (_slot != 0) {
      _onTap(_indexOf(0, merge), merge);
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

  // --------------------------------------------------------------------------
  // 页面与导航项
  // --------------------------------------------------------------------------

  List<Widget> _pages(bool merge) => [
        FilmPage(key: _filmKey),
        if (merge)
          // 从「历史」槽位切到合并模式时，直接落在历史分栏上
          RecordsPage(initialTab: _slot == 2 ? 1 : 0)
        else
          const StarPage(),
        if (!merge) const HistoryPage(),
        const MePage(),
      ];

  List<NavigationRailDestination> _railDestinations(bool merge) => [
        const NavigationRailDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: Text('首页'),
        ),
        if (merge)
          const NavigationRailDestination(
            icon: Icon(Icons.account_circle_outlined),
            selectedIcon: Icon(Icons.account_circle),
            label: Text('我的'),
          )
        else ...[
          const NavigationRailDestination(
            icon: Icon(Icons.star_border),
            selectedIcon: Icon(Icons.star),
            label: Text('收藏'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: Text('历史'),
          ),
        ],
        const NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('设置'),
        ),
      ];

  List<BottomNavigationBarItem> _barItems(bool merge) => [
        const BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined), label: '首页'),
        if (merge)
          const BottomNavigationBarItem(
              icon: Icon(Icons.account_circle_outlined), label: '我的')
        else ...[
          const BottomNavigationBarItem(
              icon: Icon(Icons.star_border), label: '收藏'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.history_outlined), label: '历史'),
        ],
        const BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined), label: '设置'),
      ];

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
    final merge = context.select<AppState, bool>((s) => s.config.mergeRecords);
    final isWide = MediaQuery.of(context).size.width >= _wideThreshold;
    final selected = _indexOf(_slot, merge);
    final body = IndexedStack(
      index: selected,
      children: _pages(merge),
    );
    return PopScope(
      // 根路由始终拦下系统返回，改由 `_onBackPressed` 决定是切回首页还是退出
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _onBackPressed(merge);
      },
      child: Scaffold(
        body: isWide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: selected,
                    onDestinationSelected: (i) => _onTap(i, merge),
                    labelType: NavigationRailLabelType.all,
                    destinations: _railDestinations(merge),
                    trailing: _buildRailShortcuts(),
                  ),
                  const VerticalDivider(thickness: 1, width: 1),
                  Expanded(child: body),
                ],
              )
            : body,
        bottomNavigationBar: isWide
            ? null
            : BottomNavigationBar(
                currentIndex: selected,
                onTap: (i) => _onTap(i, merge),
                items: _barItems(merge),
              ),
      ),
    );
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
