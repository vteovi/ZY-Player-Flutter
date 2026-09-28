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

/// 搜索页：顶部输入 + 历史搜索记录（可点选/删除/清空）+ 搜索结果网格。
/// 从首页搜索框点击进入，带入当前选中的视频源。
class SearchPage extends StatefulWidget {
  final Site? site;

  const SearchPage({super.key, this.site});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  Site? _site;
  bool _searched = false;
  bool _loading = false;
  List<Video> _results = <Video>[];
  List<String> _history = <String>[];

  @override
  void initState() {
    super.initState();
    _site = widget.site ??
        Provider.of<AppState>(context, listen: false).activeSites.firstOrNull;
    _controller.addListener(_onTextChanged);
    _loadHistory();
    // 进入页面自动聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
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
    if (_site == null) {
      if (mounted) {
        setState(() {
          _searched = true;
          _loading = false;
          _results = <Video>[];
        });
      }
      return;
    }
    if (mounted) setState(() => _loading = true);
    final list = await HttpService.instance.search(_site!, kw);
    if (!mounted) return;
    final r18 = app.config.r18;
    setState(() {
      _results = list.where((v) => !_matchesR18(v, r18)).toList();
      _loading = false;
      _searched = true;
    });
  }

  /// 清空输入框并回到历史视图
  void _resetToHistory() {
    _controller.clear();
    FocusScope.of(context).unfocus();
    if (mounted) setState(() {
      _searched = false;
      _results = <Video>[];
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
    if (_site == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailPage(siteKey: _site!.key, videoId: video.id),
      ),
    );
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
            hintText: '搜索影片',
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_site == null) {
      return const EmptyHint(
        message: '请先在首页选择视频源后再搜索',
        icon: Icons.video_library_outlined,
      );
    }
    if (_results.isEmpty) {
      return const EmptyHint(
        message: '没有搜索到相关资源',
        icon: Icons.search_off,
      );
    }
    return buildVideoGrid(
      context: context,
      videos: _results,
      scrollController: _scrollController,
      onTap: _openDetail,
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
