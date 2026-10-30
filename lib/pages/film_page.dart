import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../services/list_cache.dart';
import '../utils/app_colors.dart';
import '../utils/image_prefetch.dart';
import '../utils/constants.dart';
import '../widgets/common_widgets.dart';
import '../widgets/video_grid.dart';
import 'detail_page.dart';
import 'search_page.dart';

/// 首页：搜索 + 站点切换（顶部）+ 分类左右滑动分栏 + 资源瀑布流
class FilmPage extends StatefulWidget {
  const FilmPage({super.key});

  @override
  State<FilmPage> createState() => FilmPageState();
}

class FilmPageState extends State<FilmPage>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  static const _latestClass = VideoClass(tid: '0', name: '最新');

  /// 宽屏阈值（与 MainPage 的 _wideThreshold 一致）：达到后把搜索框并进
  /// AppBar 首行，与站点切换、资源统计同排，省下一整行竖向空间。
  static const double _wideThreshold = 600;

  Site? _site;
  List<VideoClass> _classes = <VideoClass>[_latestClass];

  /// 顶部网站切换旁的「共 X 资源」：按分类 tid 缓存各分类的资源数
  final Map<String, int> _recordCounts = <String, int>{};

  late TabController _tabController;
  int _lastTabIndex = 0;

  /// 站点 / 分类还在拉取时，整体先转圈（此时分栏还没出来）
  bool _loading = false;

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
    _tabController = TabController(length: _classes.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    // 直接进主页时 sites 可能还没加载完（bootstrap 是异步的），先挂监听：
    // 等源列表就绪（空 → 非空）后自动 reload，避免卡在「暂无可用视频源」。
    context.read<AppState>().addListener(_onAppStateChanged);
    reload();
  }

  @override
  void dispose() {
    context.read<AppState>().removeListener(_onAppStateChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// AppState 任意变化（含 sites 加载完成）时尝试按需重载。
  /// [reloadIfNeeded] 内部按源签名比对，签名不变（如只加载了收藏/历史）不会重复拉取。
  void _onAppStateChanged() {
    if (mounted) unawaited(reloadIfNeeded());
  }

  void _onTabChanged() {
    if (_tabController.index != _lastTabIndex) {
      _lastTabIndex = _tabController.index;
      // 切换分类后，顶部的「共 X 资源」要跟着当前分类刷新
      if (mounted) setState(() {});
    }
  }

  /// 站点或分类数量变化后，重建 TabController（长度必须和分类数一致）
  ///
  /// [force] = true 时即使长度没变也重建，并把选中分栏重置回「最新」——
  /// 换源后新旧站点分类数恰好相同的情况必须靠它兜住，否则会停在原来那一栏。
  void _initTabs(int length, {bool force = false}) {
    if (!force && _tabController.length == length) return;
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _tabController = TabController(length: length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _lastTabIndex = _tabController.index;
  }

  String get _currentSignature {
    final state = context.read<AppState>();
    return state.activeSites.map((s) => s.key).join(',');
  }

  /// 视频源改动过时才重新拉取（切换 tab 时调用）
  Future<void> reloadIfNeeded() async {
    if (_currentSignature != _signature) {
      await reload();
    }
  }

  String _signature = '';

  /// 重新载入（切换 tab、修改了视频源后调用）
  Future<void> reload() async {
    if (!mounted) return;
    _signature = _currentSignature;
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
      MaterialPageRoute(builder: (_) => SearchPage()),
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
    // 宽屏（平板 / 桌面）：首行够宽，把搜索框并进 AppBar，省出一整行
    final isWide = MediaQuery.of(context).size.width >= _wideThreshold;
    return Scaffold(
      appBar: AppBar(
        // 「首页」文字已去掉，原位改放网站切换 + 资源统计（宽屏再加搜索框）
        titleSpacing: isWide ? 12 : 8,
        toolbarHeight: isWide ? 60 : kToolbarHeight,
        title: isWide
            ? Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: _buildSiteButton(isDark),
                    ),
                    const SizedBox(width: 14),
                    // 搜索框吃掉剩余宽度
                    Expanded(
                      child: _buildSearchBox(
                        isDark,
                        height: 40,
                        inAppBar: true,
                      ),
                    ),
                    const SizedBox(width: 14),
                    _buildRecordCount(isDark),
                  ],
                ),
              )
            : Row(
                children: [
                  Expanded(child: _buildSiteButton(isDark)),
                  const SizedBox(width: 10),
                  _buildRecordCount(isDark),
                ],
              ),
      ),
      body: Column(
        children: [
          if (!isWide) _buildSearchEntry(),
          if (_site != null) _buildCategoryTabBar(),
          Expanded(
            child: _buildCategoryTabs(),
          ),
        ],
      ),
    );
  }

  /// 站点切换按钮（AppBar 首行最左）
  Widget _buildSiteButton(bool isDark) {
    return OutlinedButton.icon(
      onPressed: _pickSite,
      icon: const Icon(Icons.language, size: 16),
      label: Text(
        _site == null ? '未选择视频源' : '网站: ${_site!.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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

  /// 资源统计（AppBar 首行最右，宽屏时与搜索框同一行）
  Widget _buildRecordCount(bool isDark) {
    return Text(
      '共: $_activeRecordCount 资源',
      style: TextStyle(
        fontSize: 12,
        color: isDark ? Colors.white70 : const Color(0xFF909399),
        fontWeight: FontWeight.w500,
      ),
    );
  }

  /// 搜索入口（手机）：独占一行，上下留白
  Widget _buildSearchEntry() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: _buildSearchBox(Theme.of(context).brightness == Brightness.dark),
    );
  }

  /// 搜索框本体：点击进入独立搜索页（展示历史记录 + 搜索结果）。
  ///
  /// [inAppBar] 为 true 时用于 AppBar 首行：浅色主题的 AppBar 本身就是纯白，
  /// 白色填充会“看不见”，这里改用浅灰填充；深色主题沿用极暗面 + 描边。
  Widget _buildSearchBox(
    bool isDark, {
    double height = 42,
    bool inAppBar = false,
  }) {
    return InkWell(
      onTap: _openSearch,
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          // 深色下用极暗面 + 描边，而不是把底色提亮（提亮整屏就发灰了）
          color: isDark
              ? AppColors.darkSurface
              : (inAppBar ? AppColors.lightBg : Colors.white),
          borderRadius: BorderRadius.circular(height / 2),
          border: isDark ? Border.all(color: AppColors.darkOutline) : null,
        ),
        child: Row(
          children: [
            Icon(
              Icons.search,
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

  const CategoryTab({
    super.key,
    required this.site,
    required this.videoClass,
    required this.onRecordCount,
    required this.onTapVideo,
  });

  @override
  State<CategoryTab> createState() => CategoryTabState();
}

class CategoryTabState extends State<CategoryTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final List<Video> _videos = <Video>[];
  final ScrollController _scrollController = ScrollController();

  int _pageCount = 0;
  int _recordCount = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _showBackTop = false;

  /// 上一次「加载更多」失败（多半是源站超时）。底部不再静默停住，
  /// 而是给一个明确的重试入口 —— 否则用户只看到转圈消失、列表不动。
  bool _loadMoreFailed = false;

  /// 连续「加载了但列表没增长」的次数：给「内容没撑满可视区就续拉」兜底，
  /// 防止对返回重复页的源站空转狂刷。
  int _noGrowStreak = 0;

  /// 已加载的页号集合：用于「后台刷新」时只替换最新尾页、不抹掉用户已下滑加载的
  /// 更早页面，并让「加载更多」接着已加载的最早一页继续往前翻（不重复取页）。
  final Set<int> _loadedPages = <int>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 旋转 / 分屏改变可视区大小：横屏列变多后内容可能不再溢出，没有滚动事件就
    // 触发不了加载更多。这里重新检查是否要补内容（否则同样会卡在「滑不动」）。
    _maybeContinueLoad();
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

    // ① 本地缓存优先：恢复元信息与「末页 + 末页-1」（与网络取数顺序一致）
    final meta = await ListCache.getMeta(siteKey, tid);
    if (meta != null) {
      _recordCount = meta.recordcount;
      widget.onRecordCount(tid, _recordCount);
      final pages = <int>[meta.pagecount];
      if (meta.pagecount > 1) pages.add(meta.pagecount - 1);
      final restored = <Video>[];
      for (final pg in pages) {
        final cached = await ListCache.getPage(siteKey, tid, pg);
        if (cached != null) {
          restored.addAll(cached);
          _loadedPages.add(pg);
        }
      }
      if (mounted) {
        setState(() {
          _videos.addAll(restored);
          // 有缓存可显示就不铺骨架屏，直接展示
          _loading = false;
        });
        // 抢先预取这些封面的磁盘缓存：本次滚动、下次打开直接读本地不再转圈
        unawaited(ImagePrefetch.prefetch(restored.map((v) => v.pic).toList()));
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
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 向源站重新拉取片单并写回缓存，最后用最新数据**合并**进显示。
  ///
  /// 取数顺序：从末页往前翻，凑够至少 6 条（末页不足则继续往前几页），单趟不重复取页。
  /// ⚠️ 关键：刷新只替换「最新的尾页」，必须保留用户已经下滑加载出来的更早页面——
  /// 否则后台刷新一返回就把已加载内容整段抹除（表现为「滑一下闪一下、内容少了一截」，
  /// 再滑又刷出来）。做法：fresh 作前缀，再把当前列表里 id 不在 fresh 中的旧条目
  /// 按原顺序接在后面（相同 id 用 fresh 的新数据覆盖）。
  Future<void> _refresh() async {
    if (!mounted) return;
    final site = widget.site;
    final tid = widget.videoClass.tid;
    final info = await HttpService.instance.fetchPage(site, tid: tid);
    if (!mounted) return;
    _recordCount = info.recordcount;
    widget.onRecordCount(tid, _recordCount);
    await ListCache.putMeta(site.key, tid, info.pagecount, info.recordcount);

    // 从末页往前取，直到攒够至少 6 条或翻到第一页为止（单趟，不重复取页）
    final fresh = <Video>[];
    var page = info.pagecount;
    while (page >= 1 && (fresh.isEmpty || fresh.length < 6)) {
      try {
        await _appendPage(page, sink: fresh);
      } catch (_) {
        // 这一页没取到就收手，已经拿到的内容照常显示（不让整次刷新炸掉）
        break;
      }
      _loadedPages.add(page);
      page--;
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
      }
      _loading = false;
    });
    // 已加载的最早一页：接下来 loadMore 从这里继续往前翻，不重复取已加载的页
    _pageCount = _loadedPages.isEmpty
        ? info.pagecount
        : _loadedPages.reduce((a, b) => a < b ? a : b);
    // 刷新拿到的新片单同样抢先预取封面，保持「打开即秒显」的体感
    unawaited(ImagePrefetch.prefetch(fresh.map((v) => v.pic).toList()));
    // 横屏 / 大屏列多时这几页可能整屏放得下 —— 没有滚动事件就等于「加载更多」永不
    // 触发，这里主动检查并续拉，修掉「打开就已经到底、上滑没反应」。
    _noGrowStreak = 0;
    _maybeContinueLoad();
    // 首屏画出来之后，后台把后面两页也先取回来（不阻塞首屏）
    unawaited(_warmUp(2));
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
      if (!mounted || _loading || _loadingMore || _pageCount <= 1) return;
      if (_loadMoreFailed) return;
      _loadingMore = true;
      final page = _pageCount;
      _pageCount--;
      var ok = true;
      try {
        await _appendPage(page);
        _loadedPages.add(page);
      } catch (_) {
        _pageCount++; // 失败不消耗页号
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
  /// 不在此处递归翻页——翻页节奏统一由调用方（_refresh / _loadMore）控制，
  /// 避免重复取页；重复 id 的条目也在此处直接跳过，作最后一层兜底。
  Future<void> _appendPage(int page, {List<Video>? sink}) async {
    if (page <= 0) return;
    final target = sink ?? _videos;
    final list = await HttpService.instance.fetchList(
      widget.site,
      pg: page,
      tid: widget.videoClass.tid,
      strict: true, // 失败要抛出，好让调用方区分「没更多」和「没取到」
    );
    await ListCache.putPage(
      widget.site.key,
      widget.videoClass.tid,
      page,
      list,
    );
    if (!mounted) return;
    final seen = <String>{for (final v in target) if (v.id.isNotEmpty) v.id};
    for (final v in list) {
      if (v.id.isNotEmpty && seen.contains(v.id)) continue; // 跳过重复 id
      target.add(v);
      if (v.id.isNotEmpty) seen.add(v.id);
    }
  }

  /// 滚动到底部时加载更早的分页。
  ///
  /// ⚠️ 两点易踩的坑都已修：
  /// 1) 取页（网络）异常必须用 try/finally 复位 `_loadingMore`，否则一旦某页失败，
  ///    该标志永久停在 true，后续所有加载都被 guard 拦掉——表现为「滑到某处就再也不动了」。
  ///    失败时回退 `_pageCount`，下次还能重试这一页。
  /// 2) 加载完若用户仍停在底部（静止、无新滚动事件），`_onScroll` 不会再触发，必须
  ///    「来回滑一下」才续拉。这里在成功贴底且列表确有增长时**自动续拉下一页**，
  ///    让到底即连续加载，不再需要手动划动。重复页（源站返回相同 id）不增长则不续拉，
  ///    避免对问题源站空转狂刷；`_pageCount` 一路递减到 1 自然收尾。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _pageCount <= 1) return;
    _loadingMore = true;
    if (_loadMoreFailed && mounted) {
      setState(() => _loadMoreFailed = false);
    }
    final before = _videos.length;
    _pageCount--;
    var ok = true;
    try {
      await _appendPage(_pageCount);
      _loadedPages.add(_pageCount);
    } catch (e) {
      _pageCount++; // 回退，待下次滚动重试本页
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
  /// 翻到第一页，或连续两页都没新增（源站在返回重复页）为止。
  void _maybeContinueLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_loading || _loadingMore || _pageCount <= 1) return;
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
        : buildVideoGrid(
            context: context,
            videos: _videos,
            scrollController: _scrollController,
            loadingMore: _loadingMore,
            onTap: widget.onTapVideo,
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
        // 已翻到第 1 页（没有更早的页可取了）就不再提示重试，避免点了没反应。
        if (_loadMoreFailed && !_loadingMore && _pageCount > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(child: _buildRetryTip()),
          ),
      ],
    );
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

