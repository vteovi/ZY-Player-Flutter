import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
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
  void _initTabs(int length) {
    if (_tabController.length == length) return;
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _tabController = TabController(length: length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _lastTabIndex = _tabController.index;
  }

  String get _currentSignature {
    final state = context.read<AppState>();
    return '${state.activeSites.map((s) => s.key).join(',')}|${state.config.r18}';
  }

  /// 视频源或青少年模式改动过时才重新拉取（切换 tab 时调用）
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
      _initTabs(_classes.length);
      return;
    }
    setState(() {
      _loading = true;
      _recordCounts.clear();
    });
    _site = sites.first;
    _classes = <VideoClass>[_latestClass];
    _initTabs(_classes.length);
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
    _initTabs(_classes.length);
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
      _classes = <VideoClass>[_latestClass];
      _recordCounts.clear();
    });
    _initTabs(_classes.length);
    await _loadClasses();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchPage(site: _site)),
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

  /// 青少年模式下过滤命中的条目
  static bool _matchesR18(Video video, bool r18) {
    if (!r18) return false;
    return AppConstants.r18KeyWords
        .any((word) => video.name.contains(word) || video.type.contains(word));
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
            color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
            borderRadius: BorderRadius.circular(24),
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
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final r18 = context.read<AppState>().config.r18;
    return TabBarView(
      controller: _tabController,
      children: _classes
          .map(
            (c) => CategoryTab(
              key: Key('${_site!.key}-${c.tid}'),
              site: _site!,
              videoClass: c,
              r18: r18,
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
  final bool r18;
  final void Function(String tid, int count) onRecordCount;
  final void Function(Video video) onTapVideo;

  const CategoryTab({
    super.key,
    required this.site,
    required this.videoClass,
    required this.r18,
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
    final filtered =
        list.where((v) => !FilmPageState._matchesR18(v, widget.r18)).toList();
    setState(() => _videos.addAll(filtered));
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
    return Stack(
      children: [
        LoadingMask(
          visible: _loading,
          child: buildVideoGrid(
            context: context,
            videos: _videos,
            scrollController: _scrollController,
            loadingMore: _loadingMore,
            onTap: widget.onTapVideo,
          ),
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

