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
import '../utils/toast.dart';
import '../widgets/common_widgets.dart';
import 'play_page.dart';

/// 详情页：海报 + 信息 + 收藏 + 选集播放
class DetailPage extends StatefulWidget {
  final String siteKey;
  final String videoId;

  const DetailPage({super.key, required this.siteKey, required this.videoId});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  VideoDetail? _detail;
  bool _loading = true;
  bool _starred = false;
  List<PlayItem> _playList = <PlayItem>[];

  @override
  void initState() {
    super.initState();
    _load();
    _checkStar();
  }

  String get _recordKey => '${widget.siteKey}-${widget.videoId}';

  Future<void> _load() async {
    final site = context.read<AppState>().siteOf(widget.siteKey);
    if (site == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final detail =
        await HttpService.instance.fetchDetail(site, widget.videoId);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _playList = detail == null
          ? <PlayItem>[]
          : _buildPlayList(detail, widget.siteKey, widget.videoId);
      _loading = false;
    });
  }

  /// 把 m3u8List 里的「名称$地址」解析成可播放项
  List<PlayItem> _buildPlayList(VideoDetail detail, String siteKey, String id) {
    final result = <PlayItem>[];
    var num = 1;
    for (final raw in detail.m3u8List) {
      final parts = raw.split('\$');
      final label = detail.m3u8List.length > 1 ? '第$num集' : detail.name;
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

  Future<void> _checkStar() async {
    final starred = context.read<AppState>().isStarred(_recordKey);
    if (mounted) setState(() => _starred = starred);
  }

  Future<void> _toggleStar() async {
    final detail = _detail;
    if (detail == null) return;
    final state = context.read<AppState>();
    final item = RecordItem(
      key: _recordKey,
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
    if (_starred) {
      final ok = await state.removeStar(_recordKey);
      if (!mounted) return;
      showToast(context, ok ? '移除收藏成功' : '移除收藏失败', success: ok);
    } else {
      final ok = await state.addStar(item);
      if (!mounted) return;
      showToast(context, ok ? '添加收藏成功' : '添加收藏失败', success: ok);
    }
    await _checkStar();
  }

  Future<void> _addHistory(PlayItem item) async {
    final detail = _detail;
    if (detail == null) return;
    final state = context.read<AppState>();
    if (state.historyOf(_recordKey) != null) return;
    await state.addHistory(RecordItem(
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

  /// 用第三方播放器打开：与内置播放一样先选集，再交给系统选择器
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
    final status = await SystemControl.openWithExternalPlayer(
      url: item.value,
      title: item.label.isNotEmpty ? item.label : (_detail?.name ?? ''),
    );
    if (!mounted) return;
    switch (status) {
      case 'no_app':
        showToast(context, '没找到能播放该地址的第三方播放器', success: false);
      case 'no_url':
        showToast(context, '没有可播放的地址', success: false);
      case 'error':
        showToast(context, '调起第三方播放器失败', success: false);
      default:
        // ok：系统选择器已经弹出来了，不用再打扰用户
        break;
    }
  }

  /// [external] 为 true 时，选中的集数交给第三方播放器而不是内置播放页
  void _showPlayPicker({bool external = false}) {
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
                  external ? '选择集数 · 用第三方播放器播放' : '选择集数',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 2,
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
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
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

  Future<void> _onShare() async {
    if (_playList.isEmpty) {
      showToast(context, '没有可分享的地址', success: false);
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
                    ? const EmptyHint(message: '获取详情失败', icon: Icons.error_outline)
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
                    _circleButton(icon: Icons.more_vert, onTap: _onShare),
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
          image: CachedNetworkImageProvider(_detail!.pic),
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
    return SingleChildScrollView(
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
                      height: size.height * 0.36,
                      fit: BoxFit.fitHeight,
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
            icon: _starred ? Icons.star : Icons.star_border,
            color: _starred ? const Color(0xFFFF4445) : const Color(0xFF606266),
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
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.name,
            style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
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
          const SizedBox(height: 16),
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
              label: const Text('使用第三方播放器播放'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    double size = 30,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFF8F8F8)),
          boxShadow: const [
            BoxShadow(color: Color(0x22000000), blurRadius: 6),
          ],
        ),
        child: Icon(icon, color: color, size: size),
      ),
    );
  }
}
