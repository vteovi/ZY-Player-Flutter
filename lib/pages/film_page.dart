import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../utils/app_colors.dart';
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
    reload();
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
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

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _videos.clear();
    });
    final info =
        await HttpService.instance.fetchPage(widget.site, tid: widget.videoClass.tid);
    if (!mounted) return;
    setState(() {
      _pageCount = info.pagecount;
      _recordCount = info.recordcount;
    });
    widget.onRecordCount(widget.videoClass.tid, _recordCount);
    await _appendPage(_pageCount);
    if (_pageCount > 1) {
      _pageCount--;
      await _appendPage(_pageCount);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _appendPage(int page) async {
    if (page <= 0) return;
    final list = await HttpService.instance.fetchList(
      widget.site,
      pg: page,
      tid: widget.videoClass.tid,
    );
    if (!mounted) return;
    setState(() => _videos.addAll(list));
    if (_videos.length <= 6 && page > 1) {
      _pageCount--;
      await _appendPage(_pageCount);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _pageCount <= 1) return;
    _loadingMore = true;
    _pageCount--;
    await _appendPage(_pageCount);
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

