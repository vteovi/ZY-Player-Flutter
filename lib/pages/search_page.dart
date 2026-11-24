import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site.dart';
import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../widgets/common_widgets.dart';
import '../widgets/video_grid.dart';
import 'detail_page.dart';

/// 搜索范围：全部站点 / 当前站点 / 收藏 / 历史记录
enum _SearchScope { all, current, favorites, history }

/// 一条搜索结果：来自哪个源 + 影片。
///
/// 收藏 / 历史范围下的结果来自本地记录，站点可能已被删除：
/// 此时 [siteName] 为 null（不显示角标），[siteKey] 仍保留以便打开详情。
class _Hit {
  final String siteKey;
  final String? siteName;
  final Video video;

  const _Hit({
    required this.siteKey,
    this.siteName,
    required this.video,
  });
}

/// 搜索页：顶部输入框 + 搜索范围切换 + 搜索历史 + 结果网格。
///
/// - 全部站点 / 当前站点：走网络聚合搜索（分批并发），结果带来源角标。
/// - 收藏 / 历史记录：直接从内存里的记录过滤，不走网络、瞬间出结果。
class SearchPage extends StatefulWidget {
  /// 进入搜索页前正在浏览的站点，供「当前站点」范围使用。
  /// 首页还没选源时为 null，该选项会置灰。
  final Site? currentSite;

  const SearchPage({super.key, this.currentSite});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  /// 当前搜索范围，默认全部站点
  _SearchScope _scope = _SearchScope.all;

  /// 搜索代次：重新搜索 / 清空时 +1，旧请求的回调直接丢弃
  int _searchGen = 0;

  bool _searched = false;
  bool _loading = false;
  int _done = 0;
  int _total = 0;
  final List<_Hit> _results = <_Hit>[];
  List<String> _history = <String>[];

  /// 「边打边搜」的防抖计时器：停止输入一小会儿才真正发请求
  Timer? _debounce;

  /// 上一次真正发起搜索的关键词，用于跳过「内容没变」的重复触发
  /// （比如只是移动光标、或者清空后又输入同样的字）
  String _lastKeyword = '';

