import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../services/system_control.dart';
import '../utils/app_colors.dart';
import '../utils/image_cache.dart';
import '../utils/toast.dart';
import '../widgets/common_widgets.dart';
import 'play_page.dart';

/// 详情页：海报 + 信息 + 收藏 + 选集播放
class DetailPage extends StatefulWidget {
  final String siteKey;
  final String videoId;

  /// 从收藏 / 历史的「外部播放」入口跳进来时置 true：详情加载完成后
  /// 自动弹出「选择集数 · 外部播放」，省掉用户再点一次外部播放按钮。
  /// 这些条目通常没存播放地址，只能回详情页重新取选集列表。
  final bool autoExternal;

  const DetailPage({
    super.key,
    required this.siteKey,
    required this.videoId,
    this.autoExternal = false,
  });

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  VideoDetail? _detail;
  bool _loading = true;
  String? _error;
  List<PlayItem> _playList = <PlayItem>[];

  /// 全部播放线路与当前选中项。聚合站（如 `ys.cxkjg.cn`）一部片子会有十几条
  /// 线路，集数与清晰度都不一样，得让用户自己挑。
  List<PlayLine> _lines = <PlayLine>[];
  int _lineIndex = 0;

  /// 每个线路标签的 GlobalKey：切线路后要靠它把选中项滚到线路条中间，
  /// 否则线路一多，选中的那一条可能停在屏幕外，用户看不到自己切到了哪。
  List<GlobalKey> _lineKeys = <GlobalKey>[];

