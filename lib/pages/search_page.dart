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

  const _Hit({required this.siteKey, this.siteName, required this.video});
}

/// 一个源的分页进度：滑到底时据此决定还能不能拉下一页。
///
/// maccms 的搜索接口每页固定 20 条（站点默认值），只请求第一页就是
/// 「每个源最多 20 条」的原因，所以要一页页往下续。
class _SourcePaging {
  /// 已经加载到第几页（1 = 只加载了第一页）
  int loadedPage = 1;

  /// 站点声明的每页条数
  int pageSize;

  /// 站点声明的总页数，0 = 未知
  int pagecount;

  /// 正在请求下一页（同一源不重复发请求）
  bool loading = false;

  /// 已经确认没有更多了
  bool exhausted = false;

  _SourcePaging({required this.pageSize, required this.pagecount});

  bool get canLoadMore => !loading && !exhausted;
}

/// 搜索页：顶部输入框 + 搜索范围切换 + 搜索历史 + 结果网格。
///
/// - 全部站点 / 当前站点：走网络聚合搜索（分批并发），结果带来源角标。
/// - 收藏 / 历史记录：直接从内存里的记录过滤，不走网络、瞬间出结果。
class SearchPage extends StatefulWidget {
  /// 进入搜索页前正在浏览的站点，供「当前站点」范围使用。
  /// 首页还没选源时为 null，该选项会置灰。
  final Site? currentSite;

  /// 带词进入时直接搜这个词（收藏页「搜索该影片」用）。
  /// 为空则维持原来的行为：聚焦输入框、显示搜索历史。
  final String? initialKeyword;

  const SearchPage({super.key, this.currentSite, this.initialKeyword});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 结果区「全部 / 各来源」的水平分页：左右滑动即可切换来源。
  final PageController _pager = PageController();

  /// 标签条自己的横向滚动。源多的时候当前标签会被挤出屏幕，
  /// 翻页时要把它捞回可视区，否则看不出「现在是哪一页」。
  final ScrollController _chipsScroll = ScrollController();

  /// 每个标签的 key，供 [Scrollable.ensureVisible] 定位
  final Map<String, GlobalKey> _chipKeys = <String, GlobalKey>{};

  /// 当前选中的来源；null 表示「全部」
  String? _filterKey;

  static const String _allChipId = '__all__';

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

  /// 当前搜索词。加载下一页时要用它，不能现读输入框 ——
  /// 用户搜完可能又改了输入框但没提交。
  String _keyword = '';

  /// 各来源的分页进度，key = siteKey。
  final Map<String, _SourcePaging> _paging = <String, _SourcePaging>{};

  /// 「全部」页滑到底时轮流给各源加载下一页，这个游标记住轮到谁。
  int _allCursor = 0;

  /// 单个源最多自动加载到第几页（每页 20 条，约 400 条封顶）。
  /// 站点若忽视页码参数会被「整页重复」判到底，这里是第二道保险。
  static const int _maxPagePerSource = 20;

