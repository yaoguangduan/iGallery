import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 可滑动预览（上传选择器 / 本地相册）里的视频页。
///
/// 为什么不用 `AdaptiveVideoControls`：它铺满整页的手势层会赢下横向拖动，
/// PageView 收不到 → "遇到视频就不能左右滑动"。这里改用 `NoVideoControls`，
/// 只在底部放一条细进度条（它的横向拖动只作用于自己这一条），其余整片区域
/// 都让给 PageView 横滑；中间轻点切换播放/暂停（点按不与横滑竞争）。
class PreviewVideo extends StatefulWidget {
  final Player player;
  final VideoController controller;

  const PreviewVideo({
    super.key,
    required this.player,
    required this.controller,
  });

  @override
  State<PreviewVideo> createState() => _PreviewVideoState();
}

class _PreviewVideoState extends State<PreviewVideo>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台/锁屏暂停：media_kit 在 Android 不自动停，否则看不见画面声音还在放
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      widget.player.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Video(
          controller: widget.controller,
          controls: NoVideoControls,
          fill: Colors.black,
        ),
        // 中间轻点播放/暂停：translucent + 只挂 onTap，横向拖动照样冒泡给 PageView
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (widget.player.state.playing) {
                widget.player.pause();
              } else {
                widget.player.play();
              }
            },
            child: const SizedBox.expand(),
          ),
        ),
        // 底部细进度条：横向拖动仅命中这一条，不影响其余区域翻页
        Positioned(
          left: 4,
          right: 4,
          bottom: 2,
          child: _SeekBar(player: widget.player),
        ),
      ],
    );
  }
}

class _SeekBar extends StatelessWidget {
  final Player player;
  const _SeekBar({required this.player});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration.zero;
        final maxMs = dur.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final value = pos.inMilliseconds
                .toDouble()
                .clamp(0.0, maxMs > 0 ? maxMs : 1.0);
            return SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                max: maxMs > 0 ? maxMs : 1.0,
                onChanged: maxMs > 0
                    ? (v) => player.seek(Duration(milliseconds: v.toInt()))
                    : null,
              ),
            );
          },
        );
      },
    );
  }
}
