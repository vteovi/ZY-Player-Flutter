import 'dart:math' as math;

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

/// 一条搜索结果：来自哪个源 + 影片
class _Hit {
  final Site site;
  final Video video;
  const _Hit(this.site, this.video);
}

/// 搜索页：顶部输入 + 历史搜索记录（可点选/删除/清空）+ 搜索结果网格。
/// 从首页搜索框点击进入，搜索范围为**全部启用的视频源**（聚合搜索）：
/// 分批并发请求，各源结果陆续合并展示，结果卡片带来源角标。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  /// 搜索代次：重新搜索 / 清空时 +1，旧请求的回调直接丢弃
  int _searchGen = 0;

  bool _searched = false;
  bool _loading = false;
  int _done = 0;
  int _total = 0;
  final List<_Hit> _results = <_Hit>[];
  List<String> _history = <String>[];

  /// 同时请求的源数量
  static const int _batchSize = 12;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _loadHistory();
    // 进入页面自动聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchGen++; // 让还在路上的旧搜索结果失效
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // 仅用于切换清除按钮显隐
    setState(() {});
  }

  Future<void> _loadHistory() async {
    final list = await Provider.of<AppState>(context, listen: false)
        .getSearchHistory();
    if (mounted) setState(() => _history = list);
  }

  Future<void> _doSearch(String rawKeyword) async {
    final kw = rawKeyword.trim();
    if (kw.isEmpty) return;
    FocusScope.of(context).unfocus();
    final app = Provider.of<AppState>(context, listen: false);
    await app.addSearchKeyword(kw);
    await _loadHistory();

    final sites = app.activeSites;
    final gen = ++_searchGen;
    if (mounted) {
      setState(() {
        _searched = true;
        _loading = true;
        _done = 0;
        _total = sites.length;
        _results.clear();
      });
    }
    if (sites.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final r18 = app.config.r18;
    // 分批并发：每批完成后立刻合并刷新，结果陆续出现
    for (var i = 0; i < sites.length; i += _batchSize) {
      final end = math.min(i + _batchSize, sites.length);
      final chunk = sites.sublist(i, end);
      final batches = await Future.wait(
        chunk.map((site) async {
          try {
            final list = await HttpService.instance.search(site, kw);
            return list
                .where((v) => !_matchesR18(v, r18))
                .map((v) => _Hit(site, v))
                .toList();
          } catch (_) {
            return <_Hit>[];
          }
        }),
      );
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _results.addAll(batches.expand((x) => x));
        _done = end;
      });
    }
    if (mounted && gen == _searchGen) {
      setState(() => _loading = false);
    }
  }

  /// 清空输入框并回到历史视图
  void _resetToHistory() {
    _searchGen++; // 作废进行中的搜索
    _controller.clear();
    FocusScope.of(context).unfocus();
    if (mounted) setState(() {
      _searched = false;
      _results.clear();
      _loading = false;
    });
  }

  Future<void> _clearHistory() async {
    await Provider.of<AppState>(context, listen: false).clearSearchHistory();
    await _loadHistory();
  }

  Future<void> _removeHistory(String word) async {
    await Provider.of<AppState>(context, listen: false)
        .removeSearchKeyword(word);
    await _loadHistory();
  }

  void _openDetail(Video video) {
    // VideoCard 持有的就是 _results 里的同一对象，按对象身份找回所属源
    for (final hit in _results) {
      if (identical(hit.video, video)) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                DetailPage(siteKey: hit.site.key, videoId: video.id),
          ),
        );
        return;
      }
    }
  }

  /// 青少年模式下过滤命中的条目（与首页一致）
  static bool _matchesR18(Video video, bool r18) {
    if (!r18) return false;
    return AppConstants.r18KeyWords
        .any((word) => video.name.contains(word) || video.type.contains(word));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          textInputAction: TextInputAction.search,
          onSubmitted: _doSearch,
          decoration: InputDecoration(
            hintText: '搜索全部视频源',
            hintStyle: TextStyle(
              color: isDark ? Colors.white54 : Colors.black54,
            ),
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _resetToHistory,
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _doSearch(_controller.text),
            child: const Text('搜索'),
          ),
        ],
      ),
      body: _searched ? _buildResultBody(isDark) : _buildHistoryBody(isDark),
    );
  }

  Widget _buildResultBody(bool isDark) {
    if (_total == 0) {
      return const EmptyHint(
        message: '暂无启用的视频源，请先在源管理中开启',
        icon: Icons.video_library_outlined,
      );
    }
    if (_loading && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              '正在搜索 $_done/$_total 个源…',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return const EmptyHint(
        message: '所有源都没有搜到相关资源',
        icon: Icons.search_off,
      );
    }
    return Column(
      children: [
        // 搜索进行中的进度条（结果已陆续展示）
        if (_loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: _total == 0 ? null : _done / _total,
                    minHeight: 2,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$_done/$_total 源',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: buildVideoGrid(
            context: context,
            videos: _results.map((h) => h.video).toList(),
            scrollController: _scrollController,
            labelOf: (video) {
              for (final hit in _results) {
                if (identical(hit.video, video)) return hit.site.name;
              }
              return null;
            },
            onTap: _openDetail,
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryBody(bool isDark) {
    if (_history.isEmpty) {
      return const EmptyHint(
        message: '还没有搜索记录',
        icon: Icons.history,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(
              '搜索历史',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : const Color(0xFF303133),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _clearHistory,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _history
              .map(
                (word) => InputChip(
                  label: Text(word),
                  onPressed: () {
                    _controller.text = word;
                    _doSearch(word);
                  },
                  onDeleted: () => _removeHistory(word),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}