  /// 本次横向滑动的累计位移，手指抬起时据此判断是「切换」还是「误触」。
  double _lineDragDx = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _recordKey => '${widget.siteKey}-${widget.videoId}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final site = context.read<AppState>().siteOf(widget.siteKey);
    if (site == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '未找到对应的视频源，可能已被移除';
        });
      }
      return;
    }
    try {
      final detail =
          await HttpService.instance.fetchDetail(site, widget.videoId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _lines = detail?.lines ?? <PlayLine>[];
        _lineKeys = List<GlobalKey>.generate(
          _lines.length,
          (_) => GlobalKey(debugLabel: 'play-line'),
        );
        _lineIndex = _lines.isEmpty ? 0 : _lineIndex.clamp(0, _lines.length - 1);
        _playList = detail == null
            ? <PlayItem>[]
            : _buildPlayList(detail, widget.siteKey, widget.videoId);
        _loading = false;
        // 源站连通但没返回这条影片：多半是被下架 / 改版，给出比通用文案更准的提示
        _error = detail == null ? '源站未返回该影片的数据' : null;
      });
      // 收藏 / 历史条目没存播放地址，从那里点「外部播放」跳进来，
      // 详情加载好后直接弹选集，省掉再点一次「外部播放」按钮。
      if (widget.autoExternal && _playList.isNotEmpty) {
        _onExternalPlayTap();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = HttpService.describeRequestError(e);
      });
    }
  }

  /// 把当前线路的选集（「名称$地址」）解析成可播放项
  List<PlayItem> _buildPlayList(VideoDetail detail, String siteKey, String id) {
    final items = (_lineIndex >= 0 && _lineIndex < _lines.length)
        ? _lines[_lineIndex].items
        : detail.m3u8List;
    final result = <PlayItem>[];
    var num = 1;
    for (final raw in items) {
      final parts = raw.split('\$');
      // 源站集名优先：综艺按日期 / 期数上下集分集时（`261021偏爱日记`
      // `第1期上`），按序号重生成会把这类信息全抹掉。
      // 单片（只有一项）不显示集名，直接用影片名。
      final label = items.length > 1
          ? PlayItem.labelFrom(parts.length > 1 ? parts.first : '', num)
          : detail.name;
      String pick;
      if (parts.length > 1) {
        // 优先取 m3u8 地址，没有则退而取任意 http 地址，
        // 否则部分数据源（mp4 直链等）会解析不出可播放项
        final m3u8 = parts.where(
            (x) => x.contains('.m3u8') && x.startsWith('http'));
        final http = parts.where((x) => x.startsWith('http'));
        if (m3u8.isNotEmpty) {
          pick = m3u8.first;
        } else if (http.isNotEmpty) {
          pick = http.first;
        } else {
          pick = parts.last;
        }
      } else {
        pick = parts.isEmpty ? '' : parts.first;
      }
      if (pick.isEmpty) continue;
      result.add(PlayItem(
        index: raw,
        value: pick,
        label: label,
        siteKey: siteKey,
        videoId: id,
      ));
      num++;
    }
    return result;
  }

  /// 切换线路：只换选集列表，不重新请求（一次详情就把所有线路给全了）
  void _selectLine(int index) {
    final detail = _detail;
    if (detail == null || index == _lineIndex) return;
    if (index < 0 || index >= _lines.length) return;
    setState(() {
      _lineIndex = index;
      _playList = _buildPlayList(detail, widget.siteKey, widget.videoId);
    });
    _revealLine(index);
  }

  /// 页面上左右滑动切换线路：向左滑看下一条，向右滑看上一条。
  ///
  /// 阈值取「横向拖动 48 逻辑像素」或「甩动速度 320 px/s」，满足任一即切换；
  /// 手指上下滚页面时总会带一点横向抖动，靠这个阈值挡掉，避免误切。
  void _handleLineSwipe(double dx, double velocity) {
    if (_lines.length < 2) return;
    if (dx.abs() < 48 && velocity.abs() < 320) return;
    final forward = dx.abs() >= 48 ? dx < 0 : velocity < 0;
    final next = forward ? _lineIndex + 1 : _lineIndex - 1;
    if (next < 0 || next >= _lines.length) {
      // 已经到头了：给一次轻触反馈，比「滑了没反应」更容易理解
      HapticFeedback.selectionClick();
      return;
    }
    HapticFeedback.selectionClick();
    _selectLine(next);
  }

  /// 把选中线路滚到线路条中央。
  ///
  /// `ensureVisible` 会顺着所有祖先滚动容器对齐，所以同时解决两件事：
  /// 横向把标签滚进可视区（还可能顺带露出相邻线路名），纵向在用户把页面
  /// 拖到底、线路条已经滚出屏幕时把它拉回来 —— 线路名始终看得见。
  void _revealLine(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || index < 0 || index >= _lineKeys.length) return;
      final ctx = _lineKeys[index].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        // 居中而不是贴边：两侧各留半个身位，暗示「还能继续滑」
        alignment: 0.5,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _toggleStar() async {
    final detail = _detail;
    if (detail == null) return;
    final state = context.read<AppState>();
    // 以 AppState 中的权威状态为准，不信任本页缓存的 _starred：
    // 从播放页返回后本地状态可能过期，导致对已存在的收藏重复 add（返回 false → 添加失败）。
    final starred = state.isStarred(_recordKey);
    // 收藏时连当前线路第一集的集名 / 地址一起存：以前只存元数据，
    // 收藏条目没有 url，「外部播放」只能跳回详情页重新选集。
    final first = _playList.isNotEmpty ? _playList.first : null;
    final item = RecordItem(
      key: _recordKey,
      label: first?.label ?? '',
      url: first?.value ?? '',
      id: detail.id,
      tid: detail.tid,
      name: detail.name,
      type: detail.type,
      pic: detail.pic,
      lang: detail.lang,
      area: detail.area,
      year: detail.year,
      note: detail.note,
      actor: detail.actor,
      director: detail.director,
      des: detail.des,
      last: detail.last,
    );
    final ok = starred
        ? await state.removeStar(_recordKey)
        : await state.addStar(item);
    if (!mounted) return;
    showToast(
      context,
      ok
          ? (starred ? '移除收藏成功' : '添加收藏成功')
          : (starred ? '移除收藏失败' : '添加收藏失败'),
      success: ok,
    );
  }

  Future<void> _addHistory(PlayItem item) async {
    final detail = _detail;
    if (detail == null) return;
    final state = context.read<AppState>();
    // 开始播放即刷新历史 ts（重播会置顶）；touchHistory 内部按 key upsert 并保留进度
    await state.touchHistory(RecordItem(
      key: _recordKey,
      label: item.label,
      url: item.value,
      id: detail.id,
      tid: detail.tid,
      name: detail.name,
      type: detail.type,
      pic: detail.pic,
      lang: detail.lang,
      area: detail.area,
      year: detail.year,
      note: detail.note,
      actor: detail.actor,
      director: detail.director,
      des: detail.des,
      last: detail.last,
    ));
  }

  void _openPlay(PlayItem item) {
    _addHistory(item);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayPage(
          siteKey: item.siteKey,
          videoId: item.videoId,
          title: item.label,
          url: item.value,
          initialLine: _lineIndex,
        ),
      ),
    );
  }

  Future<void> _onPlayTap() async {
    if (_playList.isEmpty) {
      showToast(context, '没有解析到可播放地址', success: false);
      return;
    }
    if (_playList.length == 1) {
      _openPlay(_playList.first);
      return;
    }
    _showPlayPicker();
  }

  /// 用外部播放器打开：与内置播放一样先选集，再交给系统选择器
  Future<void> _onExternalPlayTap() async {
    if (_playList.isEmpty) {
      showToast(context, '没有解析到可播放地址', success: false);
      return;
    }
    if (_playList.length == 1) {
      await _openExternal(_playList.first);
      return;
    }
    _showPlayPicker(external: true);
  }

  Future<void> _openExternal(PlayItem item) async {
    // 与内置播放一致，先记一条播放记录
    _addHistory(item);
    final config = context.read<AppState>().config;
    final status = await SystemControl.openWithExternalPlayer(
      url: item.value,
      title: item.label.isNotEmpty ? item.label : (_detail?.name ?? ''),
      customPath: config.externalPlayerPath,
      package: config.externalPlayerPackage,
    );
    if (!mounted) return;
    switch (status) {
      case 'no_app':
        showToast(context, '没找到能播放该地址的播放器', success: false);
      case 'no_player':
        showToast(context, '所选播放器打不开该地址，请到设置重新选择', success: false);
      case 'no_url':
        showToast(context, '没有可播放的地址', success: false);
      case 'error':
        showToast(context, '调起外部播放失败', success: false);
      default:
        // ok：系统选择器已经弹出来了，不用再打扰用户
        break;
    }
  }

  /// [external] 为 true 时，选中的集数交给外部播放器而不是内置播放页
  void _showPlayPicker({bool external = false}) {
    // 只有综艺那种长集名（`261021偏爱日记`）才需要留两行高度；
    // 普通剧集全是「第01集」，保持原来的紧凑单行，别让所有人都变大。
    final hasLongLabel = _playList.any((e) => e.label.runes.length > 5);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  external ? '选择集数 · 外部播放' : '选择集数',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: hasLongLabel ? 1.7 : 2,
                  ),
                  itemCount: _playList.length,
                  itemBuilder: (context, index) {
                    final item = _playList[index];
                    return OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        if (external) {
                          _openExternal(item);
                        } else {
                          _openPlay(item);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      child: Text(
                        item.label,
                        maxLines: hasLongLabel ? 2 : 1,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, height: 1.2),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _onCopyUrl() async {
    if (_playList.isEmpty) {
      showToast(context, '没有可复制的地址', success: false);
      return;
    }
    await Clipboard.setData(ClipboardData(text: _playList.first.value));
    if (!mounted) return;
    showToast(context, '播放地址已复制到剪贴板');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: Stack(
        children: [
          if (_detail != null && _detail!.pic.isNotEmpty)
            Positioned.fill(child: _buildBlurBackground()),
          Positioned.fill(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_detail == null
                    ? EmptyHint(
                        message: _error ?? '获取详情失败',
                        icon: Icons.error_outline,
                        actionText: '重试',
                        onAction: _load,
                      )
                    : _buildContent(size)),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _circleButton(
                      icon: Icons.arrow_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.75),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: const Color(0xFF303133)),
      ),
    );
  }

  Widget _buildBlurBackground() {
    return Opacity(
      opacity: 0.55,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Image(
          image: CachedNetworkImageProvider(
            _detail!.pic,
            cacheManager: AppImageCache.instance,
          ),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildContent(Size size) {
    final detail = _detail!;
    final content = SingleChildScrollView(
      child: Column(
        children: [
          SizedBox(height: size.height * 0.1),
          Center(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  BoxShadow(color: Color(0x55ACACAC), blurRadius: 20),
                ],
              ),
              child: detail.pic.isEmpty
                  ? const SizedBox(width: 160, height: 220)
                  : CachedNetworkImage(
                      imageUrl: detail.pic,
                      cacheManager: AppImageCache.instance,
                      height: size.height * 0.36,
                      fit: BoxFit.fitHeight,
                      // 详情大图是焦点图，给到 600px 宽解码，清晰又不浪费内存
                      memCacheWidth: 600,
                      placeholder: (_, __) => const SizedBox(
                        width: 160,
                        height: 220,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      errorWidget: (_, __, ___) => const SizedBox(
                        width: 160,
                        height: 220,
                        child: Icon(Icons.broken_image, size: 48),
                      ),
                    ),
            ),
          ),
          SizedBox(height: math.max(0, size.height * 0.08 - _actionLane)),
          _buildInfoSection(detail),
        ],
      ),
    );
    // 只有一条线路时不必挂横向手势，省得和纵向滚动、文字选择互相争抢
    if (_lines.length < 2) return content;
    return GestureDetector(
      // 水平和纵向滚动各认各的方向，手指往上推仍然正常翻页
      onHorizontalDragStart: (_) => _lineDragDx = 0,
      onHorizontalDragUpdate: (d) => _lineDragDx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final dx = _lineDragDx;
        _lineDragDx = 0;
        _handleLineSwipe(dx, d.primaryVelocity ?? 0);
      },
      child: content,
    );
  }

  /// 悬浮按钮（收藏 / 播放）所需的上方透明空间高度。
  ///
  /// 这两个按钮要压在白卡片的上沿之上，看上去是「浮」在卡片外面的。
  /// 但如果直接用 `Positioned(top: -56)` 摆到 Stack 外面，虽然画得出来，
  /// **命中测试会失效**：Flutter 要求触点落在父节点尺寸内才会往下传递，
  /// 于是按钮变成看得见点不动。这里改为先用 Padding 预留一段透明区域
  /// （[_actionLane]），按钮落在这段区域内，卡片随即下移，视觉位置不变。
  static const double _actionLane = 76;

  Widget _buildInfoSection(VideoDetail detail) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: _actionLane),
          child: _buildInfoCard(detail),
        ),
        // 收藏：圆心落在卡片上沿（原设计的 top:-28 换算而来）
        Positioned(
          top: _actionLane - 28,
          right: 116,
          child: _actionButton(
            icon: context.watch<AppState>().isStarred(_recordKey)
                ? Icons.star
                : Icons.star_border,
            color: context.watch<AppState>().isStarred(_recordKey)
                ? const Color(0xFFFF4445)
                : (isDark ? Colors.white70 : const Color(0xFF606266)),
            onTap: _toggleStar,
          ),
        ),
        // 绿色播放按钮：圆心同样压在卡片上沿
        Positioned(
          top: _actionLane - 40,
          right: 40,
          child: _actionButton(
            icon: Icons.play_circle_filled,
            color: const Color(0xFF6DD143),
            size: 62,
            onTap: _onPlayTap,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard(VideoDetail detail) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBg : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 文字区支持**自由选中**：长按选中一个词，再拖两端手柄扩到任意长度，
          // 松手弹出「复制」；桌面端可直接鼠标拖选。片名 / 年份地区 / 导演 /
          // 演员 / 简介都在可选中范围内。
          //
          // 有两个按钮留在 SelectionArea 外面：选择手势（长按拖动）和按钮点击
          // 需要在手势竞技场里抢，混在一起容易出现「长按按钮变成选文字」。
          SelectionArea(
            contextMenuBuilder: _buildSelectionToolbar,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detail.name,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final text in [
                      detail.area,
                      detail.lang,
                      detail.type,
                      detail.year,
                      detail.note,
                    ])
                      if (text.isNotEmpty) Text(text),
                  ],
                ),
                const SizedBox(height: 12),
                if (detail.director.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('导演: ${detail.director}'),
                  ),
                if (detail.actor.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('演员: ${detail.actor}'),
                  ),
                if (detail.des.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('简介: ${detail.des}'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_lines.length > 1) ...[
            _buildLineBar(),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _onPlayTap,
              icon: const Icon(Icons.play_arrow),
              label: Text(_playList.length > 1
                  ? '播放（共 ${_playList.length} 集）'
                  : '立即播放'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _onExternalPlayTap,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('外部播放'),
            ),
          ),
          const SizedBox(height: 10),
          // 复制地址以前藏在右上角那个「 ⋮ 」里，点一下没任何视觉反馈，
          // 很多人以为那是菜单。挪到底部和播放并排，意图一眼就明白。
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _onCopyUrl,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制播放地址'),
            ),
          ),
        ],
      ),
    );
  }

  /// 线路选择条：横滑一排「金鹰 19集 / 闪电 16集 / …」
  ///
  /// 只在多于一条线路时出现。早期实现只把 `vod_play_url` 的第一段当全集，
  /// 聚合站的其余线路（集数、清晰度、可用性都不同）全被丢弃，用户既看不到
  /// 也不知道有替补。
  Widget _buildLineBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final line = _lines[_lineIndex];
    final hintColor = (isDark ? Colors.white70 : const Color(0xFF606266))
        .withValues(alpha: 0.8);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '播放线路 · ${line.name}（${_playList.length} 集）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white70 : const Color(0xFF606266),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 手势没有视觉入口，给一行小字说明，否则没人知道能滑
            Icon(Icons.swipe, size: 13, color: hintColor),
            const SizedBox(width: 3),
            Text(
              '左右滑动切换',
              style: TextStyle(fontSize: 11, color: hintColor),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < _lines.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _buildLineChip(i),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLineChip(int index) {
    final line = _lines[index];
    final selected = index == _lineIndex;
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      // 当前线路再点一次没有意义，只是空转重建列表
      onTap: selected ? null : () => _selectLine(index),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        // key 挂在这里，切换后据此把标签滚进可视区
        key: index < _lineKeys.length ? _lineKeys[index] : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? accent : Colors.transparent,
          border: Border.all(
            color: selected ? accent : Theme.of(context).dividerColor,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          '${line.name} ${line.length}集',
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : null,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 选中文字后弹出的菜单，把系统默认的英文 Copy / Select all 换成中文。
  ///
  /// 没有引入 `flutter_localizations`：那会把几十种语言的资源全打进 APK
  /// （包体明显变大），而这里只需要两个按钮的文案。其余 `ContextMenuButtonType`
  /// （比如系统自带的其他项）原样保留，不丢功能。
  Widget _buildSelectionToolbar(
    BuildContext context,
    SelectableRegionState state,
  ) {
    final items = <ContextMenuButtonItem>[
      for (final item in state.contextMenuButtonItems)
        switch (item.type) {
          ContextMenuButtonType.copy =>
            ContextMenuButtonItem(label: '复制', onPressed: item.onPressed),
          ContextMenuButtonType.selectAll =>
            ContextMenuButtonItem(label: '全选', onPressed: item.onPressed),
          _ => item,
        },
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Widget _actionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    double size = 30,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          // 压在模糊海报上：纯黑 + 已有的白色描边即可，不必再提亮底色
          color: isDark ? AppColors.darkBg : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark ? Colors.white24 : const Color(0xFFF8F8F8),
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x22000000), blurRadius: 6),
          ],
        ),
        child: Icon(icon, color: color, size: size),
      ),
    );
  }
}