  /// 同时在跑的搜索请求上限。每个源各自独立跑，谁先回来就先展示谁，
  /// 这里只限制总并发，避免 20 多个源一起把网络打满。
  static const int _concurrency = 12;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initial = widget.initialKeyword?.trim() ?? '';
      if (initial.isEmpty) {
        // 常规进入：聚焦输入框，显示搜索历史
        _focusNode.requestFocus();
        return;
      }
      // 从收藏页带片名进来：填好词立刻搜，省得用户再点一次
      _controller.text = initial;
      _doSearch(initial);
    });
  }

  @override
  void dispose() {
    _searchGen++; // 让还在路上的旧搜索结果失效
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _pager.dispose();
    _chipsScroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // 仅用于切换清除按钮显隐
    setState(() {});
  }

  Future<void> _loadHistory() async {
    final list = await Provider.of<AppState>(
      context,
      listen: false,
    ).getSearchHistory();
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
    if (_searched && kw.isNotEmpty) _doSearch(kw);
  }

  Future<void> _doSearch(String rawKeyword) async {
    final kw = rawKeyword.trim();
    if (kw.isEmpty) return;
    // 彻底取消搜索框焦点（而非只上移一级），否则从详情页返回时
    // Flutter 会恢复"最后聚焦节点"又把键盘弹出来
    _focusNode.unfocus();
    final app = Provider.of<AppState>(context, listen: false);
    await app.addSearchKeyword(kw);
    await _loadHistory();

    final gen = ++_searchGen;
    final scope = _scope;
    _keyword = kw;

    // ---- 收藏 / 历史：本地记录过滤，不走网络 ----
    if (scope == _SearchScope.favorites || scope == _SearchScope.history) {
      final source = scope == _SearchScope.favorites
          ? app.stars
          : app.histories;
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
        hits.add(
          _Hit(
            siteKey: siteKey,
            siteName: app.siteOf(siteKey)?.name,
            video: item,
          ),
        );
      }
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _searched = true;
        _loading = false;
        _done = 0;
        _total = 0;
        _filterKey = null;
        // 本地记录过滤没有「下一页」，分页进度一并清掉，免得残留上一轮的状态
        _paging.clear();
        _results
          ..clear()
          ..addAll(hits);
      });
      _jumpToAll();
      return;
    }

    // ---- 全部站点 / 当前站点：走网络聚合搜索 ----
    final sites = scope == _SearchScope.current
        ? (widget.currentSite == null ? <Site>[] : <Site>[widget.currentSite!])
        : app.activeSites;
    if (mounted) {
      setState(() {
        _searched = true;
        _loading = true;
        _done = 0;
        _total = sites.length;
        // 新关键词：旧结果立刻清掉，下面来一个源显示一个源
        _results.clear();
        // 每个源的分页进度也归零，否则新关键词会沿上一轮的页码继续翻
        _paging.clear();
        _allCursor = 0;
        // 上一轮的来源筛选也一并复位：新结果的来源集合和上一轮对不上，
        // 停在某个源上会「空白一页」。
        _filterKey = null;
      });
      _jumpToAll();
    }
    if (sites.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // 每个源各自独立跑，**谁先回来就立刻把它的结果追加进列表**。
    // 以前是「一批 12 个源 Future.wait 完再统一刷新」，于是第一个源
    // 300ms 就回来了也得等这批里最慢的那个，看起来就像"搜一阵子再一起出"。
    // 现在只用一个游标 + 固定数量的 worker 轮流领站点：完成一个、显示一个、
    // 游标再往前挪一个，总并发仍受 [_concurrency] 限制。
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= sites.length) return;
        final site = sites[index];
        final hits = <_Hit>[];
        SearchPageResult? res;
        try {
          // 只拿第一页（maccms 默认 20 条），后面的页由用户滑到底时按需加载
          res = await HttpService.instance.searchPaged(site, kw);
          for (final v in res.videos) {
            hits.add(_Hit(siteKey: site.key, siteName: site.name, video: v));
          }
        } catch (_) {
          // 单个源失败（超时 / 404 / 解析失败）不该影响其他源的结果
        }
        // 换了关键词或退出页面了，这个源的结果直接丢掉
        if (!mounted || gen != _searchGen) return;
        final result = res;
        setState(() {
          if (hits.isNotEmpty) {
            _appendSourceHits(site.key, hits);
            _paging[site.key] = _SourcePaging(
              pageSize: result?.pageSize ?? 20,
              pagecount: result?.pagecount ?? 0,
            )..exhausted = !(result?.hasMore ?? false);
          }
          _done++;
        });
      }
    }

    await Future.wait(
      List<Future<void>>.generate(
        math.min(_concurrency, sites.length),
        (_) => worker(),
      ),
    );
    if (mounted && gen == _searchGen) {
      setState(() => _loading = false);
    }
  }

  /// 把某个源的这批结果插到**该源已有结果的末尾**，而不是整个列表末尾。
  ///
  /// 首次搜索时每个源只有一批，插哪儿都一样；但加载第二页时若直接 addAll，
  /// 「全部」页里同一个源会被拆成前后两段，滑起来很乱。
  void _appendSourceHits(String siteKey, List<_Hit> hits) {
    if (hits.isEmpty) return;
    var at = _results.length;
    for (var i = _results.length - 1; i >= 0; i--) {
      if (_results[i].siteKey == siteKey) {
        at = i + 1;
        break;
      }
    }
    _results.insertAll(at, hits);
  }

  /// 按 key 找源。结果里可能还留着刚被停用/删除的源，所以先查启用列表再查全集。
  Site? _siteOf(String key) {
    final app = Provider.of<AppState>(context, listen: false);
    for (final s in app.activeSites) {
      if (s.key == key) return s;
    }
    for (final s in app.sites) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// 给某个源加载下一页并追加到结果里。
  Future<void> _loadMore(String siteKey) async {
    final state = _paging[siteKey];
    if (state == null || !state.canLoadMore) return;
    if (state.loadedPage >= _maxPagePerSource) {
      setState(() => state.exhausted = true);
      return;
    }
    final site = _siteOf(siteKey);
    if (site == null) return;
    final gen = _searchGen;
    setState(() => state.loading = true);

    SearchPageResult? res;
    try {
      res = await HttpService.instance.searchPaged(
        site,
        _keyword,
        pg: state.loadedPage + 1,
      );
    } catch (_) {
      res = null;
    }
    if (!mounted || gen != _searchGen) return;
    setState(() {
      state.loading = false;
      // 请求失败不标记到底：用户下次滑到底还会再试一次
      if (res == null) return;
      // 去重：有些站对 pg 视而不见，第二页还是第一页的内容
      final known = <String>{};
      for (final h in _results) {
        if (h.siteKey == siteKey) known.add(h.video.id);
      }
      final fresh = <_Hit>[];
      for (final v in res.videos) {
        if (known.add(v.id)) {
          fresh.add(_Hit(siteKey: siteKey, siteName: site.name, video: v));
        }
      }
      if (fresh.isEmpty) {
        // 整页都是已有的 → 这个站翻不动了，别再请求
        state.exhausted = true;
        return;
      }
      _appendSourceHits(siteKey, fresh);
      state.loadedPage++;
      state.pageSize = res.pageSize;
      state.pagecount = res.pagecount;
      if (!res.hasMore) state.exhausted = true;
    });
  }

  /// 「全部」页滑到底：按来源顺序轮流给一个还有下一页的源加载。
  ///
  /// 一次只拉一个源。二十多个源同时翻页会把网络打满，而用户此刻只是
  /// 想再多看一点，不需要每个源都补齐。
  Future<void> _loadMoreForAll() async {
    final order = _sourceOrder;
    if (order.isEmpty) return;
    for (var step = 0; step < order.length; step++) {
      final i = (_allCursor + step) % order.length;
      final state = _paging[order[i]];
      if (state == null || !state.canLoadMore) continue;
      _allCursor = (i + 1) % order.length;
      await _loadMore(order[i]);
      return;
    }
  }

  /// 清空输入框并回到历史视图
  void _resetToHistory() {
    _searchGen++; // 作废进行中的搜索
    _controller.clear();
    _focusNode.unfocus();
    if (mounted) {
      setState(() {
        _searched = false;
        _results.clear();
        _loading = false;
        _filterKey = null;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 来源标签条 + 结果分页
  // ---------------------------------------------------------------------------

  String _chipId(String? key) => key ?? _allChipId;

  /// 本轮结果里出现过的来源，顺序按**首次出结果的先后**排列。
  ///
  /// 用「首次出现」而不是站点列表顺序：边搜边上屏时，先回来的源排前面，
  /// 用户点进去看到的第一页就是刚出结果的那批，不用在一堆空标签里找。
  List<String> get _sourceOrder {
    final keys = <String>[];
    final seen = <String>{};
    for (final hit in _results) {
      if (seen.add(hit.siteKey)) keys.add(hit.siteKey);
    }
    return keys;
  }

  String _sourceNameOf(String key) {
    for (final hit in _results) {
      if (hit.siteKey == key) return hit.siteName ?? '未知来源';
    }
    return '未知来源';
  }

  int _sourceCountOf(String key) {
    var n = 0;
    for (final hit in _results) {
      if (hit.siteKey == key) n++;
    }
    return n;
  }

  /// 当前真正生效的来源筛选。
  ///
  /// 所选源在这轮结果里已经不存在时（重新搜索、切了搜索范围）按「全部」处理，
  /// 避免停在越界页上显示空白。
  String? get _activeFilter {
    final key = _filterKey;
    if (key == null) return null;
    for (final hit in _results) {
      if (hit.siteKey == key) return key;
    }
    return null;
  }

  /// 搜索结果的来源角标（按对象身份回查所属源）
  String? _siteNameOfVideo(Video video) {
    for (final hit in _results) {
      if (identical(hit.video, video)) return hit.siteName;
    }
    return null;
  }

  /// 回到「全部」第一页。PageView 可能还没挂载（结果刚清空），
  /// 这时交给下次构建时的 initialPage 处理，跳不过去也没关系。
  void _jumpToAll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pager.hasClients) return;
      _pager.jumpToPage(0);
    });
  }

  void _selectFilter(String? key) {
    if (_filterKey == key) return;
    // 「全部」是第 0 页，各来源按标签顺序排在其后（找不到就回第 0 页）
    final target = key == null ? 0 : _sourceOrder.indexOf(key) + 1;
    setState(() => _filterKey = key);
    if (_pager.hasClients) {
      _pager.animateToPage(
        target < 0 ? 0 : target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    _scrollChipIntoView(key);
  }

  /// 翻页时让对应标签滚进可视区。
  ///
  /// 用 [Scrollable.ensureVisible] 而不是手工测宽累加偏移：标签宽度会随
  /// 「源名 + 数量」的文字长度变化，量一次就得每帧跟着算，反而容易错位。
  void _scrollChipIntoView(String? key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _chipKeys[_chipId(key)]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _onPageChanged(int index, List<String?> pageIds) {
    final key = index >= 0 && index < pageIds.length ? pageIds[index] : null;
    if (key != _filterKey) setState(() => _filterKey = key);
    _scrollChipIntoView(key);
  }

  Future<void> _clearHistory() async {
    await Provider.of<AppState>(context, listen: false).clearSearchHistory();
    await _loadHistory();
  }

  Future<void> _removeHistory(String word) async {
    await Provider.of<AppState>(
      context,
      listen: false,
    ).removeSearchKeyword(word);
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
          // 来源标签条：只在有结果时出现，免得搜索前顶着一排空标签
          if (_searched && _results.isNotEmpty) _buildSourceBar(),
          if (_searched && _loading && _results.isNotEmpty)
            _buildSearchProgress(isDark),
          Expanded(
            child: _searched
                ? _buildResultBody(isDark)
                : _buildHistoryBody(isDark),
          ),
        ],
      ),
    );
  }

  /// 来源标签条：「全部 N」+ 每个有结果的源「源名 N」，可左右滚动。
  ///
  /// 用 SingleChildScrollView + Row 而不是 ListView：Row 会把离屏标签也
  /// 布局一遍，[Scrollable.ensureVisible] 才能拿到远处标签的位置把标签条
  /// 滚过去；ListView 的离屏项没有 context，源一多就「跟不上」。
  Widget _buildSourceBar() {
    final keys = _sourceOrder;
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        controller: _chipsScroll,
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sourceChip(key: null, label: '全部 ${_results.length}'),
            for (final k in keys)
              _sourceChip(
                key: k,
                label: '${_sourceNameOf(k)} ${_sourceCountOf(k)}',
              ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip({required String? key, required String label}) {
    final chipKey = _chipKeys.putIfAbsent(_chipId(key), () => GlobalKey());
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: FilterChip(
          key: chipKey,
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: _activeFilter == key,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelPadding: const EdgeInsets.symmetric(horizontal: 2),
          onSelected: (_) => _selectFilter(key),
        ),
      ),
    );
  }

  /// 搜索进行中的细进度条（结果已经陆续上屏，只是还有源没回来）
  Widget _buildSearchProgress(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
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
    return _scope == _SearchScope.current ? '当前站点没有搜到相关资源' : '所有源都没有搜到相关资源';
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

    // 每页 = 「全部」或某一个源；第 0 页固定是全部。
    // ids 在这里定格成一帧的快照传给 onPageChanged —— 翻页回调触发时
    // 结果集可能又多了一个源，用快照才不会把索引对错源。
    final pageIds = <String?>[null, ..._sourceOrder];
    final active = _activeFilter;
    if (active != _filterKey) {
      // 选中的源已不在结果里：下一帧复位到「全部」（build 里不能 setState）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _filterKey == null) return;
        setState(() => _filterKey = null);
        _jumpToAll();
      });
    }

    return PageView.builder(
      controller: _pager,
      itemCount: pageIds.length,
      onPageChanged: (i) => _onPageChanged(i, pageIds),
      itemBuilder: (context, i) {
        final key = pageIds[i];
        final visible = key == null
            ? _results
            : _results.where((h) => h.siteKey == key).toList(growable: false);
        // 「全部」页只要还有任意一个源能续页就有下一页；单源页只看自己。
        // 收藏 / 历史是本地过滤出来的，没有下一页（_paging 为空）。
        final canMore = key == null
            ? _paging.values.any((s) => s.canLoadMore)
            : (_paging[key]?.canLoadMore ?? false);
        final loadingMore = key == null
            ? _paging.values.any((s) => s.loading)
            : (_paging[key]?.loading ?? false);
        return _SourceResultGrid(
          // key 里带上搜索代次：同一个来源在新一轮搜索里也要是全新的一页。
          // 只带来源的话 State（连同 ScrollController）会被复用，换关键词后
          // 列表还停在上一轮的滚动位置，一进来就在中段。
          key: ValueKey('search-$_searchGen-${key ?? _allChipId}'),
          videos: [for (final hit in visible) hit.video],
          // 单源页里每张卡都标同一个来源是重复信息，只在「全部」页标
          labelOf: key == null ? _siteNameOfVideo : null,
          onTap: _openDetail,
          loadingMore: loadingMore,
          canLoadMore: canMore,
          onLoadMore: key == null ? _loadMoreForAll : () => _loadMore(key),
          // 收藏 / 历史是本地过滤，没有下一页，不显示底栏
          hasPaging: _paging.isNotEmpty,
          // 单源页内容不满一屏时自动补几页；「全部」页只给按钮
          autoFill: key != null,
        );
      },
    );
  }

  Widget _buildHistoryBody(bool isDark) {
    if (_history.isEmpty) {
      return const EmptyHint(message: '还没有搜索记录', icon: Icons.history);
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

/// 搜索结果的单页内容（「全部」或某一个来源）。
///
/// 单独做成 StatefulWidget 只为一件事：**每页自己的 ScrollController**。
/// PageView 里各页共用同一个 controller 会「一个 controller 绑多个
/// ScrollPosition」直接报错；再配上 KeepAlive，左右划走再划回来时列表
/// 还停在原来的位置，不会每次都弹回顶部。
class _SourceResultGrid extends StatefulWidget {
  const _SourceResultGrid({
    super.key,
    required this.videos,
    required this.onTap,
    this.labelOf,
    this.loadingMore = false,
    this.canLoadMore = false,
    this.onLoadMore,
    this.hasPaging = false,
    this.autoFill = false,
  });

  final List<Video> videos;
  final String? Function(Video)? labelOf;
  final void Function(Video) onTap;

  /// 正在请求下一页（列表末尾显示转圈）
  final bool loadingMore;

  /// 还有下一页可拉
  final bool canLoadMore;

  /// 滑到接近底部（或点底部按钮）时回调，由外层去发请求
  final VoidCallback? onLoadMore;

  /// 这一页背后有分页能力（联网搜索）。收藏 / 历史是本地过滤，不显示底栏。
  final bool hasPaging;

  /// 内容不满一屏时是否自动续拉。
  ///
  /// 只对单源页开放：「全部」页会轮流给每个源补页，自动续拉会连锁出
  /// 几百个请求。全部页靠底部的「加载更多」按钮由用户决定。
  final bool autoFill;

  @override
  State<_SourceResultGrid> createState() => _SourceResultGridState();
}

class _SourceResultGridState extends State<_SourceResultGrid>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    // 首帧布局完主动查一次：内容不满一屏时根本滚不动，也就没有任何滚动
    // 事件，不主动看一眼就会永远停在第一批（例如一页只有 10 条的站）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  @override
  void didUpdateWidget(covariant _SourceResultGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 追加内容后重新判断：仍然不满一屏就继续补，直到满屏或到底
    if (widget.videos.length != oldWidget.videos.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  /// 离底部还有约两屏就开始拉下一页，滑到底时内容已经接上了。
  void _maybeLoadMore() {
    if (!mounted) return;
    if (!widget.canLoadMore || widget.loadingMore) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.axis != Axis.vertical) return;
    if (pos.maxScrollExtent <= 0) {
      // 不满一屏、滑不动，没有滚动事件可等。单源页自动补，
      // 「全部」页留给底部按钮，避免连锁把二十多个源全翻一遍。
      if (widget.autoFill) widget.onLoadMore?.call();
      return;
    }
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      widget.onLoadMore?.call();
    }
  }

  /// 底栏：加载中转圈 / 「加载更多」按钮 / 「已全部加载」提示。
  Widget? _buildFooter(BuildContext context) {
    if (!widget.hasPaging) return null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (widget.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (widget.canLoadMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: widget.onLoadMore,
            icon: const Icon(Icons.expand_more, size: 18),
            label: const Text('加载更多'),
            style: OutlinedButton.styleFrom(
              foregroundColor: isDark
                  ? Colors.white70
                  : const Color(0xFF303133),
              side: BorderSide(
                color: isDark
                    ? const Color(0x24FFFFFF)
                    : const Color(0xFFE0E0E0),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ),
      );
    }
    if (widget.videos.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 22),
      child: Center(
        child: Text(
          // 「全部」页是各源混排，条数说了也没意义，只给单源页报数
          widget.autoFill ? '已全部加载 · ${widget.videos.length} 条' : '已全部加载',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return buildVideoGrid(
      context: context,
      videos: widget.videos,
      scrollController: _scroll,
      labelOf: widget.labelOf,
      onTap: widget.onTap,
      footer: _buildFooter(context),
    );
  }
}