  /// 防抖间隔。太短会每敲一个字都去轮一遍所有源；太长会顿。
  /// 中文走输入法时 composing 期间本来就不触发，这里主要兜英文 / 数字。
  static const Duration _debounceDelay = Duration(milliseconds: 450);

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
    _debounce?.cancel();
    _searchGen++; // 让还在路上的旧搜索结果失效
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // 切换清除按钮显隐 + 触发边打边搜
    setState(() {});
    _scheduleSearch();
  }

  /// 输入变化后安排一次「边打边搜」。
  ///
  /// 三种情况不搜：输入法还在拼（composing 未落字）、内容没变、已清空。
  void _scheduleSearch() {
    _debounce?.cancel();
    // 中文输入法拼写到一半时 text 是半截拼音 / 候选字，搜出来毫无意义，
    // 等 composing 结束（真正落字）监听会再触发一次
    if (_controller.value.composing.isValid) return;
    final kw = _controller.text.trim();
    if (kw.isEmpty) {
      if (_searched) _backToHistory();
      return;
    }
    if (kw == _lastKeyword) return;
    _debounce = Timer(
      _debounceDelay,
      () => _doSearch(kw, typeahead: true),
    );
  }

  Future<void> _loadHistory() async {
    final list = await Provider.of<AppState>(context, listen: false)
        .getSearchHistory();
    if (mounted) setState(() => _history = list);
  }

  /// 当前范围下的输入框提示语
  String get _hintText => switch (_scope) {
        _SearchScope.all => '搜索全部视频源',
        _SearchScope.current => '搜索当前视频源',
        _SearchScope.favorites => '搜索我的收藏',
        _SearchScope.history => '搜索历史记录',
      };

  /// 切范围后，如果已经搜过且输入框有词，立刻用新范围重搜
  void _changeScope(_SearchScope scope) {
    if (scope == _scope) return;
    setState(() => _scope = scope);
    final kw = _controller.text.trim();
    // 走 typeahead 分支：结果等新范围的第一批回来再整体替换，不清空闪一下，
    // 也不重复写搜索历史
    if (_searched && kw.isNotEmpty) _doSearch(kw, typeahead: true);
  }

  /// 执行搜索。
  ///
  /// [typeahead] = true 表示由「边打边搜」触发：不记搜索历史（否则每敲一个
  /// 字就塞一条半截关键词）、不动输入焦点（否则键盘一收就没法继续打）。
  /// 两种触发方式都沿用同一套「旧结果留到第一批新结果到达才替换」的策略，
  /// 避免列表闪空白。
  Future<void> _doSearch(String rawKeyword, {bool typeahead = false}) async {
    _debounce?.cancel();
    final kw = rawKeyword.trim();
    if (kw.isEmpty) return;
    // 彻底取消搜索框焦点（而非只上移一级），否则从详情页返回时
    // Flutter 会恢复"最后聚焦节点"又把键盘弹出来
    if (!typeahead) _focusNode.unfocus();
    _lastKeyword = kw;
    final app = Provider.of<AppState>(context, listen: false);
    if (!typeahead) {
      await app.addSearchKeyword(kw);
      await _loadHistory();
    }

    final gen = ++_searchGen;
    final scope = _scope;

    // ---- 收藏 / 历史：本地记录过滤，不走网络 ----
    if (scope == _SearchScope.favorites || scope == _SearchScope.history) {
      final source =
          scope == _SearchScope.favorites ? app.stars : app.histories;
      final lower = kw.toLowerCase();
      final hits = <_Hit>[];
      for (final item in source) {
        // 匹配片名、最近集名、分类、备注、年份、地区、演员、导演
        final haystack = [
          item.name,
          item.label,
          item.type,
          item.note,
          item.year,
          item.area,
          item.actor,
          item.director,
        ].join(' ').toLowerCase();
        if (!haystack.contains(lower)) continue;
        final siteKey = app.resolveRecordKey(item.key).first;
        hits.add(_Hit(
          siteKey: siteKey,
          siteName: app.siteOf(siteKey)?.name,
          video: item,
        ));
      }
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _searched = true;
        _loading = false;
        _done = 0;
        _total = 0;
        _results
          ..clear()
          ..addAll(hits);
      });
      return;
    }

    // ---- 全部站点 / 当前站点：走网络聚合搜索 ----
    final sites = scope == _SearchScope.current
        ? (widget.currentSite == null
            ? <Site>[]
            : <Site>[widget.currentSite!])
        : app.activeSites;
    if (mounted) {
      setState(() {
        _searched = true;
        _loading = true;
        _done = 0;
        _total = sites.length;
      });
    }
    if (sites.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // 旧结果一直留到第一批新结果到达的那一刻再整体换掉。
    // 边打边搜时这样不会每敲一个字就闪一下空白；明确点搜索时也是
    // 「先看着旧结果、新结果到了再换」，比瞬间清空舒服。
    var replaced = false;

    // 分批并发：每批完成后立刻合并刷新，结果陆续出现
    for (var i = 0; i < sites.length; i += _batchSize) {
      final end = math.min(i + _batchSize, sites.length);
      final chunk = sites.sublist(i, end);
      final batches = await Future.wait(
        chunk.map((site) async {
          try {
            final list = await HttpService.instance.search(site, kw);
            return list
                .map((v) => _Hit(
                      siteKey: site.key,
                      siteName: site.name,
                      video: v,
                    ))
                .toList();
          } catch (_) {
            return <_Hit>[];
          }
        }),
      );
      if (!mounted || gen != _searchGen) return;
      setState(() {
        if (!replaced) {
          _results.clear();
          replaced = true;
        }
        _results
          ..addAll(batches.expand((x) => x));
        _done = end;
      });
    }
    if (mounted && gen == _searchGen) {
      setState(() => _loading = false);
    }
  }

  /// 清空输入框并回到历史视图（输入框右侧的 ×）
  void _resetToHistory() {
    // clear() 会触发监听 → 见空文本自动回历史视图，这里只管清焦点
    _controller.clear();
    _focusNode.unfocus();
    _backToHistory();
  }

  /// 只把结果区切回历史视图，**不碰输入框**。
  ///
  /// 边打边搜把字删光时走这里：如果在这里再调 `_controller.clear()`，
  /// 会同步触发文本监听 → 又回到这里，形成递归。
  void _backToHistory() {
    _debounce?.cancel();
    _searchGen++; // 作废进行中的搜索
    _lastKeyword = '';
    if (!mounted) return;
    setState(() {
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
        if (hit.siteKey.isEmpty) return;
        // 离开搜索页前先清掉搜索框焦点，避免从详情页 pop 回来时
        // Flutter 恢复焦点又把键盘弹出来
        _focusNode.unfocus();
        Navigator.of(context)
            .push(
          MaterialPageRoute(
            builder: (_) =>
                DetailPage(siteKey: hit.siteKey, videoId: video.id),
          ),
        )
            .then((_) {
          // 兜底：返回后确保键盘不自动弹出
          if (mounted) _focusNode.unfocus();
        });
        return;
      }
    }
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
            hintText: _hintText,
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
      body: Column(
        children: [
          _buildScopeBar(),
          Expanded(
            child: _searched
                ? _buildResultBody(isDark)
                : _buildHistoryBody(isDark),
          ),
        ],
      ),
    );
  }

  /// 搜索范围切换条：窄屏自动换行，当前站点未选时置灰
  Widget _buildScopeBar() {
    Widget chip(_SearchScope scope, String label) {
      final unavailable =
          scope == _SearchScope.current && widget.currentSite == null;
      return ChoiceChip(
        label: Text(label),
        selected: _scope == scope,
        showCheckmark: false,
        onSelected: unavailable ? null : (_) => _changeScope(scope),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        tooltip: scope == _SearchScope.current && widget.currentSite != null
            ? '当前站点：${widget.currentSite!.name}'
            : null,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        children: [
          chip(_SearchScope.all, '全部站点'),
          chip(
            _SearchScope.current,
            widget.currentSite == null ? '当前站点(未选)' : '当前站点',
          ),
          chip(_SearchScope.favorites, '收藏'),
          chip(_SearchScope.history, '历史'),
        ],
      ),
    );
  }

  /// 按范围给出空结果提示
  String get _emptyHint {
    if (_scope == _SearchScope.favorites) return '收藏里没有匹配的影片';
    if (_scope == _SearchScope.history) return '历史记录里没有匹配的影片';
    if (_total == 0) {
      return _scope == _SearchScope.current
          ? '请先在首页选择一个视频源'
          : '暂无启用的视频源，请先在源管理中开启';
    }
    return _scope == _SearchScope.current
        ? '当前站点没有搜到相关资源'
        : '所有源都没有搜到相关资源';
  }

  Widget _buildResultBody(bool isDark) {
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
      return EmptyHint(message: _emptyHint, icon: Icons.search_off);
    }
    return Column(
      children: [
        // 搜索进行中的进度条（结果已陆续展示）
        if (_loading && _total > 0)
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
                if (identical(hit.video, video)) return hit.siteName;
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
