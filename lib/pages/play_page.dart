import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/video.dart';
import '../providers/app_state.dart';
import '../services/http_service.dart';
import '../services/system_control.dart';
import '../services/video_network_stats.dart';
import '../services/zy_database.dart';
import '../utils/player_options.dart';
import '../utils/toast.dart';

/// 播放页：视频播放 + 画面比例/大小调节 + 选集 + 收藏 + 自动记录进度
class PlayPage extends StatefulWidget {
  final String siteKey;
  final String videoId;
  final String title;
  final String url;
  final double initialTime;

  const PlayPage({
    super.key,
    required this.siteKey,
    required this.videoId,
    required this.title,
    required this.url,
    this.initialTime = 0,
  });

  @override
  State<PlayPage> createState() => _PlayPageState();
}

class _PlayPageState extends State<PlayPage> {
  static const Color _accent = Color(0xFF1E88E5);

  /// 画中画通道：既用于「请求进入 PiP」(invokeMethod enterPip)，
  /// 也用于接收原生侧回传的 PiP 模式变化事件 (onPipModeChanged)。
  final MethodChannel _pipChannel = const MethodChannel('com.zy.player/pip');

  /// 桌面端窗口通道：处理「真正窗口全屏」(enterFullscreen/exitFullscreen)。
  /// Android/iOS 不走窗口级全屏（系统级全屏由 SystemChrome 处理），无此通道。
  final MethodChannel _windowChannel =
      const MethodChannel('com.zy.player/window');

  /// 竖屏时画面区域最多占屏幕高度的比例，防止 9:16 这类竖版比例把布局撑爆
  static const double _portraitMaxHeightRatio = 0.42;

