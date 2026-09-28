import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../utils/constants.dart';
import '../widgets/common_widgets.dart';
import '../widgets/video_card.dart';
import 'detail_page.dart';

/// 首页：搜索 + 站点/分类切换 + 资源瀑布流
class FilmPage extends StatefulWidget {
  const FilmPage({super.key});

  @override
  State<FilmPage> createState() => FilmPageState();
}

class FilmPageState extends State<FilmPage> with AutomaticKeepAliveClientMixin {
  static const _latestClass = VideoClass(tid: '0', name: '最新');

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Video> _videos = <Video>[];

  Site? _site;
  List<VideoClass> _classes = <VideoClass>[_latestClass];
  VideoClass _currentClass = _latestClass;

  int _pageCount = 0;
  int _recordCount = 0;
  /// 已加载数据对应的「视频源 + 青少年模式」指纹，用于判断是否需要重新拉取
  String _signature = '';
  bool _loading = false;
  bool _loadingMore = false;
  bool _isSearchMode = false;
  bool _showBackTop = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    reload();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final show = position.pixels > 800;
    if (show != _showBackTop && mounted) {
      setState(() => _showBackTop = show);
    }
    // 触底加载更多
    if (position.pixels >= position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  String get _currentSignature {
    final state = context.read<AppState>();
    return '${state.activeSites.map((s) => s.key).join(',')}|${state.config.r18}';
  }

  /// 视频源或青少年模式改动过时才重新拉取（切换 tab 时调用）
  Future<void> reloadIfNeeded() async {
    if (_signature != _currentSignature) {
      await reload();
    }
  }

  /// 重新载入（切换 tab、修改了视频源后调用）
  Future<void> reload() async {
    if (!mounted) return;
    _signature = _currentSignature;
    final state = context.read<AppState>();
    final sites = state.activeSites;
    if (sites.isEmpty) {
      setState(() {
        _site = null;
        _videos.clear();
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _videos.clear();
    _isSearchMode = false;
    _searchController.clear();
    _site = sites.first;
    _currentClass = _latestClass;
    _classes = <VideoClass>[_latestClass];

    await _loadClasses();
    await _loadPageInfo();
    await _appendPage(_pageCount);
    if (_pageCount > 1) {
      _pageCount--;
      await _appendPage(_pageCount);
    }
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
  }

  Future<void> _loadPageInfo() async {
    if (_site == null) return;
    final info =
        await HttpService.instance.fetchPage(_site!, tid: _currentClass.tid);
    if (!mounted) return;
    setState(() {
      _pageCount = info.pagecount;
      _recordCount = info.recordcount;
    });
  }

  /// 青少年模式下过滤命中的条目
  bool _shouldHide(Video video) {
    final r18 = context.read<AppState>().config.r18;
    if (!r18) return false;
    return AppConstants.r18KeyWords
        .any((word) => video.name.contains(word) || video.type.contains(word));
  }

  Future<void> _appendPage(int page) async {
    if (page <= 0 || _site == null) return;
    final list = await HttpService.instance.fetchList(
      _site!,
      pg: page,
      tid: _currentClass.tid,
    );
    if (!mounted) return;
    final filtered = list.where((v) => !_shouldHide(v)).toList();
    setState(() {
      _videos.addAll(filtered);
    });
    // 数据过少时继续往前翻一页（与 uni-app 版行为一致）
    if (_videos.length <= 6 && page > 1) {
      _pageCount--;
      await _appendPage(_pageCount);
    }
  }

  Future<void> _loadMore() async {
    if (_isSearchMode || _loadingMore || _loading || _site == null) return;
    if (_pageCount <= 1) return;
    _loadingMore = true;
    _pageCount--;
    await _appendPage(_pageCount);
    if (mounted) {
      setState(() => _loadingMore = false);
    } else {
      _loadingMore = false;
    }
  }

  Future<void> _onSearch(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty || _site == null) return;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    final list = await HttpService.instance.search(_site!, kw);
    if (!mounted) return;
    setState(() {
      _videos
        ..clear()
        ..addAll(list.where((v) => !_shouldHide(v)));
      _isSearchMode = true;
      _loading = false;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    if (!_isSearchMode) return;
    reload();
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
    setState(() => _loading = true);
    _site = picked;
    _currentClass = _latestClass;
    _classes = <VideoClass>[_latestClass];
    _videos.clear();
    _isSearchMode = false;
    _searchController.clear();
    await _loadClasses();
    await _loadPageInfo();
    await _appendPage(_pageCount);
    if (_pageCount > 1) {
      _pageCount--;
      await _appendPage(_pageCount);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickClass() async {
    final picked = await showPicker<VideoClass>(
      context: context,
      title: '选择分类',
      items: _classes,
      selected: _currentClass,
      labelBuilder: (c) => c.name,
    );
    if (picked == null || picked.tid == _currentClass.tid) return;
    setState(() => _loading = true);
    _currentClass = picked;
    _videos.clear();
    _isSearchMode = false;
    _searchController.clear();
    await _loadPageInfo();
    await _appendPage(_pageCount);
    if (_pageCount > 1) {
      _pageCount--;
      await _appendPage(_pageCount);
    }
    if (mounted) setState(() => _loading = false);
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
    return Scaffold(
      appBar: AppBar(title: const Text('首页')),
      body: LoadingMask(
        visible: _loading,
        child: Column(
          children: [
            _buildSearchBar(),
            _buildToolbar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      floatingActionButton: _showBackTop
          ? FloatingActionButton.small(
              heroTag: 'filmBackTop',
              onPressed: () => _scrollController.animateTo(
                0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              ),
              child: const Icon(Icons.arrow_upward),
            )
          : null,
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onSubmitted: _onSearch,
        decoration: InputDecoration(
          hintText: '搜索影片',
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _clearSearch,
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    if (_site == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _pickSite,
              child: Text(
                '网站: ${_site!.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: _pickClass,
              child: Text(
                '分类: ${_currentClass.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '共: $_recordCount 资源',
            style: const TextStyle(fontSize: 12, color: Color(0xFF909399)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_site == null) {
      return const EmptyHint(
        message: '暂无可用视频源\n请到「我 - 视频源管理」中启用或导入视频源',
        icon: Icons.video_library_outlined,
      );
    }
    if (_videos.isEmpty && !_loading) {
      return EmptyHint(
        message: _isSearchMode ? '没有搜索到相关资源' : '该分类下暂无资源',
        icon: Icons.search_off,
      );
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 16),
        itemCount: _videos.length + (_loadingMore ? 1 : 0),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          childAspectRatio: 0.62,
          crossAxisSpacing: 0,
          mainAxisSpacing: 0,
        ),
        itemBuilder: (context, index) {
          if (index >= _videos.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final video = _videos[index];
          return VideoCard(video: video, onTap: () => _openDetail(video));
        },
      ),
    );
  }
}
