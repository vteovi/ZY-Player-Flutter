import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 应用内「小窗」悬浮播放的全局持有者。
///
/// 播放页点「小窗」时，把正在播放的 [VideoPlayerController] 转移过来，
/// 在根 Overlay 上挂一个可拖动的迷你播放器；播放页随之退出。
/// 控制器不被释放，所以小窗里视频继续播。点小窗可回到播放页续播，
/// 点关闭才真正 dispose。
class FloatingPlayer {
  FloatingPlayer._();

  /// 单例：整个 App 同时只允许一个小窗。
  static final FloatingPlayer instance = FloatingPlayer._();

  VideoPlayerController? controller;
  String title = '';
  String url = '';
  String siteKey = '';
  String videoId = '';
  double initialTime = 0;

  /// 当前挂着的 OverlayEntry，关闭/续播时移除它。
  OverlayEntry? entry;

  bool get active => controller != null;

  void attach(
    VideoPlayerController c, {
    required String title,
    required String url,
    required String siteKey,
    required String videoId,
    required double initialTime,
  }) {
    controller = c;
    this.title = title;
    this.url = url;
    this.siteKey = siteKey;
    this.videoId = videoId;
    this.initialTime = initialTime;
  }

  void detach() {
    controller = null;
    entry = null;
  }
}

/// 可拖动的迷你播放器：视频铺满小窗，右上角关闭按钮，点击小窗「续播」。
class FloatingPlayerWidget extends StatefulWidget {
  final VideoPlayerController controller;
  final String title;
  final VoidCallback onExpand;
  final VoidCallback onClose;

  const FloatingPlayerWidget({
    super.key,
    required this.controller,
    required this.title,
    required this.onExpand,
    required this.onClose,
  });

  @override
  State<FloatingPlayerWidget> createState() => _FloatingPlayerWidgetState();
}

class _FloatingPlayerWidgetState extends State<FloatingPlayerWidget> {
  static const double _w = 140;
  static const double _h = 80;

  late Offset _pos;

  @override
  void initState() {
    super.initState();
    final m = MediaQuery.of(context).size;
    // 默认落在右下角
    _pos = Offset(m.width - _w - 12, m.height - _h - 12);
  }

  @override
  Widget build(BuildContext context) {
    final m = MediaQuery.of(context).size;
    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: Draggable(
        feedback: _box(opacity: 0.92),
        childWhenDragging: const SizedBox.shrink(),
        onDragEnd: (d) {
          setState(() {
            _pos = Offset(
              d.offset.dx.clamp(0, m.width - _w),
              d.offset.dy.clamp(0, m.height - _h),
            );
          });
        },
        child: GestureDetector(
          onTap: widget.onExpand,
          child: Stack(
            children: [
              _box(),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  // 关闭按钮要吞掉 tap，不能触发「续播」
                  onTap: widget.onClose,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x80000000),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _box({double opacity = 1}) => Opacity(
        opacity: opacity,
        child: SizedBox(
          width: _w,
          height: _h,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.black,
              // 视频纹理铺满小窗；cover 保证不变形
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _w * 2,
                  height: _h * 2,
                  child: VideoPlayer(widget.controller),
                ),
              ),
            ),
          ),
        ),
      );
}
