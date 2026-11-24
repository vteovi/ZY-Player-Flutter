import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/boot_snapshot.dart';
import '../services/http_service.dart';
import '../services/list_cache.dart';
import '../utils/app_colors.dart';
import '../utils/image_prefetch.dart';
import '../utils/constants.dart';
import '../widgets/common_widgets.dart';
import '../widgets/video_grid.dart';
import 'detail_page.dart';
import 'search_page.dart';

/// 首页右下角悬浮搜索按钮的直径，以及它需要的额外底部留白。
///
/// 只在小屏（竖屏手机）出现：那里顶栏只剩一个小图标，拇指够不着，
/// 悬浮按钮随手可点；宽屏顶栏本来就有一条完整搜索框，不需要再来一个。
const double _kSearchFabSize = 56;

/// 「回到顶部」小 FAB 的直径（FloatingActionButton.small 固定 40）
const double _kBackTopFabSize = 40;

/// 悬浮搜索按钮相对 Scaffold 默认位置（距底 16）再抬高的距离：
/// 正好让出「回到顶部」那一位，搜索在上、回到顶部在下，两者上下叠着不打架。
const double _kSearchFabLift = _kBackTopFabSize + 12;

/// 网格底部额外留白：从底往上依次是 回到顶部(40) + 间距 + 搜索按钮(56)，
/// 让最后一排（含右下角那张卡）能完整滚到按钮上方，不被压住。
const double _kSearchFabInset = _kSearchFabSize + _kSearchFabLift;

/// 首页：搜索 + 站点切换（顶部）+ 分类左右滑动分栏 + 资源瀑布流
class FilmPage extends StatefulWidget {
  const FilmPage({super.key});

  @override
  State<FilmPage> createState() => FilmPageState();
}