  /// 内置播放器请求头：很多影视源站/CDN 会按 User-Agent 拦掉 ExoPlayer 的
  /// `ExoPlayer/2.x` UA（返回 403 或 HTML 而非视频流），导致「播放失败」。
  /// 带上浏览器 UA 后大多能直接过。Referer 一般不强制（外部播放器也没带却能播），
  /// 故这里只补 UA，避免乱带 Referer 反而被严格防盗链拦。
  static const Map<String, String> _kPlayerHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  };

  late VideoPlayerController _controller;
  Timer? _historyTimer;

  bool _initialized = false;
  bool _hasError = false;
  /// 最近一次播放错误的原始描述（来自异常或 ExoPlayer 的 errorDescription），
  /// 用于在失败界面展示，便于定位是 403 / mime / codec 哪种问题。
  String? _lastError;
  bool _fullscreen = false;

  /// 是否处于系统画中画（PiP）模式。进入后隐藏一切 Flutter UI（标题栏 / 进度条 /
  /// 控制按钮 / 详情），只留纯播放画面，让 PiP 窗口里是「全屏视频」而非缩小的整页。
  bool _inPip = false;

  /// 桌面端是否处于「真正窗口全屏」(无边框铺满整个显示器，盖住任务栏)。
  /// 与「填满窗口」(_fullscreen 在桌面只是视频铺满应用窗口) 区分。
  bool _nativeFullscreen = false;

  /// 是否桌面平台（Windows/macOS/Linux）——这些平台需要窗口级原生操作
  /// （画中画浮窗、真正全屏），且 SystemChrome 的沉浸模式对它们无效。
  bool get _isDesktop {
    final p = Theme.of(context).platform;
    return p == TargetPlatform.windows ||
        p == TargetPlatform.macOS ||
        p == TargetPlatform.linux;
  }

  /// 当前画面比例 / 大小（初始化时从设置读入，改动后写回）
  late AspectOption _aspect;
  late ScaleOption _scaleMode;

  /// 比例 / 大小选项面板是否展开
  bool _aspectPanelOpen = false;
  bool _scalePanelOpen = false;

  // ---- 画面手势（竖屏 / 全屏同一套）：左半屏上下滑调亮度，右半屏调音量 ----

  /// 当前亮度 / 音量，0.0 ~ 1.0（进入页面时从系统读一次）
  double _brightness = 0.5;
  double _volume = 0.5;

  /// 手势进行中：是否显示 HUD、调的是哪一项、当前值
  bool _gestureActive = false;
  bool _gestureIsBrightness = true;
  double _gestureValue = 0.5;

  /// 一次满屏滑动对应的像素高度（在 build 里按实际尺寸算）
  double _gestureSpan = 400;

  /// 手动交换宽高：纠正「竖屏视频被上报成横屏」的源，来自设置
  bool _flip = false;

  // ---- 全屏网速显示（设置里的「显示实时下载速度」）----

  /// 是否显示实时网速，进入页面时从设置读一次
  bool _showSpeed = false;

  /// 网速轮询（只在全屏 + 开关打开时跑）
  Timer? _statsTimer;
  PlayerNetworkStats? _netStats;

  // ---- 全屏左右滑动快进 / 快退 ----

  /// 滑动 seek 进行中
  bool _seekActive = false;

  /// seek 预览目标进度（0~1），用于 HUD 显示
  double _seekPreviewFraction = 0;

  /// 相对起点的偏移秒数（正=快进，负=快退），用于 HUD 显示
  double _seekDeltaSeconds = 0;

  double _seekBaseFraction = 0;
  double _seekStartDx = 0;
  double _seekTrackWidth = 0;

  /// 左右滑满整屏宽度对应的快进 / 快退秒数
  static const double _seekSpanSeconds = 120;

  // ---- 全屏长按加速 ----

  /// 长按加速进行中
  bool _longPressActive = false;

  /// 长按加速倍率，进入页面时从设置读一次，默认 2.0
  double _longPressRate = 2.0;

  // ---- 全屏控制层自动隐藏 ----

  /// 控制层（进度条 + 按钮行）是否可见
  bool _controlsVisible = true;

  /// 自动隐藏计时器
  Timer? _hideTimer;

  /// 无操作多久后隐藏控制层
  static const Duration _controlsAutoHideDelay = Duration(seconds: 4);

  /// 全屏方向的手动覆盖。
  /// null = 跟随画面比例自动选（默认），true = 强制横屏，false = 强制竖屏。
  /// 只在本次全屏会话内有效，退出全屏或重新进入全屏时复位。
  bool? _forceLandscape;

  /// 上一次看到的视频尺寸，用于在尺寸变化时重建画面
  Size _lastVideoSize = Size.zero;

  /// Android API 等级，仅用于诊断信息
  int _sdkInt = 0;

  VideoDetail? _detail;
  List<PlayItem> _playList = <PlayItem>[];
  String _title = '';

  /// 当前正在播放的地址（切集后会变化，用于写入历史）
  String _currentUrl = '';

  /// 当前是否已通知系统保持常亮，避免重复调用 setKeepScreenOn
  bool _awake = false;

  String get _recordKey => '${widget.siteKey}-${widget.videoId}';

  @override
  void initState() {
    super.initState();
    final config = context.read<AppState>().config;
    _aspect = PlayerAspects.byKey(config.playerAspect);
    _scaleMode = PlayerScales.byKey(config.playerScale);
    _flip = config.playerFlip;
    _showSpeed = config.showSpeed;
    _longPressRate = config.playerLongPressRate;

    _title = widget.title;
    _currentUrl = widget.url;
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      httpHeaders: _kPlayerHeaders,
    );
    _controller.addListener(_onControllerUpdate);
    _initPlayer(seekTo: widget.initialTime);
    _loadDetail();
    _loadSystemLevels();
    _pipChannel.setMethodCallHandler(_onPipCall);
    // 每 10 秒写一次播放进度
    _historyTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _updateHistory(),
    );
  }

  @override
  void dispose() {
    _pipChannel.setMethodCallHandler(null);
    _historyTimer?.cancel();
    _statsTimer?.cancel();
    _hideTimer?.cancel();
    _updateHistory();
    // 兜底关闭常亮：避免播放中直接退出页面时监听器没机会把屏幕唤醒标志清掉
    if (_awake) {
      _awake = false;
      SystemControl.setKeepScreenOn(false);
    }
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    // ⚠️ 退出播放页必须把方向偏好**清空**（空列表 = 交还系统决定），
    // 而不是锁死 portraitUp——否则在平板上（系统横屏但 App 被锁竖屏）整个 App
    // 会被两侧黑边夹住、中间内容又矮又窄，离开播放页也回不来。
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _initPlayer({double seekTo = 0}) async {
    try {
      await _controller.initialize();
      if (!mounted) return;
      if (seekTo > 0) {
        await _controller.seekTo(Duration(seconds: seekTo.floor()));
      }
      await _controller.play();
      if (mounted) setState(() => _initialized = true);
      // 换集后视频自身的比例可能变了，全屏中要跟着重新选横竖屏
      if (_fullscreen) await _applyFullscreenOrientation();
    } catch (e) {
      if (mounted) {
        _lastError = e.toString();
        setState(() => _hasError = true);
      }
      // 暴露真实报错，便于定位是 403 / mime / codec 哪种（之前被 catch(_) 吞掉）
      debugPrint('[PlayPage] 内置播放器初始化失败: $e');
    }
  }

  /// 读一次系统亮度 / 音量，作为手势滑动的起点
  Future<void> _loadSystemLevels() async {
    final brightness = await SystemControl.brightness();
    final volume = await SystemControl.volume();
    final sdkInt = await SystemControl.androidSdkInt();
    if (!mounted) return;
    setState(() {
      _brightness = brightness;
      _volume = volume;
      _sdkInt = sdkInt;
    });
  }

  void _togglePlay() {
    final value = _controller.value;
    if (value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
    setState(() {});
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    // 播放状态变化时保持/放开屏幕常亮（播放中不熄屏，暂停/结束即恢复）
    final playing = _controller.value.isPlaying;
    if (playing != _awake) {
      _awake = playing;
      SystemControl.setKeepScreenOn(playing);
    }
    // 播放中出错时刷新一次
    if (_controller.value.hasError && !_hasError) {
      _lastError = _controller.value.errorDescription;
      setState(() => _hasError = true);
      return;
    }
    // 视频尺寸可能变化（切清晰度、换集、播放器补正旋转方向），
    // 画面区域是按尺寸算出来布局的，必须跟着重建，否则会用旧比例渲染新画面
    final size = _controller.value.size;
    if (size != _lastVideoSize) {
      _lastVideoSize = size;
      setState(() {});
    }
  }

  Future<void> _loadDetail() async {
    final site = context.read<AppState>().siteOf(widget.siteKey);
    if (site == null) return;
    final detail = await HttpService.instance.fetchDetail(site, widget.videoId);
    if (!mounted || detail == null) return;
    final list = <PlayItem>[];
    var num = 1;
    for (final raw in detail.m3u8List) {
      final parts = raw.split('\$');
      final label = detail.m3u8List.length > 1 ? '第$num集' : detail.name;
      String pick;
      if (parts.length > 1) {
        final m3u8 =
            parts.where((x) => x.contains('.m3u8') && x.startsWith('http'));
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
      list.add(PlayItem(
        index: raw,
        value: pick,
        label: label,
        siteKey: widget.siteKey,
        videoId: widget.videoId,
      ));
      num++;
    }
    setState(() {
      _detail = detail;
      _playList = list;
    });

    // 不论是详情页进来还是从其他地方（如历史分栏）直接进来，开始播放都刷新历史 ts
    final state = context.read<AppState>();
    await state.touchHistory(RecordItem(
      key: _recordKey,
      label: _title.isEmpty ? detail.name : _title,
      url: _currentUrl,
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

  Future<void> _toggleStar() async {
    final state = context.read<AppState>();
    // 以 AppState 中的权威状态为准，不信任本页缓存的 _starred：
    // 从详情页收藏后返回，本地状态可能过期，导致对已存在的收藏重复 add/remove。
    final starred = state.isStarred(_recordKey);
    final detail = _detail;
    final hist = state.historyOf(_recordKey);
    // 优先用已加载的详情；详情还没回来（如刚从历史记录进入、网络慢/失败）时，
    // 退而从历史记录取元数据，再退而用标题/地址兜底 —— 这样「点收藏」绝不会
    // 因为 _detail 为 null 而静默失败（修复「从历史进入偶尔收藏不了」）。
    final item = detail != null
        ? RecordItem(
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
          )
        : RecordItem(
            key: _recordKey,
            label: _title.isEmpty ? (hist?.name ?? '') : _title,
            url: _currentUrl,
            id: hist?.id ?? '',
            tid: hist?.tid ?? '',
            name: hist?.name.isNotEmpty == true ? hist!.name : _title,
            type: hist?.type ?? '',
            pic: hist?.pic ?? '',
            lang: hist?.lang ?? '',
            area: hist?.area ?? '',
            year: hist?.year ?? '',
            note: hist?.note ?? '',
            actor: hist?.actor ?? '',
            director: hist?.director ?? '',
            des: hist?.des ?? '',
            last: hist?.last ?? '',
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

  /// 原生侧 `onPictureInPictureModeChanged` 回传：进入 / 退出 PiP 时切换 [_inPip]，
  /// 驱动 build 隐藏 / 恢复全部 Flutter UI，使 PiP 窗口里只剩纯播放画面。
  Future<dynamic> _onPipCall(MethodCall call) async {
    if (call.method == 'onPipModeChanged' && mounted) {
      setState(() => _inPip = call.arguments == true);
    }
    return;
  }

  /// 进入系统级画中画（安卓 8+）：视频缩进系统 PiP 角落，切到其他 App 也继续播。
  /// 不支持时提示用户。
  Future<void> _enterPip() async {
    if (_fullscreen || _nativeFullscreen) {
      SystemChrome.setPreferredOrientations([]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _fullscreen = false;
      // 进入画中画与「原生全屏」互斥：原生侧 EnterPip 会同时复位窗口全屏状态，
      // 这里同步清掉 Dart 标志，避免按钮状态与实际不一致。
      _nativeFullscreen = false;
      if (mounted) setState(() {});
    }
    try {
      // 与安卓端 MainActivity 的 'com.zy.player/pip' 通道对应；把**实际显示比例**
      // （_displayAspectRatio，已含用户手动设置的比例 + 交换宽高）带过去，
      // 让 PiP 窗口形状贴合画面，避免「手动设了 9:16 但小窗还按 16:9 留黑边」。
      final ok = await _pipChannel.invokeMethod<bool>(
        'enterPip',
        {'aspect': _displayAspectRatio},
      );
      if (ok != true && mounted) {
        showToast(context, '当前设备/系统不支持画中画', success: false);
      }
    } catch (_) {
      if (mounted) showToast(context, '当前设备/系统不支持画中画', success: false);
    }
  }

  /// 退出桌面端「模拟画中画」：还原主窗尺寸/位置/取消置顶。
  /// Android 端走系统原生 PiP，由系统管理退出，此处调用会被忽略（NotImplemented）。
  Future<void> _exitPip() async {
    try {
      await _pipChannel.invokeMethod('exitPip');
    } catch (_) {}
  }

  /// 桌面端「真正窗口全屏」：把应用窗口铺满整个显示器（无边框、盖住任务栏）。
  /// 进入时一并打开「填满」(_fullscreen=true) 让视频铺满；退出时还原窗口并关闭填满。
  /// Android/iOS 无此通道，调用会被忽略（NotImplemented）。
  Future<void> _toggleNativeFullscreen() async {
    try {
      if (_nativeFullscreen) {
        await _windowChannel.invokeMethod('exitFullscreen');
        _nativeFullscreen = false;
        if (mounted) setState(() => _fullscreen = false);
      } else {
        await _windowChannel.invokeMethod('enterFullscreen');
        _nativeFullscreen = true;
        if (mounted) setState(() => _fullscreen = true);
      }
    } catch (_) {}
  }

  /// 每 10 秒记录一次播放进度。
  /// 直接写库而不触发通知：播放中的界面不需要重绘，历史页进入时会重新读库。
  Future<void> _updateHistory() async {
    final detail = _detail;
    if (detail == null || !_controller.value.isInitialized) return;
    final exist = context.read<AppState>().historyOf(_recordKey);
    if (exist == null) return;
    final position = _controller.value.position;
    final duration = _controller.value.duration;
    await ZyDatabase.instance.update(
      DbNames.history,
      exist
          .copyWithRecord(
            label: _title.isEmpty ? detail.name : _title,
            url: _currentUrl,
            currentTime: position.inMilliseconds / 1000,
            duration: duration.inMilliseconds / 1000,
          )
          .toJson(),
    );
  }

  Future<void> _switchEpisode(PlayItem item) async {
    setState(() {
      _initialized = false;
      _hasError = false;
      _title = item.label;
      _currentUrl = item.value;
      // 新控制器默认速度 1.0，长按加速标记复位，避免卡在加速态
      _longPressActive = false;
      _seekActive = false;
    });
    await _controller.pause();
    _controller.removeListener(_onControllerUpdate);
    await _controller.dispose();
    if (!mounted) return;
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(item.value),
      httpHeaders: _kPlayerHeaders,
    );
    _controller.addListener(_onControllerUpdate);
    await _initPlayer();
    await _updateHistory();
  }

  /// 内置播放失败时的一键兜底：把当前地址交给外部播放器（与外部播放入口同一逻辑）。
  Future<void> _openExternalFromError() async {
    final status = await SystemControl.openWithExternalPlayer(
      url: _currentUrl,
      title: _title.isNotEmpty ? _title : (_detail?.name ?? ''),
      customPath: context.read<AppState>().config.externalPlayerPath,
    );
    if (!mounted) return;
    switch (status) {
      case 'no_app':
        showToast(context, '没找到能播放该地址的播放器', success: false);
      case 'no_url':
        showToast(context, '没有可播放的地址', success: false);
      case 'error':
        showToast(context, '调起外部播放失败', success: false);
      default:
        break;
    }
  }

  void _showEpisodePicker() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('选择集数',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
                        _switchEpisode(item);
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

  /// 播放下一集：在当前播放列表里找「正在播放这一集」的下一项，找不到（已是最后一集
  /// 或列表不足两集）就不动。当前集用播放地址匹配，切集后 _currentUrl 已更新。
  void _playNextEpisode() {
    if (_playList.length < 2) return;
    final idx = _playList.indexWhere((e) => e.value == _currentUrl);
    if (idx < 0 || idx >= _playList.length - 1) return;
    _switchEpisode(_playList[idx + 1]);
  }

  // --------------------------------------------------------------------------
  // 全屏：控制层自动隐藏 + 实时网速
  // --------------------------------------------------------------------------

  /// 重新计时：[_controlsAutoHideDelay] 之后把控制层藏起来。
  ///
  /// 面板（画面比例 / 画面大小）展开时先不藏，过一会儿再试 —— 否则用户刚点开
  /// 面板就被收走，手感很怪。
  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || !_fullscreen) return;
      if (_aspectPanelOpen || _scalePanelOpen) {
        _scheduleHideControls();
        return;
      }
      setState(() => _controlsVisible = false);
    });
  }

  /// 显示控制层并重新计时
  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHideControls();
  }

  /// 单击画面：可见 → 立刻收起；已收起 → 显示并计时
  void _toggleControls() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  /// 开始 / 停止网速轮询。
  ///
  /// 每秒问一次插件（ExoPlayer 的带宽计本来就是按 chunk 更新的，问得再勤也没用）。
  /// 只在「全屏 + 设置里打开了开关」时跑，其余时候完全停掉。
  void _syncStatsPolling() {
    final shouldPoll = _fullscreen && _showSpeed;
    if (shouldPoll) {
      _statsTimer?.cancel();
      _refreshNetStats();
      _statsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshNetStats(),
      );
      return;
    }
    _statsTimer?.cancel();
    _statsTimer = null;
    if (_netStats != null) setState(() => _netStats = null);
  }

  Future<void> _refreshNetStats() async {
    // playerId 被 video_player 标成 @visibleForTesting，但这是拿到插件侧播放器实例的
    // 唯一途径 —— 侧信道要靠它定位 ExoPlayer。读取一个 int 字段，没有副作用。
    // ignore: invalid_use_of_visible_for_testing_member
    final stats = await VideoNetworkStats.get(_controller.playerId);
    if (!mounted || !_fullscreen || !_showSpeed) return;
    setState(() => _netStats = stats);
  }

  Future<void> _toggleFullscreen() async {
    // 桌面端：若处于原生窗口全屏，优先退出窗口全屏（连带退出「填满」），
    // 让现有「全屏/填满」按钮与新增的「窗口全屏」按钮互斥、状态一致。
    if (_nativeFullscreen) {
      await _toggleNativeFullscreen();
      return;
    }
    // 退出 / 进入全屏前，若正在长按加速，先恢复正常速度，避免状态卡住
    if (_longPressActive) {
      _controller.setPlaybackSpeed(1.0);
    }
    if (_fullscreen) {
      // 退出全屏：同样把方向偏好清空，交还系统决定（不要在平板上把 App 锁成竖屏条）。
      // 非全屏的竖屏播放页布局本身靠 LayoutBuilder 自适应，不需要锁方向。
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      // 方向跟着画面比例走，而不是一律横屏
      await _applyFullscreenOrientation();
    }
    if (mounted) {
      setState(() {
        _fullscreen = !_fullscreen;
        // 每次进入/退出全屏都回到「跟随比例」，避免上次的手动旋转粘到下个视频
        _forceLandscape = null;
        // 切换横竖屏后画面区域尺寸会变，收起面板避免遮挡
        _aspectPanelOpen = false;
        _scalePanelOpen = false;
        // 进全屏先把控制层亮出来，几秒后再自动收
        _controlsVisible = true;
        // 手势状态复位（长按 / 滑动 seek 只在全屏内有效）
        _longPressActive = false;
        _seekActive = false;
        _gestureActive = false;
      });
      _hideTimer?.cancel();
      if (_fullscreen) _scheduleHideControls();
      _syncStatsPolling();
    }
  }

  /// 当前画面是不是横版（宽 >= 高）。
  /// 依赖的是「实际显示比例」，即选了固定比例用固定比例，选「自适应」用视频原始比例。
  bool get _isLandscapeRatio => _displayAspectRatio >= 1.0;

  /// 当前全屏方向：被手动旋转过就听手动的，否则按画面比例推。
  bool get _landscapeNow => _forceLandscape ?? _isLandscapeRatio;

  /// 按当前画面比例决定全屏方向并进入沉浸式：
  /// 横版（16:9 / 21:9 / 1:1）→ 横屏；竖版（9:16 / 3:4）→ 保持竖屏。
  /// 用户点过旋转按钮后以手动值为准。
  Future<void> _applyFullscreenOrientation() async {
    if (_landscapeNow) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 全屏里的「旋转」按钮：把屏幕方向翻到另一侧。
  ///
  /// 判定基准取 [_landscapeNow] 而不是原始比例，所以点一下必定切到反面；
  /// 切完之后 `_forceLandscape` 会被记住，后续换集 / 调比例不会把方向抢回去。
  Future<void> _rotateFullscreen() async {
    _forceLandscape = !_landscapeNow;
    await _applyFullscreenOrientation();
    if (!mounted) return;
    setState(() {
      _aspectPanelOpen = false;
      _scalePanelOpen = false;
    });
  }

  // --------------------------------------------------------------------------
  // 画面比例 / 大小
  // --------------------------------------------------------------------------

  void _selectAspect(AspectOption option) {
    setState(() => _aspect = option);
    context.read<AppState>().setPlayerAspect(option.key);
    // 全屏中换比例，方向可能要从横屏切回竖屏（9:16）或反之
    if (_fullscreen) _applyFullscreenOrientation();
  }

  void _selectScale(ScaleOption option) {
    setState(() => _scaleMode = option);
    context.read<AppState>().setPlayerScale(option.key);
  }

  /// 视频自身的显示比例。
  ///
  /// 这里直接取 `value.size` 而不是 `value.aspectRatio`：后者在尺寸为空时会返回
  /// **1.0**，那会把画面摆进一个正方形里，比横屏拉伸更离谱。尺寸拿不到时退回 16:9。
  double get _naturalAspectRatio {
    final size = _controller.value.size;
    if (size.width > 0 && size.height > 0) {
      final ratio = size.width / size.height;
      if (ratio.isFinite && ratio > 0) return ratio;
    }
    return 16 / 9;
  }

  /// 画面区域实际使用的比例；选「自适应」时等于视频原始比例。
  /// 打开「交换宽高」后取倒数，用于纠正分辨率方向上报反了的源。
  double get _displayAspectRatio {
    final base = _aspect.ratio ?? _naturalAspectRatio;
    final ratio = _flip ? 1 / base : base;
    return (ratio.isFinite && ratio > 0) ? ratio : base;
  }

  void _toggleFlip() {
    setState(() => _flip = !_flip);
    context.read<AppState>().setPlayerFlip(_flip);
    // 宽高对调后横竖关系也可能反过来，全屏时要重新选方向
    if (_fullscreen) _applyFullscreenOrientation();
  }

  /// 画面区域的尺寸（宽度占满传入的可用宽度，高度按需要给）。
  ///
  /// 「适配屏幕 / 原始」要完整显示画面，高度按目标比例折算，超出可用高度时才取满；
  /// 「填充 / 拉伸」要铺满，直接占满可用高度。
  ///
  /// ⚠️ 关键：区域尺寸**不能**总是等于内容的形状。以前这里按比例算框，区域和内容
  /// 天然同形状，于是 contain / cover / fill 摆出来一模一样 —— 看起来就是
  /// 「画面大小（适配屏幕/填充/拉伸）全部失效」。
  Size _stageAreaSize(double boxWidth, double maxHeight) {
    final fit = _scaleMode.fit;
    if (fit == BoxFit.cover || fit == BoxFit.fill) {
      return Size(boxWidth, maxHeight);
    }
    final ratio = _displayAspectRatio;
    var height = ratio > 0 ? boxWidth / ratio : maxHeight;
    if (!height.isFinite || height <= 0 || height > maxHeight) height = maxHeight;
    return Size(boxWidth, height);
  }

  // --------------------------------------------------------------------------
  // 界面
  // --------------------------------------------------------------------------

  /// 系统返回键：全屏时先退出全屏，再按一次才退出播放页。
  ///
  /// 用 `PopScope` 而不是已废弃的 `WillPopScope`。
  /// `canPop` 是在 build 时求值的 —— 第一次返回把 `_fullscreen` 置 false 并触发重建，
  /// `canPop` 随之变成 true，第二次返回才真正 pop。
  /// ⚠️ 拦截分支里**不要**自己调 `Navigator.pop()`，否则会和系统正在进行的
  /// pop 流程打架（重复出栈 / 直接把播放页也弹掉）。
  @override
  Widget build(BuildContext context) {
    return PopScope(
      // PiP 模式下不响应系统返回：避免退出 PiP 时直接把播放页（乃至 App）pop 掉；
      // 退 PiP 由用户点小窗展开 / 上滑关闭，原生侧会回传 onPipModeChanged(false)。
      canPop: !_fullscreen && !_inPip,
      onPopInvokedWithResult: (didPop, result) {
        // didPop == true：系统已放行，无需接管
        if (didPop) return;
        if (_fullscreen) {
          _toggleFullscreen();
        }
        // _inPip 时什么都不做：交还给系统处理 PiP 窗口
      },
      child: Scaffold(
        backgroundColor: (_fullscreen || _inPip) ? Colors.black : null,
        appBar: (_fullscreen || _inPip)
            ? null
            : AppBar(title: Text(_title.isEmpty ? '播放' : _title)),
        body: _inPip
            ? _buildPipBody()
            : (_fullscreen ? _buildFullscreenBody() : _buildPortraitBody()),
      ),
    );
  }

  Widget _buildPortraitBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final frame = _stageAreaSize(
          constraints.maxWidth,
          constraints.maxHeight * _portraitMaxHeightRatio,
        );
        return Column(
          children: [
            _buildVideoArea(frame),
            _buildControlPanel(),
            Expanded(child: _buildInfo()),
          ],
        );
      },
    );
  }

  /// 画中画（PiP）模式下的画面：整屏纯黑底 + 居中视频，**不含任何 Flutter UI**
  /// （无标题栏、无进度条、无控制按钮、无详情）。这样 PiP 窗口里就是「全屏视频」，
  /// 而不是把整页（含控件）缩小塞进角落。
  Widget _buildPipBody() {
    // 仅桌面端（Windows/macOS/Linux）需要手动退出浮窗：系统无原生 PiP 关闭键。
    final isDesktop = Theme.of(context).platform == TargetPlatform.windows ||
        Theme.of(context).platform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.linux;
    return LayoutBuilder(
      builder: (context, constraints) {
        final frame = _stageAreaSize(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            if (isDesktop)
              GestureDetector(
                onDoubleTap: _exitPip,
                child: Container(
                  color: Colors.black,
                  child: Center(child: _buildStage(frame)),
                ),
              )
            else
              Container(
                color: Colors.black,
                child: Center(child: _buildStage(frame)),
              ),
            // 右上角退出按钮：点一下还原主窗（仅非桌面端需要——桌面端 PiP 用
            // 原生窗口标题栏的 X 关闭，Flutter 按钮会被标题栏盖住，故桌面端不显示）。
            if (!isDesktop)
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _exitPip,
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.close, size: 18, color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildFullscreenBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final frame = _stageAreaSize(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            Positioned.fill(
              child: Center(child: _buildStage(frame)),
            ),
            // 手势层铺满整屏（两侧留黑也能滑），但压在控制层之下。
            // 全屏时单击开关控制层，所以这里要多接管 onTap。
            _buildGestureLayer(allowTapToggle: true),
            // 控制层：淡入淡出；收起时用 IgnorePointer 让点击穿透到手势层
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: Listener(
                    // 摸到控制层就把自动隐藏重新计时（拖动进度条时不会中途消失）
                    onPointerDown: (_) => _scheduleHideControls(),
                    child: _buildOverlayControls(),
                  ),
                ),
              ),
            ),
            // 右上角实时网速 / 码率：与控制层无关，一直显示。
            // 套 IgnorePointer —— 否则这块区域会吃掉点击，右上角变成「点了没反应」的死区。
            if (_showSpeed && _netStats != null)
              Positioned(
                top: 10,
                right: 12,
                child: IgnorePointer(child: _buildNetStatsBadge(_netStats!)),
              ),
            if (_gestureActive)
              Positioned.fill(
                child: IgnorePointer(child: _buildGestureHud()),
              ),
            // 左右滑动快进 / 快退的居中提示
            if (_seekActive)
              Positioned.fill(
                child: IgnorePointer(child: _buildSeekHud()),
              ),
            // 长按加速提示（左上），与控制层无关，套 IgnorePointer 避免吃掉点击
            if (_longPressActive)
              Positioned(
                top: 10,
                left: 12,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xB3000000),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        '长按加速 ${_longPressRate.toStringAsFixed(1)}×',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 右上角的实时网速浮层。
  ///
  /// 缓冲已满时播放器不再下载，插件给的速度是「上一次采样」的值，
  /// 这时把速度调暗、并标一个「·」，避免被当成当前网速。
  Widget _buildNetStatsBadge(PlayerNetworkStats stats) {
    final stale = !stats.fresh;
    final speedColor = stale ? Colors.white54 : const Color(0xFF6DD143);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xB3000000),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_downward_rounded, size: 13, color: speedColor),
            const SizedBox(width: 3),
            Text(
              VideoNetworkStats.formatSpeed(stats.speedBps),
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: speedColor,
              ),
            ),
            if (stale)
              const Text(
                ' ·',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 全屏手势：左右滑动快进快退 + 长按加速
  // --------------------------------------------------------------------------

  /// 当前播放进度的归一化比例（0~1）
  double get _positionFraction {
    final total = _controller.value.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_controller.value.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// 横向滑动起点：记下当前进度与手指横坐标，整屏宽度对应 [_seekSpanSeconds] 秒。
  void _onSeekStart(DragStartDetails details, double width) {
    if (!_fullscreen) return;
    if (!_controller.value.isInitialized) return;
    setState(() {
      _seekActive = true;
      _seekBaseFraction = _positionFraction;
      _seekStartDx = details.localPosition.dx;
      _seekTrackWidth = width;
      _seekDeltaSeconds = 0;
      _seekPreviewFraction = _seekBaseFraction;
    });
  }

  void _onSeekUpdate(DragUpdateDetails details) {
    if (!_seekActive) return;
    final total = _controller.value.duration.inMilliseconds.toDouble();
    if (total <= 0 || _seekTrackWidth <= 0) return;
    final deltaFraction = ((details.localPosition.dx - _seekStartDx) /
            _seekTrackWidth) *
        (_seekSpanSeconds * 1000 / total);
    final fraction = (_seekBaseFraction + deltaFraction).clamp(0.0, 1.0);
    setState(() {
      _seekPreviewFraction = fraction;
      _seekDeltaSeconds = (fraction - _seekBaseFraction) * total / 1000;
    });
    _controller.seekTo(Duration(milliseconds: (fraction * total).round()));
  }

  void _onSeekEnd() {
    if (!_seekActive) return;
    setState(() {
      _seekActive = false;
      _seekPreviewFraction = 0;
      _seekDeltaSeconds = 0;
    });
  }

  /// 长按开始：把播放速度提到设定的倍率。
  /// video_player 底层走 ExoPlayer 的 PlaybackParameters，支持任意正数倍率，
  /// 大于 2.0 时会用跳帧方式实现，2 / 4 / 8 都没问题。
  void _onLongPressStart() {
    if (!_fullscreen) return;
    if (!_controller.value.isInitialized) return;
    _controller.setPlaybackSpeed(_longPressRate);
    setState(() => _longPressActive = true);
  }

  /// 长按结束：恢复正常速度（本 App 基础速度恒为 1.0，没有别的速度设置项）。
  void _onLongPressEnd() {
    _controller.setPlaybackSpeed(1.0);
    setState(() => _longPressActive = false);
  }

  /// 左右滑动 seek 时的居中提示：目标时间 + 快进 / 快退秒数。
  Widget _buildSeekHud() {
    final duration = _controller.value.duration;
    final target = Duration(
      milliseconds: (_seekPreviewFraction * duration.inMilliseconds).round(),
    );
    final delta = _seekDeltaSeconds;
    final sign = delta >= 0 ? '+' : '−';
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xD9000000),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${_fmt(target)} / ${_fmt(duration)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$sign ${delta.abs().toStringAsFixed(0)} 秒',
              style: TextStyle(
                color: delta >= 0 ? const Color(0xFF6DD143) : Colors.white,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 画面手势层（竖屏画面区域 / 全屏共用）。
  ///
  /// 左半屏上下滑动调亮度、右半屏调音量，向上滑为增大；双击暂停 / 继续。
  /// 必须是 `HitTestBehavior.opaque`：竖屏时它盖在 `_buildStage` 之上，
  /// 命中即止，所以下层的点击收不到 —— 双击也得在本层处理。
  ///
  /// [allowTapToggle] 只有全屏才开：单击画面显示 / 收起控制层。
  /// 竖屏的控制层常驻，不需要这个手势，留着反而会白白吃掉一次点击。
  Widget _buildGestureLayer({bool allowTapToggle = false}) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final halfWidth = constraints.maxWidth / 2;
          final width = constraints.maxWidth;
          final span =
              constraints.maxHeight * 0.7 > 0 ? constraints.maxHeight * 0.7 : 400.0;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 全屏单击：显示 / 收起进度条与按钮行
            onTap: allowTapToggle ? _toggleControls : null,
            // 双击暂停 / 继续，与竖屏一致
            onDoubleTap: _togglePlay,
            // 左半屏上下滑调亮度、右半屏调音量，向上滑为增大
            onVerticalDragStart: (details) {
              final isBrightness = details.localPosition.dx < halfWidth;
              setState(() {
                _gestureActive = true;
                _gestureIsBrightness = isBrightness;
                _gestureValue = isBrightness ? _brightness : _volume;
                _gestureSpan = span;
              });
            },
            onVerticalDragUpdate: (details) {
              if (!_gestureActive) return;
              // dy 为负（向上滑）时增大
              final next =
                  (_gestureValue - details.delta.dy / _gestureSpan).clamp(0.0, 1.0).toDouble();
              setState(() => _gestureValue = next);
              if (_gestureIsBrightness) {
                _brightness = next;
                SystemControl.setBrightness(next);
              } else {
                _volume = next;
                SystemControl.setVolume(next);
              }
            },
            onVerticalDragEnd: (_) => setState(() => _gestureActive = false),
            onVerticalDragCancel: () => setState(() => _gestureActive = false),
            // 全屏左右滑动快进 / 快退（横竖手势由 Flutter 竞技场自动按主方向分流，
            // 不需要手动判断）。只在全屏启用，竖屏无此手势。
            onHorizontalDragStart:
                _fullscreen ? (d) => _onSeekStart(d, width) : null,
            onHorizontalDragUpdate: _fullscreen ? _onSeekUpdate : null,
            onHorizontalDragEnd: _fullscreen ? (_) => _onSeekEnd() : null,
            onHorizontalDragCancel: _fullscreen ? () => _onSeekEnd() : null,
            // 全屏长按加速：按下提到倍率速度，松手恢复 1.0
            onLongPressStart: _fullscreen ? (_) => _onLongPressStart() : null,
            onLongPressEnd: _fullscreen ? (_) => _onLongPressEnd() : null,
          );
        },
      ),
    );
  }

  /// 滑动过程中居中的提示：图标 + 「亮度/音量 xx%」+ 进度条
  Widget _buildGestureHud() {
    final isBrightness = _gestureIsBrightness;
    final value = _gestureValue.clamp(0.0, 1.0).toDouble();
    final IconData icon;
    if (isBrightness) {
      icon = Icons.brightness_medium_rounded;
    } else if (value <= 0) {
      icon = Icons.volume_off_rounded;
    } else if (value < 0.5) {
      icon = Icons.volume_down_rounded;
    } else {
      icon = Icons.volume_up_rounded;
    }
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xD9000000),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 24),
                const SizedBox(width: 10),
                Text(
                  '${isBrightness ? '亮度' : '音量'} ${(value * 100).round()}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: 160,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(3),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value,
                child: const ColoredBox(
                  color: Colors.white,
                  child: SizedBox(height: 5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 竖屏：黑底容器的高度就是画面区域的高度，区域形状见 `_stageAreaSize`。
  ///
  /// 画面之上再叠一层手势层（与全屏同一套实现）：左半屏上下滑调亮度、
  /// 右半屏调音量、双击暂停。只在视频就绪后挂上，加载中 / 失败时不拦点击。
  Widget _buildVideoArea(Size area) {
    final interactive = _initialized && !_hasError;
    return ColoredBox(
      color: Colors.black,
      child: SizedBox(
        width: area.width,
        height: area.height,
        child: Stack(
          children: [
            Positioned.fill(child: _buildStage(area)),
            if (interactive) _buildGestureLayer(),
            if (interactive && _gestureActive)
              Positioned.fill(child: IgnorePointer(child: _buildGestureHud())),
          ],
        ),
      ),
    );
  }

  /// 画面区域：外层定尺寸，内部由 `_buildStageContent` 决定内容怎么放
  Widget _buildStage(Size area) {
    return SizedBox(
      width: area.width,
      height: area.height,
      child: _buildStageContent(),
    );
  }

  Widget _buildStageContent() {
    if (_hasError) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('播放失败，请更换视频源或线路',
                    style: TextStyle(color: Colors.white70)),
                if (_lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(_lastError!,
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                      textAlign: TextAlign.center,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _openExternalFromError,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('用外部播放器打开'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_initialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final natural = _naturalAspectRatio;
    // ① 纹理先铺进一个「视频原始方向」的盒子里；开了「交换宽高」就把整个盒子转 90°，
    //    这才是真的把宽高对调 —— 只改画框形状那是拉伸，不是交换。
    Widget surface = SizedBox(
      width: natural * 1000,
      height: 1000,
      child: VideoPlayer(_controller),
    );
    if (_flip) {
      surface = RotatedBox(quarterTurns: 1, child: surface);
    }

    // ②「画面比例」：把纹理装进目标形状的盒子。自适应时目标形状就是视频原始形状，
    //    这一步等价于不变形。
    final ratio = _displayAspectRatio;
    final shape = ratio >= 1
        ? Size(ratio * 1000, 1000)
        : Size(1000, 1000 / ratio);
    final shaped = SizedBox(
      width: shape.width,
      height: shape.height,
      child: FittedBox(
        fit: BoxFit.fill,
        clipBehavior: Clip.hardEdge,
        child: surface,
      ),
    );

    // ③「画面大小」：把这个形状盒子放进画面区域。区域形状由 `_stageAreaSize` 决定，
    //    所以 contain / cover / fill 才会呈现出真正不同的结果。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 双击暂停 / 继续（单击不再触发，避免误触）
      onDoubleTap: _togglePlay,
      child: ClipRect(
        child: FittedBox(
          fit: _scaleMode.fit,
          clipBehavior: Clip.hardEdge,
          child: shaped,
        ),
      ),
    );
  }

  /// 竖屏控制面板（放在画面下方，跟主题色）
  Widget _buildControlPanel() {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressRow(),
            _buildButtonRow(),
            if (_aspectPanelOpen) _buildAspectPanel(),
            if (_scalePanelOpen) _buildScalePanel(),
            const Divider(height: 1),
          ],
        );
      },
    );
  }

  /// 全屏控制层（浮在画面上，白色前景 + 底部渐变保证可读）
  Widget _buildOverlayControls() {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xCC000000)],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildProgressRow(),
                _buildButtonRow(),
                if (_aspectPanelOpen) _buildAspectPanel(),
                if (_scalePanelOpen) _buildScalePanel(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 进度条独占一行。
  ///
  /// 用自绘的 `_ProgressSlider` 代替官方的 `VideoProgressIndicator`：后者内部固定用
  /// `LinearProgressIndicator`（minHeight 只有 4），条子细得几乎点不中，只能靠
  /// padding 撑触摸区。现在「条子粗细」「触摸高度」「手柄大小」三个尺寸分开控制，
  /// 全屏整体放大一圈，手指容易瞄。
  Widget _buildProgressRow() {
    final value = _controller.value;
    // 深色（含全屏深色视频底）下轨道用浅色，否则黑底黑条看不见；
    // 浅色模式沿用深色半透明轨道，叠在浅色控制面板上才看得清。
    final darkTrack =
        _fullscreen || Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: _ProgressSlider(
              controller: _controller,
              barHeight: _fullscreen ? 10 : 6,
              touchHeight: _fullscreen ? 48 : 36,
              thumbSize: _fullscreen ? 20 : 14,
              playedColor: _accent,
              bufferedColor: darkTrack
                  ? const Color(0x80FFFFFF)
                  : const Color(0x40000000),
              backgroundColor: darkTrack
                  ? const Color(0x33FFFFFF)
                  : const Color(0x1F000000),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${_fmt(value.position)} / ${_fmt(value.duration)}',
            style: TextStyle(fontSize: 12, color: _fgDim),
          ),
        ],
      ),
    );
  }

  Widget _buildButtonRow() {
    final value = _controller.value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          _controlButton(
            icon: value.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            label: value.isPlaying ? '暂停' : '播放',
            onTap: () =>
                value.isPlaying ? _controller.pause() : _controller.play(),
          ),
          // 下一集：仅多集视频显示，放在播放/暂停右边
          if (_playList.length > 1)
            _controlButton(
              icon: Icons.skip_next_rounded,
              label: '下一集',
              onTap: _playNextEpisode,
            ),
          _controlButton(
            icon: Icons.aspect_ratio_rounded,
            label: _aspect.label,
            active: _aspectPanelOpen,
            onTap: () => setState(() {
              _aspectPanelOpen = !_aspectPanelOpen;
              _scalePanelOpen = false;
            }),
          ),
          _controlButton(
            icon: Icons.fit_screen_rounded,
            label: _scaleMode.label,
            active: _scalePanelOpen,
            onTap: () => setState(() {
              _scalePanelOpen = !_scalePanelOpen;
              _aspectPanelOpen = false;
            }),
          ),
          _controlButton(
            icon: context.watch<AppState>().isStarred(_recordKey)
                ? Icons.star_rounded
                : Icons.star_border_rounded,
            label:
                context.watch<AppState>().isStarred(_recordKey) ? '已收藏' : '收藏',
            tint: context.watch<AppState>().isStarred(_recordKey)
                ? const Color(0xFFFF4445)
                : null,
            onTap: _toggleStar,
          ),
          _controlButton(
            icon: Icons.picture_in_picture_rounded,
            label: '画中画',
            onTap: _enterPip,
          ),
          if (_playList.length > 1)
            _controlButton(
              icon: Icons.playlist_play_rounded,
              label: '选集',
              onTap: _showEpisodePicker,
            ),
          // 全屏才有意义：竖屏页面本身被锁在竖屏
          if (_fullscreen)
            _controlButton(
              icon: _landscapeNow
                  ? Icons.stay_current_portrait_rounded
                  : Icons.stay_current_landscape_rounded,
              label: _landscapeNow ? '切竖屏' : '切横屏',
              onTap: _rotateFullscreen,
            ),
          _controlButton(
            icon: _isDesktop && !_fullscreen
                ? Icons.crop_free_rounded
                : (_fullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded),
            label: _fullscreen
                ? '退出全屏'
                : (_isDesktop ? '填满' : '全屏'),
            onTap: _toggleFullscreen,
          ),
          // 桌面端独有：真正把窗口铺满整个屏幕（无边框、盖任务栏），区别于上面的
          // 「填满」(仅视频铺满应用窗口)。移动端系统级全屏已足够，不显示。
          if (_isDesktop)
            _controlButton(
              icon: _nativeFullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              label: _nativeFullscreen ? '退出全屏' : '全屏',
              onTap: _toggleNativeFullscreen,
            ),
        ],
      ),
    );
  }

  Widget _buildAspectPanel() {
    return _buildPanel(
      title: _aspect.ratio == null
          ? '画面比例 · 自适应（跟随视频原始比例）'
          : '画面比例 · ${_aspect.label}（画面会变成该形状）',
      children: [
        for (final option in PlayerAspects.all)
          _buildChip(
            label: option.label,
            selected: option.key == _aspect.key,
            onTap: () => _selectAspect(option),
          ),
        // 少数源上报的分辨率方向与实际画面相反（竖屏视频被当成横屏），
        // 用这个一键把宽高对调；选择会被记住
        _buildChip(
          label: '⇄ 交换宽高',
          selected: _flip,
          onTap: _toggleFlip,
        ),
      ],
    );
  }

  Widget _buildScalePanel() {
    return _buildPanel(
      title: '画面大小 · ${_scaleMode.desc}',
      children: [
        for (final option in PlayerScales.all)
          _buildChip(
            label: option.label,
            selected: option.key == _scaleMode.key,
            onTap: () => _selectScale(option),
          ),
      ],
    );
  }

  Widget _buildPanel({required String title, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 11, color: _fgDim)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }

  Widget _buildChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _accent : Colors.transparent,
          border: Border.all(color: selected ? _accent : _borderColor),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : _fg,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 等宽的控制按钮：图标 + 文字，选中态用主题蓝
  Widget _controlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color? tint,
  }) {
    final color = tint ?? (active ? _accent : _fg);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfo() {
    final detail = _detail;
    if (detail == null) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
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
          const SizedBox(height: 10),
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
          const SizedBox(height: 18),
          _buildPlaybackInfo(),
        ],
      ),
    );
  }

  /// 播放信息诊断块。
  /// 排查「画面被拉伸」时看这里：把「上报尺寸」和「实际显示」比一比，
  /// 就能判断是视频源给的比例不对（两者方向相反），还是渲染的问题。
  Widget _buildPlaybackInfo() {
    final value = _controller.value;
    final size = value.size;
    final screen = MediaQuery.of(context).size;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 14, color: _fgDim),
              const SizedBox(width: 6),
              Text(
                '播放信息',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _fgDim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '上报尺寸     ${size.width.toStringAsFixed(0)} × ${size.height.toStringAsFixed(0)}\n'
            '上报比例     ${_describeRatio(_naturalAspectRatio)}\n'
            '实际显示     ${_describeRatio(_displayAspectRatio)}${_flip ? '（已交换宽高）' : ''}\n'
            '旋转修正     ${value.rotationCorrection}°\n'
            '画面比例     ${_aspect.label}　画面大小　${_scaleMode.label}\n'
            '屏幕尺寸     ${screen.width.toStringAsFixed(0)} × ${screen.height.toStringAsFixed(0)}\n'
            'Android API  ${_sdkInt == 0 ? '读取中…' : _sdkInt}',
            style: TextStyle(fontSize: 11, height: 1.7, color: _fgDim),
          ),
        ],
      ),
    );
  }

  static String _describeRatio(double ratio) {
    if (!ratio.isFinite || ratio <= 0) return '—';
    return '${ratio.toStringAsFixed(3)}（${ratio >= 1 ? '横' : '竖'}）';
  }

  // --------------------------------------------------------------------------
  // 配色：全屏是深色底，用白色前景；竖屏跟随主题
  // --------------------------------------------------------------------------

  Color get _fg =>
      _fullscreen ? Colors.white : Theme.of(context).colorScheme.onSurface;

  Color get _fgDim => _fullscreen
      ? Colors.white70
      : Theme.of(context).colorScheme.onSurfaceVariant;

  Color get _borderColor => _fullscreen
      ? Colors.white38
      : Theme.of(context).colorScheme.outlineVariant;

  static String _fmt(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

/// 自绘进度条：可拖动 / 可点击跳转，带已缓冲区间和圆形手柄。
///
/// 与官方 `VideoProgressIndicator` 的区别（也是换掉它的原因）：
/// `barHeight`（条子粗细）、`touchHeight`（触摸区域高度）、`thumbSize`（手柄直径）
/// 三个尺寸完全独立，条子能做得足够粗、触摸区足够高，全屏时手指不容易点偏。
///
/// 手柄圆心沿着「左内缩 thumbSize/2 ~ 右内缩 thumbSize/2」的轨道移动，
/// 所以 fraction = 0 / 1 时手柄刚好贴住两端，不会被裁掉。
class _ProgressSlider extends StatefulWidget {
  const _ProgressSlider({
    required this.controller,
    required this.barHeight,
    required this.touchHeight,
    required this.thumbSize,
    required this.playedColor,
    required this.bufferedColor,
    required this.backgroundColor,
  });

  final VideoPlayerController controller;
  final double barHeight;
  final double touchHeight;
  final double thumbSize;
  final Color playedColor;
  final Color bufferedColor;
  final Color backgroundColor;

  @override
  State<_ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<_ProgressSlider> {
  /// 拖动 / 点击过程中手指对应的进度（0~1）。
  /// 非 null 时优先显示它，避免 `seekTo` 生效前的跳回；抬手后置回 null。
  double? _pending;

  /// 拖动前是否在播放，抬手时恢复
  bool _wasPlaying = false;

  VideoPlayerController get _controller => widget.controller;

  double get _durationMs => _controller.value.duration.inMilliseconds.toDouble();

  double get _fraction {
    final pending = _pending;
    if (pending != null) return pending;
    final total = _durationMs;
    if (total <= 0) return 0;
    return (_controller.value.position.inMilliseconds / total)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  double get _bufferedFraction {
    final total = _durationMs;
    if (total <= 0) return 0;
    var maxEnd = 0.0;
    for (final range in _controller.value.buffered) {
      final end = range.end.inMilliseconds.toDouble();
      if (end > maxEnd) maxEnd = end;
    }
    return (maxEnd / total).clamp(0.0, 1.0).toDouble();
  }

  double _fractionAt(double dx, double trackWidth) =>
      ((dx - widget.thumbSize / 2) / trackWidth).clamp(0.0, 1.0).toDouble();

  /// 按手指位置跳转。`trackWidth` 为 0（宽度还没量出来）时什么都不做。
  void _seekTo(double dx, double trackWidth) {
    final value = _controller.value;
    if (!value.isInitialized) return;
    final total = _durationMs;
    if (total <= 0 || trackWidth <= 0) return;
    final fraction = _fractionAt(dx, trackWidth);
    setState(() => _pending = fraction);
    _controller.seekTo(Duration(milliseconds: (total * fraction).round()));
  }

  void _onDragStart(double dx, double trackWidth) {
    if (!_controller.value.isInitialized) return;
    _wasPlaying = _controller.value.isPlaying;
    // 拖动期间先暂停，抬手再续播，跟官方 scrubber 行为一致
    if (_wasPlaying) _controller.pause();
    _seekTo(dx, trackWidth);
  }

  void _onDragEnd() {
    if (_pending != null) setState(() => _pending = null);
    final value = _controller.value;
    if (_wasPlaying && value.position != value.duration) {
      _controller.play();
    }
    _wasPlaying = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final trackWidth =
            (width - widget.thumbSize).clamp(0.0, width).toDouble();
        final fraction = _fraction;
        final buffered = _bufferedFraction;
        final barTop = (widget.touchHeight - widget.barHeight) / 2;
        final thumbTop = (widget.touchHeight - widget.thumbSize) / 2;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 点一下就跳到该位置，按住横向拖动连续跟随
          onTapDown: (d) => _seekTo(d.localPosition.dx, trackWidth),
          onTapUp: (_) => _onDragEnd(),
          onTapCancel: _onDragEnd,
          onHorizontalDragStart: (d) =>
              _onDragStart(d.localPosition.dx, trackWidth),
          onHorizontalDragUpdate: (d) => _seekTo(d.localPosition.dx, trackWidth),
          onHorizontalDragEnd: (_) => _onDragEnd(),
          onHorizontalDragCancel: _onDragEnd,
          child: SizedBox(
            width: width,
            height: widget.touchHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: widget.thumbSize / 2,
                  right: widget.thumbSize / 2,
                  top: barTop,
                  height: widget.barHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.barHeight / 2),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ColoredBox(color: widget.backgroundColor),
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: trackWidth * buffered,
                          child: ColoredBox(color: widget.bufferedColor),
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: trackWidth * fraction,
                          child: ColoredBox(color: widget.playedColor),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: trackWidth * fraction,
                  top: thumbTop,
                  width: widget.thumbSize,
                  height: widget.thumbSize,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.playedColor,
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x4D000000),
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
