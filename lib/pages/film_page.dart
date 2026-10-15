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
    return Scaffold(
      appBar: AppBar(
        // 「首页」文字已去掉，原位改放网站切换 + 资源统计
        titleSpacing: 8,
        title: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickSite,
                icon: const Icon(Icons.language, size: 16),
                label: Text(
                  _site == null ? '未选择视频源' : '网站: ${_site!.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor:
                      isDark ? Colors.white70 : const Color(0xFF303133),
                  side: BorderSide(
                    color: isDark ? Colors.white24 : const Color(0xFFDCDFE6),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 36),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '共: $_activeRecordCount 资源',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white70 : const Color(0xFF909399),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildSearchEntry(),
          if (_site != null) _buildCategoryTabBar(),
          Expanded(
            child: _buildCategoryTabs(),
          ),
        ],
      ),
    );
  }

  /// 搜索入口：点击进入独立搜索页（展示历史记录 + 搜索结果）
  Widget _buildSearchEntry() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: InkWell(
        onTap: _openSearch,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            // 深色下用极暗面 + 描边，而不是把底色提亮（提亮整屏就发灰了）
            color: isDark ? AppColors.darkSurface : Colors.white,
            borderRadius: BorderRadius.circular(24),
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
    with AutomaticKeepAliveClientMixin {
  final List<Video> _videos = <Video>[];
  final ScrollController _scrollController = ScrollController();

  int _pageCount = 0;
  int _recordCount = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _showBackTop = false;

  /// 已加载的页号集合：用于「后台刷新」时只替换最新尾页、不抹掉用户已下滑加载的
  /// 更早页面，并让「加载更多」接着已加载的最早一页继续往前翻（不重复取页）。
  final Set<int> _loadedPages = <int>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final show = position.pixels > 800;
    if (show != _showBackTop && mounted) {
      setState(() => _showBackTop = show);
    }
    if (position.pixels >= position.maxScrollExtent - 400) {
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
    await _refresh();
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
      await _appendPage(page, sink: fresh);
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

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _pageCount <= 1) return;
    _loadingMore = true;
    _pageCount--;
    await _appendPage(_pageCount);
    _loadedPages.add(_pageCount);
    if (mounted) {
      setState(() => _loadingMore = false);
    } else {
      _loadingMore = false;
    }
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
      ],
    );
  }
}

/// 视频网格已抽到 widgets/video_grid.dart（VideoGridView / buildVideoGrid），
/// 首页分类页与搜索结果共用。