class FilmPageState extends State<FilmPage>
    with
        SingleTickerProviderStateMixin,
        AutomaticKeepAliveClientMixin,
        WidgetsBindingObserver {
  static const _latestClass = VideoClass(tid: '0', name: '最新');

  /// 宽屏阈值（与 MainPage 的 _wideThreshold 一致）：达到后把搜索框并进
  /// AppBar 首行，与站点切换、资源统计同排，省下一整行竖向空间。
  static const double _wideThreshold = 600;

  Site? _site;
  List<VideoClass> _classes = <VideoClass>[_latestClass];

  /// 顶部网站切换旁的「共 X 资源」：按分类 tid 缓存各分类的资源数
  final Map<String, int> _recordCounts = <String, int>{};

  /// 每个分类的「刷新令牌」：+1 就通知对应分栏静默重拉片单。
  /// 只给当前可见分类加，避免一次回到前台就朝源站打十几个并发请求。
  final Map<String, int> _refreshTicks = <String, int>{};

  /// 上次触发（或页面刚建好）的时间。回到前台 / 切回首页时据此判断内容是否偏旧。
  DateTime _lastRefreshAt = DateTime.now();

  /// 内容超过这个时长就认为「旧了」，需要静默刷新一次
  static const Duration _staleAfter = Duration(minutes: 10);

  late TabController _tabController;
  int _lastTabIndex = 0;

  /// 站点 / 分类还在拉取时，整体先转圈（此时分栏还没出来）
  bool _loading = false;

  /// 首屏内容来自 [BootSnapshot]（而不是异步加载完成）。
  ///
  /// 这种状态下 `_site` / `_classes` 已经有值，但 `AppState` 还没 ready ——
  /// bootstrap 完成后要走 [_adoptRealSites] 交接，**不能**走 [reload]
  /// （那会把刚显示出来的内容先换成骨架屏，等于白等一次）。
  bool _usingSnapshot = false;

  /// 快照自带的第一页片单，只喂给「快照里那个分类」用一次。
  ///
  /// 必须连站点 key 一起记：换到别的源之后，同一个 tid 也会命中这份数据，
  /// 那就把 A 站的片单画到 B 站上了。
  Map<String, List<Video>> _bootVideos = <String, List<Video>>{};
  String? _bootSiteKey;

  /// 快照恢复后要选中第几个分类
  int _initialIndex = 0;

  /// 当前选中的分类（跟随 TabBar 的 index）
  VideoClass get _activeClass {
    if (_classes.isEmpty) return _latestClass;
    final i = _tabController.index.clamp(0, _classes.length - 1);
    return _classes[i];
  }

  int get _activeRecordCount => _recordCounts[_activeClass.tid] ?? 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 先吃启动快照：有的话第一帧就有站点、分类栏、片单（封面按索引同步读本地
    // 文件出图），不必先空白一两秒等 bootstrap + 网络往返。
    _applyBootSnapshot();
    _tabController = TabController(
      length: _classes.length,
      vsync: this,
      initialIndex: _initialIndex,
    );
    _tabController.addListener(_onTabChanged);
    _lastTabIndex = _tabController.index;
    // 直接进主页时 sites 可能还没加载完（bootstrap 是异步的），先挂监听：
    // 等源列表就绪（空 → 非空）后自动接手，避免卡在「暂无可用视频源」。
    final state = context.read<AppState>();
    state.addListener(_onAppStateChanged);
    if (_usingSnapshot) {
      // 快照只是「先给你看」，分类栏仍要和源站对一次 —— 静默做，不铺骨架屏
      if (state.activeSites.isEmpty) {
        unawaited(_refreshClassesSilently());
      } else {
        // bootstrap 恰好已经跑完（启动很快时会发生）：直接交接，
        // 别干等一个不会再来的 notify，否则分类栏永远停在快照那一份
        _usingSnapshot = false;
        unawaited(_adoptRealSites(state));
      }
    } else {
      reload();
    }
  }

  /// 从启动快照恢复首屏（站点 / 分类 / 上次停留的位置 + 那一页片单）。
  ///
  /// 只在 [BootSnapshot] 拿到完整结构时生效；否则什么都不做，走原来的加载路径。
  void _applyBootSnapshot() {
    final s = BootSnapshot.site;
    if (s == null || BootSnapshot.classes.isEmpty) return;
    final visible = BootSnapshot.classes
        .where((c) => !AppConstants.hiddenClasses.contains(c.name))
        .where((c) => c.tid != _latestClass.tid)
        .toList();
    if (visible.isEmpty) return;
    _usingSnapshot = true;
    _site = s;
    _bootSiteKey = s.key;
    _classes = <VideoClass>[_latestClass, ...visible];
    final tid = BootSnapshot.activeTid;
    final i = _classes.indexWhere((c) => c.tid == tid);
    _initialIndex = i < 0 ? 0 : i;
    if (tid.isNotEmpty) {
      // 快照里没记到资源数（缓存没有元信息）就留空，别在顶栏显示「· 0 资源」
      if (BootSnapshot.recordCount > 0) {
        _recordCounts[tid] = BootSnapshot.recordCount;
      }
      if (BootSnapshot.videos.isNotEmpty) {
        _bootVideos = <String, List<Video>>{tid: BootSnapshot.videos};
      }
    }
    // 有内容了，不要再挂骨架屏
    _loading = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    context.read<AppState>().removeListener(_onAppStateChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// App 从后台回到前台：片单可能已经放了一整夜没动过，静默刷一次头部页面。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshIfStale();
  }

  /// 内容放了超过 [_staleAfter] 就刷新当前可见分类；否则什么都不做。
  ///
  /// 首页用 IndexedStack 常驻（切到收藏、设置再切回来不会重建），没有这一步的话
  /// 第一屏内容会一直停在「打开 App 那一刻」，看着就像「从来没更新过」。
  void refreshIfStale() {
    if (!mounted || _site == null) return;
    if (DateTime.now().difference(_lastRefreshAt) < _staleAfter) return;
    _lastRefreshAt = DateTime.now();
    final tid = _activeClass.tid;
    setState(() => _refreshTicks[tid] = (_refreshTicks[tid] ?? 0) + 1);
  }

  /// AppState 任意变化（含 sites 加载完成）时尝试按需重载。
  /// [reloadIfNeeded] 内部按源签名比对，签名不变（如只加载了收藏/历史）不会重复拉取。
  void _onAppStateChanged() {
    if (!mounted) return;
    if (_usingSnapshot) {
      // 快照 → 真实源列表的交接：只换站点对象，不铺骨架屏
      final state = context.read<AppState>();
      if (state.activeSites.isEmpty) return;
      _usingSnapshot = false;
      unawaited(_adoptRealSites(state));
      return;
    }
    unawaited(reloadIfNeeded());
  }

  /// bootstrap 完成后接手真实源列表。
  ///
  /// 和 [reload] 的区别：不置 `_loading`（否则刚显示出来的快照内容会先被换成
  /// 骨架屏），也不重建分类栏，只把站点对象换成库里那份（收藏 / 历史要用它的
  /// key），然后静默对一次分类。
  Future<void> _adoptRealSites(AppState state) async {
    final sites = state.activeSites;
    if (sites.isEmpty) return;
    _signature = sites.map((s) => s.key).join(',');
    _lastRefreshAt = DateTime.now();
    final key = _site?.key;
    final keep = key == null
        ? sites.first
        : sites.firstWhere((s) => s.key == key, orElse: () => sites.first);
    if (keep.key != key) {
      // 上次那个源被删掉 / 停用了：只能整页重来（这一次铺骨架屏，没办法）。
      // 先换站点再 reload，顺序不能反 —— 反了会先按新站点渲染一帧旧分类。
      if (mounted) setState(() => _site = keep);
      await reload();
      return;
    }
    if (mounted && !identical(keep, _site)) {
      setState(() => _site = keep);
    }
    await _refreshClassesSilently();
    _saveBootSnapshot();
  }

  void _onTabChanged() {
    if (_tabController.index != _lastTabIndex) {
      _lastTabIndex = _tabController.index;
      // 切换分类后，顶部的「共 X 资源」要跟着当前分类刷新
      if (mounted) setState(() {});
      // 记住停在哪一栏，下次冷启动直接回到这里
      _saveBootSnapshot();
    }
  }

  /// 站点或分类数量变化后，重建 TabController（长度必须和分类数一致）
  ///
  /// [force] = true 时即使长度没变也重建，并把选中分栏重置回 [initialIndex]
  /// （默认 0，即「最新」）—— 换源后新旧站点分类数恰好相同的情况必须靠它兜住，
  /// 否则会停在原来那一栏。
  void _initTabs(int length, {bool force = false, int initialIndex = 0}) {
    if (!force && _tabController.length == length) return;
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    // length 可能是 0（分类被清空），clamp 的上下界会反掉，这里先挡一层
    final index = length <= 0 ? 0 : initialIndex.clamp(0, length - 1);
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: index,
    );
    _tabController.addListener(_onTabChanged);
    _lastTabIndex = _tabController.index;
  }

  String get _currentSignature {
    final state = context.read<AppState>();
    return state.activeSites.map((s) => s.key).join(',');
  }

  /// 视频源改动过时才重新拉取（切换 tab 时调用）；
  /// 源没变但内容放太久，就静默刷新当前分类。
  Future<void> reloadIfNeeded() async {
    if (_currentSignature != _signature) {
      await reload();
    } else {
      refreshIfStale();
    }
  }

  String _signature = '';

  /// 重新载入（切换 tab、修改了视频源后调用）
  Future<void> reload() async {
    if (!mounted) return;
    _signature = _currentSignature;
    // 刚整批重拉过，重置陈旧计时，避免紧接着又被 refreshIfStale 触发一次
    _lastRefreshAt = DateTime.now();
    final state = context.read<AppState>();
    final sites = state.activeSites;
    if (sites.isEmpty) {
      setState(() {
        _site = null;
        _classes = <VideoClass>[_latestClass];
        _recordCounts.clear();
        _loading = false;
      });
      _initTabs(_classes.length, force: true);
      return;
    }
    // 换源期间**保留旧的分类栏**，等新分类拉回来再整体替换。
    // 原来这里立刻把 _classes 重置成 [最新]，分类栏会先塌成 1 个再变回来，
    // 白白闪一下。
    setState(() {
      _loading = true;
      _site = sites.first;
      _recordCounts.clear();
    });
    await _loadClasses();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadClasses() async {
    if (_site == null) return;
    final list = await HttpService.instance.fetchClasses(_site!);
    if (!mounted) return;
    final visible = list
        .where((c) => !AppConstants.hiddenClasses.contains(c.name))
        .toList();
    setState(() {
      _classes = <VideoClass>[_latestClass, ...visible];
    });
    _initTabs(_classes.length, force: true);
    _saveBootSnapshot();
  }

  /// 静默向源站对一次分类栏。
  ///
  /// 冷启动先用快照把分类栏画出来，再走这里更新：失败就保持现状（快照里的分类
  /// 是能用的，不该因为一次网络抖动就清空），成功且确实有变化才替换 —— 期间
  /// 不置 `_loading`，所以网格不会闪成骨架屏。
  Future<void> _refreshClassesSilently() async {
    final site = _site;
    if (site == null) return;
    List<VideoClass> list;
    try {
      list = await HttpService.instance.fetchClasses(site);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final visible = list
        .where((c) => !AppConstants.hiddenClasses.contains(c.name))
        .toList();
    final next = <VideoClass>[_latestClass, ...visible];
    if (_sameClasses(next, _classes)) {
      _saveBootSnapshot();
      return;
    }
    final keepTid = _activeClass.tid;
    final idx = next.indexWhere((c) => c.tid == keepTid);
    setState(() => _classes = next);
    _initTabs(next.length, force: true, initialIndex: idx < 0 ? 0 : idx);
    _saveBootSnapshot();
  }

  bool _sameClasses(List<VideoClass> a, List<VideoClass> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].tid != b[i].tid || a[i].name != b[i].name) return false;
    }
    return true;
  }

  /// 把当前首屏结构（站点 / 分类 / 停在哪一栏）记下来，供下次冷启动秒开。
  void _saveBootSnapshot() {
    final site = _site;
    if (site == null || _classes.length <= 1) return;
    final cls = _classes.where((c) => c.tid != _latestClass.tid).toList();
    if (cls.isEmpty) return;
    BootSnapshot.save(site, cls, _activeClass.tid);
  }

  /// 子分类页面加载完某一分类的资源数后，回写到顶部的统计
  void _onRecordCount(String tid, int count) {
    _recordCounts[tid] = count;
    // 仅当回写的是当前可见分类时才刷新顶部显示
    if (_classes.isNotEmpty &&
        _activeClass.tid == tid &&
        mounted) {
      setState(() {});
    }
  }

  Future<void> _pickSite() async {
    final sites = context.read<AppState>().activeSites;
    if (sites.isEmpty) return;
    final picked = await showPicker<Site>(
      context: context,
      title: '选择视频源',
      items: sites,
      selected: _site,
      labelBuilder: (s) => s.name,
    );
    if (picked == null || picked.key == _site?.key) return;
    _lastRefreshAt = DateTime.now();
    setState(() {
      _loading = true;
      _site = picked;
      _recordCounts.clear();
    });
    await _loadClasses();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      // 带上当前正在浏览的源，搜索页「当前站点」范围要用
      MaterialPageRoute(builder: (_) => SearchPage(currentSite: _site)),
    );
  }

  void _openDetail(Video video) {
    if (_site == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(siteKey: _site!.key, videoId: video.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 宽屏（平板 / 桌面）：首行够宽，站点切换与右侧操作同排
    final isWide = MediaQuery.of(context).size.width >= _wideThreshold;
    // 卡片形态：横向（16:10 图上文下）/ 竖向（竖版海报网格）。
    // 设置页也能改，这里 select 只订阅这一个字段 —— 用 watch 会让任何设置变更
    // （主题、倍速、下载速度…）都把整个首页连同分栏重建一次。
    final landscape =
        context.select<AppState, bool>((s) => s.config.landscapeCard);
    // 视图切换按钮默认隐藏（设置页里开启），同样只订阅这一个字段
    final showViewToggle =
        context.select<AppState, bool>((s) => s.config.showViewToggle);
    return Scaffold(
      appBar: AppBar(
        // 「首页」文字已去掉，原位改放站点切换（含资源数）+ 搜索，
        // 视图切换按钮是否出现由设置页的「显示视图切换按钮」决定（默认关）
        titleSpacing: isWide ? 12 : 8,
        toolbarHeight: isWide ? 60 : kToolbarHeight,
        title: isWide
            ? Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: _buildSiteButton(isDark),
                    ),
                    const SizedBox(width: 10),
                    // 宽屏（平板 / 桌面）空间够：搜索做成输入框样式的入口，
                    // Expanded 吃掉站点按钮与视图按钮之间的全部剩余宽度
                    Expanded(child: _buildSearchBox(isDark, height: 40)),
                    if (showViewToggle) ...[
                      const SizedBox(width: 6),
                      _buildViewButton(isDark, landscape),
                    ],
                  ],
                ),
              )
            : Row(
                children: [
                  Expanded(child: _buildSiteButton(isDark)),
                  const SizedBox(width: 4),
                  // 手机宽度不够铺开搜索框，仍用一个图标按钮，点开进搜索页
                  _buildSearchButton(isDark),
                  if (showViewToggle) _buildViewButton(isDark, landscape),
                  const SizedBox(width: 4),
                ],
              ),
      ),
      body: Column(
        children: [
          if (_site != null) _buildCategoryTabBar(),
          Expanded(
            child: _buildCategoryTabs(),
          ),
        ],
      ),
      // 小屏专属：右下角悬浮搜索，单手握持时拇指一伸就到。
      // 往上抬一层，把最贴近拇指的位置留给「回到顶部」——它只在滚动后出现，
      // 用固定偏移而不是跟着它显隐，避免按钮上下跳动。
      floatingActionButton: isWide
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: _kSearchFabLift),
              child: _buildSearchFab(isDark),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  /// 悬浮搜索按钮：浅色白底 + 淡描边，深色沿用 OLED 的「极暗面 + 1px 描边」，
  /// 不靠提亮底色分层（提亮整块就发灰了）。
  Widget _buildSearchFab(bool isDark) {
    return SizedBox(
      width: _kSearchFabSize,
      height: _kSearchFabSize,
      child: FloatingActionButton(
        // 同一页里还有「回到顶部」小 FAB，默认 heroTag 会撞车，这里关掉 Hero
        heroTag: null,
        onPressed: _openSearch,
        tooltip: '搜索影片',
        elevation: 4,
        highlightElevation: 8,
        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
        foregroundColor: isDark ? Colors.white70 : const Color(0xFF303133),
        shape: CircleBorder(
          side: BorderSide(
            color: isDark ? AppColors.darkOutline : const Color(0xFFE4E7ED),
          ),
        ),
        child: const Icon(Icons.search_rounded, size: 26),
      ),
    );
  }

  /// 站点切换按钮（AppBar 首行最左）
  ///
  /// 当前分类的资源数直接并进按钮里（`网站: 某站 · 128 资源`），
  /// 首行因此只用「站点 / 搜索 / 视图」三个元素，手机上也能把搜索和切视图
  /// 一起收进第一排，不必再单占一行。
  Widget _buildSiteButton(bool isDark) {
    // 资源数用弱化的色号，和站点名拉开层级：一眼分清「是什么源」和「有多少片」
    final muted = isDark ? Colors.white54 : const Color(0xFF909399);
    return OutlinedButton.icon(
      onPressed: _pickSite,
      icon: const Icon(Icons.language, size: 16),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 站点名可被压缩（超长省略号），资源数固定不参与收缩 ——
          // 否则名字一长，被裁掉的正好是刚并进来的资源数。
          Flexible(
            child: Text(
              // 不加「网站: 」前缀 —— 左边的地球图标已经说明了这是站点，
              // 省下的宽度留给站名本身（窄屏尤其紧张）
              _site == null ? '未选择视频源' : _site!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 未选源 / 还不知道数量时不显示，那句 0 反而像「源是空的」。
          // 冷启动走快照时数量来自缓存元信息，读不到就是 0，这里一并挡掉。
          if (_site != null && _activeRecordCount > 0) ...[
            const SizedBox(width: 8),
            Text(
              '· $_activeRecordCount 资源',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: muted,
              ),
            ),
          ],
        ],
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: isDark ? Colors.white70 : const Color(0xFF303133),
        side: BorderSide(
          color: isDark ? Colors.white24 : const Color(0xFFDCDFE6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    );
  }

  /// AppBar 首行的图标按钮（搜索、卡片形态切换共用）。
  ///
  /// 用 [IconButton] 而不是自绘 InkWell，白送水波纹、焦点框与无障碍语义；
  /// 约束压到 36×36，手机 56 高的工具栏里才不会把站点按钮挤没。
  Widget _buildBarIcon({
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      color: isDark ? Colors.white70 : const Color(0xFF303133),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    );
  }

  /// 搜索入口（手机）：点开独立搜索页（历史记录 + 搜索结果）。
  Widget _buildSearchButton(bool isDark) {
    return _buildBarIcon(
      isDark: isDark,
      icon: Icons.search_rounded,
      tooltip: '搜索影片',
      onTap: _openSearch,
    );
  }

  /// 搜索框（宽屏）：做成输入框的样子，但点一下是进独立搜索页，不是就地输入。
  ///
  /// 高度由调用方给（宽屏工具栏 60，取 40 与之对齐图标按钮）；
  /// 宽度交给外层 `Expanded` 按剩余空间自动拉伸，不写死。
  ///
  /// 浅色主题下 AppBar 本身就是白底，白色填充会「看不见」，所以用浅灰；
  /// 深色主题用极暗面 + 描边，不靠提亮底色区分层级。
  Widget _buildSearchBox(bool isDark, {double height = 40}) {
    return InkWell(
      onTap: _openSearch,
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : AppColors.lightBg,
          borderRadius: BorderRadius.circular(height / 2),
          border: isDark ? Border.all(color: AppColors.darkOutline) : null,
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 20,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
            const SizedBox(width: 8),
            Text(
              '搜索影片',
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.black54,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 卡片形态切换：横向卡片（16:10 图上文下）⇄ 竖向卡片（竖版海报网格）。
  ///
  /// 图标显示的是**点下去会变成什么**，配 tooltip 说清方向，一眼能看出作用；
  /// 当前形态本身在屏幕上就看得见，不需要再用图标重复一遍。
  Widget _buildViewButton(bool isDark, bool landscape) {
    return _buildBarIcon(
      isDark: isDark,
      icon: landscape ? Icons.grid_view_rounded : Icons.view_agenda_rounded,
      tooltip: landscape ? '切换为竖向卡片' : '切换为横向卡片',
      onTap: () => context.read<AppState>().setLandscapeCard(!landscape),
    );
  }

  /// 分类分栏：可横向滑动（分类多时滚动），也可点选
  Widget _buildCategoryTabBar() {
    if (_classes.isEmpty) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? AppColors.darkBg : Colors.white,
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        labelColor: isDark ? Colors.white : const Color(0xFF1E88E5),
        unselectedLabelColor: isDark ? Colors.white70 : const Color(0xFF606266),
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(
            width: 2,
            color: isDark ? Colors.white : const Color(0xFF1E88E5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tabs: _classes.map((c) => Tab(text: c.name)).toList(),
      ),
    );
  }

  /// 分类内容区：左右滑动切换分栏
  Widget _buildCategoryTabs() {
    if (_site == null) {
      return const EmptyHint(
        message: '暂无可用视频源\n请到「设置 - 视频源管理」中启用或导入视频源',
        icon: Icons.video_library_outlined,
      );
    }
    // 换源 / 拉分类期间铺骨架屏（形状与真实网格一致），
    // 不再整块换成居中转圈 —— 那会先把内容抹掉再长回来
    if (_loading) return const VideoGridSkeleton();
    return TabBarView(
      controller: _tabController,
      children: _classes
          .map(
            (c) => CategoryTab(
              key: Key('${_site!.key}-${c.tid}'),
              site: _site!,
              videoClass: c,
              onRecordCount: _onRecordCount,
              onTapVideo: _openDetail,
              refreshTick: _refreshTicks[c.tid] ?? 0,
              // 快照来的那一页片单只在「同一个源」上注入一次，
              // 否则换源后同一个 tid 会把旧站的片子画到新站上
              initialVideos: _site!.key == _bootSiteKey
                  ? _bootVideos[c.tid]
                  : null,
            ),
          )
          .toList(),
    );
  }
}

/// 单个分类分栏页：自己管理列表、分页、滚动、加载，切走再切回保留状态。
class CategoryTab extends StatefulWidget {
  final Site site;
  final VideoClass videoClass;
  final void Function(String tid, int count) onRecordCount;
  final void Function(Video video) onTapVideo;

  /// 「刷新令牌」：父级把某个分类的令牌 +1，本分栏就静默重拉一次片单。
  ///
  /// 用自增 int 而不是 GlobalKey 调子 State 方法，是因为分栏都在
  /// `AutomaticKeepAlive` 里常驻，GlobalKey 还要跟着换源重建、清理，容易出错。
  final int refreshTick;

  /// 冷启动快照自带的第一页片单：有值就**直接当首帧内容**画出来，
  /// 跳过「先读缓存再显示」那一步异步等待（两者本来就是同一份数据）。
  final List<Video>? initialVideos;

  const CategoryTab({
    super.key,
    required this.site,
    required this.videoClass,
    required this.onRecordCount,
    required this.onTapVideo,
    this.refreshTick = 0,
    this.initialVideos,
  });

  @override
  State<CategoryTab> createState() => CategoryTabState();
}

class CategoryTabState extends State<CategoryTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final List<Video> _videos = <Video>[];
  final ScrollController _scrollController = ScrollController();

  /// 下一个要加载的页号。
  ///
  /// ⚠️ 采集接口 `pg=1` 才是**最新**内容，页码越大内容越老（实测某源
  /// `pg=1` 是今天更新的片子，末页是 2023 年的）。所以这里从 1 开始递增，
  /// 一旦搞反，「最新」分栏取到的就是全站最老的那批片子，永远不变。
  int _pageCount = 1;

  /// 源站总页数（pagecount）。0 表示还没问到，边界未知。
  int _totalPages = 0;

  int _recordCount = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _showBackTop = false;

  /// 上一次「加载更多」失败（多半是源站超时）。底部不再静默停住，
  /// 而是给一个明确的重试入口 —— 否则用户只看到转圈消失、列表不动。
  bool _loadMoreFailed = false;

  /// 首次/整页刷新失败且手上一条数据都没有：给一个可点的失败提示，
  /// 而不是永远停在骨架屏或一片空白。
  bool _loadFailed = false;

  /// 连续「加载了但列表没增长」的次数：给「内容没撑满可视区就续拉」兜底，
  /// 防止对返回重复页的源站空转狂刷。
  int _noGrowStreak = 0;

  /// 已加载的页号集合：用于「后台刷新」时只替换最新的头部页面、不抹掉用户已下滑
  /// 加载的后续页面，并让「加载更多」接着已加载的最后一页继续往后翻（不重复取页）。
  final Set<int> _loadedPages = <int>{};

  /// 首帧内容是否来自冷启动快照。是的话 [_load] 里跳过读缓存那一步 ——
  /// 快照本身就是从同一份 [ListCache] 读出来的，再读一遍只会重复劳动。
  bool _seededFromSnapshot = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    final boot = widget.initialVideos;
    if (boot != null && boot.isNotEmpty) {
      _videos.addAll(boot);
      _loadedPages.add(1);
      _seededFromSnapshot = true;
      // 首帧就要出图，先把这批封面的磁盘缓存排上（命中索引的直接本地读）
      unawaited(ImagePrefetch.prefetch(boot.map((v) => v.pic).toList()));
    }
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  /// 上一次静默刷新是否还在进行中，防止「回到前台」和「切回首页」同时触发两次请求
  bool _refreshing = false;

  @override
  void didChangeMetrics() {
    // 旋转 / 分屏改变可视区大小：横屏列变多后内容可能不再溢出，没有滚动事件就
    // 触发不了加载更多。这里重新检查是否要补内容（否则同样会卡在「滑不动」）。
    _maybeContinueLoad();
  }

  @override
  void didUpdateWidget(covariant CategoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级要求刷新（回到前台 / 切回首页且内容偏旧）：只静默替换头部页面，
    // 用户已下滑加载的内容保持不动。
    if (widget.refreshTick != oldWidget.refreshTick) {
      unawaited(_refresh());
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final show = position.pixels > 800;
    if (show != _showBackTop && mounted) {
      setState(() => _showBackTop = show);
    }
    // 提前 900px（约 3 行）就开始取下一页：源站单页往往要 1~9 秒，
    // 等真正贴底再请求，用户必然在底部干等；提前发能让等待落在滚动过程中。
    if (position.pixels >= position.maxScrollExtent - 900) {
      _loadMore();
    }
  }

  /// 载入当前分类的片单。
  ///
  /// 两步：① 先读本地缓存（若存在）瞬间把上一次的片单画出来——**打开即显示**；
  /// ② 后台静默向源站刷新，拿到新数据再替换。刷新失败则保留缓存、不空白。
  Future<void> _load() async {
    if (!mounted) return;
    final siteKey = widget.site.key;
    final tid = widget.videoClass.tid;

    if (_seededFromSnapshot) {
      // 首帧内容已经由启动快照铺好，直接进 ② 向源站静默刷新：
      // 再读一遍缓存只是把同一批数据搬一次，白等几个异步往返。
      _seededFromSnapshot = false;
      try {
        await _refresh();
      } catch (_) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadFailed = _videos.isEmpty;
          });
        }
      }
      return;
    }

    // ① 本地缓存优先：恢复元信息与「第 1、2 页」（与网络取数顺序一致）
    // ⚠️ 读缓存任何一环出问题都只当「没有缓存」处理，绝不能让异常跳出 _load ——
    // 那样 _loading 会停在 false、列表又空，界面就显示成「该分类下暂无资源」，
    // 看起来像源站没内容，实际是本地读取失败、网络请求根本还没发出去。
    CachedMeta? meta;
    try {
      meta = await ListCache.getMeta(siteKey, tid);
    } catch (_) {
      meta = null;
    }
    if (!mounted) return;
    if (meta != null) {
      _recordCount = meta.recordcount;
      _totalPages = meta.pagecount;
      widget.onRecordCount(tid, _recordCount);
      final pages = <int>[1];
      if (meta.pagecount > 1) pages.add(2);
      final restored = <Video>[];
      for (final pg in pages) {
        try {
          final cached = await ListCache.getPage(siteKey, tid, pg);
          if (cached != null && cached.isNotEmpty) {
            restored.addAll(cached);
            _loadedPages.add(pg);
          }
        } catch (_) {
          // 这一页缓存读坏了就跳过，剩下的照常恢复
        }
      }
      if (mounted) {
        setState(() {
          if (restored.isNotEmpty) _videos.addAll(restored);
          // 有缓存可显示就立刻展示；缓存是空的（只有元信息没分页数据）时
          // 继续铺骨架屏，别先闪一下「暂无资源」再长回来。
          _loading = restored.isEmpty;
        });
        if (restored.isNotEmpty) {
          // 抢先预取这些封面的磁盘缓存：本次滚动、下次打开直接读本地不再转圈
          unawaited(ImagePrefetch.prefetch(restored.map((v) => v.pic).toList()));
        }
      }
    } else if (mounted) {
      setState(() {
        _loading = true;
        _videos.clear();
      });
    }

    // ② 后台刷新（不阻塞首屏）
    // 任何意外都不能让 _loading 永久停在 true —— 那会一直挂在骨架屏上。
    try {
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = _videos.isEmpty;
        });
      }
    }
  }

  /// 静默刷新入口：防重入后转给 [_doRefresh]
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await _doRefresh();
    } finally {
      _refreshing = false;
    }
  }

  /// 向源站重新拉取片单并写回缓存，最后用最新数据**合并**进显示。
  ///
  /// 取数顺序：从 `pg=1`（最新）往后翻，凑够至少 6 条，单趟不重复取页。
  /// ⚠️ 关键：刷新只替换「最新的头部页面」，必须保留用户已经下滑加载出来的后续页面——
  /// 否则后台刷新一返回就把已加载内容整段抹除（表现为「滑一下闪一下、内容少了一截」，
  /// 再滑又刷出来）。做法：fresh 作前缀，再把当前列表里 id 不在 fresh 中的旧条目
  /// 按原顺序接在后面（相同 id 用 fresh 的新数据覆盖）。
  Future<void> _doRefresh() async {
    if (!mounted) return;
    final site = widget.site;
    final tid = widget.videoClass.tid;
    final info = await HttpService.instance.fetchPage(site, tid: tid);
    if (!mounted) return;
    if (!info.ok) {
      // 连总页数都没问到：**不写缓存、不动分页边界**，保留已显示的内容。
      // 早先这里会把 pagecount=1 当成真的只有一页写进缓存，之后这个分类就
      // 再也翻不动了。手上一条数据都没有时给个可重试的提示。
      setState(() {
        _loading = false;
        _loadFailed = _videos.isEmpty;
      });
      return;
    }
    _recordCount = info.recordcount;
    _totalPages = info.pagecount;
    _loadFailed = false;
    widget.onRecordCount(tid, _recordCount);
    try {
      await ListCache.putMeta(site.key, tid, info.pagecount, info.recordcount);
    } catch (_) {
      // 元信息写不进去只影响下次秒开，不能连累这一次的显示
    }

    // 从第 1 页往后取。首屏**只要 1 页**（20 条）就够把手机竖屏铺满两屏多，
    // 不再一次取 3 页：首页十几个分类同时初始化时，每栏多发两个请求就会叠成
    // 几十个并发，源站一限流就整屏返回失败 —— 那才是「所有分类都暂无资源」的
    // 直接原因。少而稳比多而全重要，剩下的交给滚动加载去补。
    // `pagecount <= 0`（有些源对父分类不给分页信息）时至少试第 1 页，
    // 否则 `page <= 0` 一次都不循环，明明有内容也会显示成空。
    final lastPage = info.pagecount <= 0 ? 1 : info.pagecount;
    final fresh = <Video>[];
    var page = 1;
    var tries = 0;
    // 是否至少有「一次取页是成功返回的」。用来区分两种空：
    //  - 全部请求失败（网络/限流）→ 该给「加载失败 + 重试」
    //  - 请求成功但源站就是没内容（父分类常见）→ 才是真的「暂无资源」
    var anyOk = false;
    while (page <= lastPage && tries < 2 && (fresh.isEmpty || fresh.length < 6)) {
      try {
        await _appendPage(page, sink: fresh);
        anyOk = true;
      } catch (_) {
        // 这一页没取到就收手，已经拿到的内容照常显示（不让整次刷新炸掉）
        break;
      }
      _loadedPages.add(page);
      page++;
      tries++;
    }
    if (!mounted) return;
    setState(() {
      if (fresh.isNotEmpty) {
        // 合并而非清空：保留更早的已加载页，避免刷新把内容抹掉
        final freshIds =
            <String>{for (final v in fresh) if (v.id.isNotEmpty) v.id};
        final kept = <Video>[];
        for (final v in _videos) {
          if (v.id.isNotEmpty && freshIds.contains(v.id)) continue;
          kept.add(v);
        }
        _videos
          ..clear()
          ..addAll(fresh)
          ..addAll(kept);
      } else if (_videos.isEmpty && !anyOk) {
        // 一页都没取到，且手上没有旧内容：这是「没取到」不是「没资源」。
        // 以前这里静默留空，界面就显示「该分类下暂无资源」，把网络问题
        // 伪装成源站没内容，用户只能干看着。现在给一个能点的重试。
        _loadFailed = true;
      }
      _loading = false;
    });
    // 已加载的最后一页：接下来 loadMore 从这里继续往后翻，不重复取已加载的页
    _pageCount = _loadedPages.isEmpty
        ? 1
        : _loadedPages.reduce((a, b) => a > b ? a : b) + 1;
    // 刷新拿到的新片单同样抢先预取封面，保持「打开即秒显」的体感
    unawaited(ImagePrefetch.prefetch(fresh.map((v) => v.pic).toList()));
    // 横屏 / 大屏列多时这几页可能整屏放得下 —— 没有滚动事件就等于「加载更多」永不
    // 触发，这里主动检查并续拉，修掉「打开就已经到底、上滑没反应」。
    _noGrowStreak = 0;
    _maybeContinueLoad();
    // 首屏画出来之后，再错峰垫一页。不在这里立刻连发两个请求，是因为首页
    // 十几个分类几乎同时初始化，每栏再多两个请求就会叠成几十个并发，源站
    // 一限流整屏都变成「暂无资源」。延迟 + 只垫一页，把峰值压下来。
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) unawaited(_warmUp(1));
    }));
  }

  /// 首屏内容出现后，后台**再补几页**，把「滑几个就撞上等网络」的空档填掉。
  ///
  /// 采集站一页只有 20 条（手机 2 列约 3 屏半），而单页响应实测 1~9 秒。
  /// 用户滑到第 20 条时必然要等下一页 —— 这就是「滑出来几个视频就卡住十几秒」
  /// 的来源。这里趁用户还在看第一页，把后面两页静默取回来，滑到那儿已经有内容。
  ///
  /// 静默：不显示底部转圈、不动 [_loading]；失败直接收手，页号不消耗，
  /// 等用户真正滑到底时 [_loadMore] 还会再试一次。
  Future<void> _warmUp(int pages) async {
    for (var i = 0; i < pages; i++) {
      if (!mounted || _loading || _loadingMore) return;
      if (_totalPages > 0 && _pageCount > _totalPages) return;
      if (_loadMoreFailed) return;
      _loadingMore = true;
      final page = _pageCount;
      _pageCount++;
      var ok = true;
      try {
        await _appendPage(page);
        _loadedPages.add(page);
      } catch (_) {
        _pageCount--; // 失败不消耗页号
        ok = false;
      }
      _loadingMore = false;
      if (!mounted) return;
      if (!ok) return;
      setState(() {});
    }
    // 补齐之后再看一眼：大屏列多时 3 页仍可能不够撑满一屏，
    // 那种情况没有滚动事件，得靠这里主动续拉。
    if (mounted) _maybeContinueLoad();
  }

  /// 取某一页的片单并写入缓存。
  ///
  /// [sink] 非空时把结果累加进外部列表（用于后台刷新：先攒齐再一次性替换显示）；
  /// 为空时直接累加进 [_videos]（用于滚动加载更多：边取边显示）。
  /// 不在此处递归翻页——翻页节奏统一由调用方（_doRefresh / _loadMore）控制，
  /// 避免重复取页；重复 id 的条目也在此处直接跳过，作最后一层兜底。
  Future<void> _appendPage(int page, {List<Video>? sink}) async {
    if (page <= 0) return;
    final target = sink ?? _videos;
    var list = await _fetchPageVideos(page);
    if (list.isEmpty) {
      // 空页（有些源偶发返回空）等一小会儿再问一次，别直接判成「没更多了」
      await Future<void>.delayed(const Duration(milliseconds: 350));
      list = await _fetchPageVideos(page);
    }
    if (!mounted) return;
    final seen = <String>{for (final v in target) if (v.id.isNotEmpty) v.id};
    for (final v in list) {
      if (v.id.isNotEmpty && seen.contains(v.id)) continue; // 跳过重复 id
      target.add(v);
      if (v.id.isNotEmpty) seen.add(v.id);
    }
    // ⚠️ 缓存必须放在「数据已经进列表」之后，且失败只吞掉：写缓存是锦上添花，
    // 一旦磁盘/序列化出问题就抛出去，会让刚刚取到的这一页连同循环一起作废，
    // 最终显示成「暂无资源」。
    try {
      await ListCache.putPage(
        widget.site.key,
        widget.videoClass.tid,
        page,
        list,
      );
    } catch (_) {
      // ignore：不影响本次显示
    }
  }

  /// 取一页片单（失败抛异常，供调用方区分「没更多」与「没取到」）
  Future<List<Video>> _fetchPageVideos(int page) =>
      HttpService.instance.fetchList(
        widget.site,
        pg: page,
        tid: widget.videoClass.tid,
        strict: true,
      );

  /// 滚动到底部时加载下一页（更早的内容）。
  ///
  /// ⚠️ 两点易踩的坑都已修：
  /// 1) 取页（网络）异常必须复位 `_loadingMore`，否则一旦某页失败，
  ///    该标志永久停在 true，后续所有加载都被 guard 拦掉——表现为「滑到某处就再也不动了」。
  ///    失败时回退 `_pageCount`，下次还能重试这一页。
  /// 2) 加载完若用户仍停在底部（静止、无新滚动事件），`_onScroll` 不会再触发，必须
  ///    「来回滑一下」才续拉。这里在成功贴底且列表确有增长时**自动续拉下一页**，
  ///    让到底即连续加载，不再需要手动划动。重复页（源站返回相同 id）不增长则不续拉，
  ///    避免对问题源站空转狂刷；`_pageCount` 一路递增超过 pagecount 自然收尾。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading) return;
    if (_totalPages > 0 && _pageCount > _totalPages) return;
    _loadingMore = true;
    if (_loadMoreFailed && mounted) {
      setState(() => _loadMoreFailed = false);
    }
    final before = _videos.length;
    final page = _pageCount;
    _pageCount++;
    var ok = true;
    try {
      await _appendPage(page);
      _loadedPages.add(page);
    } catch (e) {
      _pageCount--; // 回退，待下次滚动重试本页
      ok = false;
    }
    if (!mounted) {
      _loadingMore = false;
      return;
    }
    setState(() {
      _loadingMore = false;
      // 失败不静默：底部给「点击重试」，否则用户只看到转圈消失、列表不动
      _loadMoreFailed = !ok;
    });
    if (!ok) return;
    // 成功且列表增长、仍贴底（或内容还没撑满可视区）：自动续拉，
    // 免去「往下滑一下再往上滑一下」，也修掉横屏下根本滑不动导致的卡死
    _noGrowStreak = _videos.length > before ? 0 : _noGrowStreak + 1;
    _maybeContinueLoad();
    // 再往后垫一页：始终保持「比用户领先一页」，下一屏就不会又停在底部干等
    unawaited(_warmUp(1));
  }

  /// 内容没撑满可视区时主动续拉。
  ///
  /// 横屏（或平板 / 大屏）列数多、行高相对可视区更小，首屏那几页可能**完全放得下**。
  /// 这时 GridView 的 maxScrollExtent 为 0，根本产生不了滚动事件，
  /// [_onScroll] 里的 [_loadMore] 永远不会被调用 —— 用户看到的就是
  /// 「打开就已经到底、上滑没反应、只有左右切分类能用」。
  ///
  /// 这里在每帧布局完成后检查：仍然不可滚动 / 仍然贴底就继续翻页，直到能滑、
  /// 翻到末页，或连续两页都没新增（源站在返回重复页）为止。
  void _maybeContinueLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_loading || _loadingMore) return;
      if (_totalPages > 0 && _pageCount > _totalPages) return;
      if (_noGrowStreak >= 2) return;
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      final notScrollable = pos.maxScrollExtent <= 0;
      final atBottom = pos.pixels >= pos.maxScrollExtent - 900;
      if (!notScrollable && !atBottom) return;
      _loadMore();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 本栏还没有数据时铺骨架屏；已经有内容再加载（例如刷新）就保持内容不动，
    // 只在顶部压一条细进度线，避免「切一下变灰、内容消失又长回来」。
    final Widget content = (_loading && _videos.isEmpty)
        ? const VideoGridSkeleton()
        : (_loadFailed && _videos.isEmpty)
            ? EmptyHint(
                message: '片单加载失败\n可能是网络波动，或这个源暂时打不开',
                icon: Icons.cloud_off_outlined,
                actionText: '重试',
                onAction: _retryLoad,
              )
            : (_videos.isEmpty)
                ? EmptyHint(
                    message: '该分类下暂无资源',
                    icon: Icons.search_off,
                    // 有些源对父分类确实不给内容，但也可能是刚才那一次请求
                    // 恰好失败。给个刷新入口，用户点一下就能自己验证。
                    actionText: '刷新',
                    onAction: _retryLoad,
                  )
                : buildVideoGrid(
                    context: context,
                    videos: _videos,
                    scrollController: _scrollController,
                    loadingMore: _loadingMore,
                    onTap: widget.onTapVideo,
                    // 窄屏右下角有悬浮搜索按钮，给最后一排留出能滚过去的空间
                    bottomInset:
                        MediaQuery.sizeOf(context).width < FilmPageState._wideThreshold
                            ? _kSearchFabInset
                            : 0,
                  );
    return Stack(
      children: [
        content,
        if (_loading && _videos.isNotEmpty)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_showBackTop)
          Positioned(
            right: 16,
            // 贴底那一格归「回到顶部」，窄屏的悬浮搜索按钮固定在它上方
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: 'catBackTop-${widget.videoClass.tid}',
              onPressed: () => _scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              ),
              child: const Icon(Icons.arrow_upward),
            ),
          ),
        // 翻页失败：底部浮一条可点重试的提示。源站偶发超时时，
        // 原来的「转圈消失、列表不动」看不出发生了什么，用户只能干等。
        // 已翻到末页（没有更多页了）就不再提示重试，避免点了没反应。
        if (_loadMoreFailed &&
            !_loadingMore &&
            (_totalPages <= 0 || _pageCount <= _totalPages))
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(child: _buildRetryTip()),
          ),
      ],
    );
  }

  /// 失败提示上的「重试」：重新走一遍静默刷新
  void _retryLoad() {
    if (_refreshing || !mounted) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    unawaited(_refresh());
  }

  Widget _buildRetryTip() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.inverseSurface,
      borderRadius: BorderRadius.circular(20),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _loadMore,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh, size: 18, color: scheme.onInverseSurface),
              const SizedBox(width: 6),
              Text(
                '加载失败，点击重试',
                style: TextStyle(fontSize: 13, color: scheme.onInverseSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 视频网格已抽到 widgets/video_grid.dart（VideoGridView / buildVideoGrid），
/// 首页分类页与搜索结果共用。

