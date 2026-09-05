import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_view/photo_view.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/disk_cache.dart';
import '../../core/display_prefs.dart';
import '../../core/download_service.dart';
import '../../core/hash_sync.dart';
import '../../core/kv_store.dart';
import '../../core/media_service.dart';
import '../../core/platform.dart';
import '../../core/time_fmt.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';

/// 查看器是"永远深色"的独立空间（YouTube 播放器同理）。
/// 黑底上主题的 brand(#065FD4) 对比度不足，这里用提亮版本。
const Color _kViewerAccent = Color(0xFF5B9DFF);
const Color _kViewerDanger = Color(0xFFFF6B6B);
const Color _kViewerFav = Color(0xFFFFFFFF);

/// mm:ss / h:mm:ss。播放时长不是日期，不走 core/time_fmt.dart。
String _fmtClock(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

class MediaViewer extends StatefulWidget {
  final List<MediaItem> items;
  final int initialIndex;
  final MediaService service;
  final void Function(String id)? onDeleted;
  final VoidCallback onClose;
  /// 移动端下载成功后"查看"→ 切到本地 tab。桌面端没有本地 tab，传 null。
  final VoidCallback? onViewLocal;
  /// 相册网格处于选择态时打开查看器：右上角显示选择圆圈、中间显示已选数量，
  /// 隐藏收藏/分享/更多（此刻查看器的职责是"边看边选"，不是管理单张）。
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<String>? onToggleSelect;

  const MediaViewer({super.key, required this.items, required this.initialIndex,
    required this.service, required this.onClose, this.onDeleted,
    this.onViewLocal, this.selecting = false, this.selectedIds = const {},
    this.onToggleSelect});

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final PageController _pageCtrl;
  late final AnimationController _enterCtrl;
  late int _current;
  Player? _player;
  VideoController? _videoCtrl;

  bool _showUI = true;
  late bool _showDetails;
  bool _videoPausedForDetails = false;

  // 视频加载失败态。没有它的话，服务器挂了/令牌失效时视频就是一片黑屏，
  // 用户不知道发生了什么，也没有重试入口。
  bool _videoFailed = false;
  StreamSubscription<dynamic>? _videoErrSub;
  Timer? _videoOpenWatchdog;

  PhotoViewController? _photoCtrl;
  double _scale = 1.0;
  double _baseScale = 1.0; // contained scale (fit-to-view)

  // 选择态本地副本：查看器自己持有，切换时经 onToggleSelect 同步回相册网格
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _current = widget.initialIndex;
    _showDetails = widget.items[_current].isImage;
    _selected = Set<String>.from(widget.selectedIds);
    _pageCtrl = PageController(initialPage: _current);
    _enterCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _enterCtrl.forward();
    _resetPhotoCtrl();
    _initVideo();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台/锁屏就暂停视频：media_kit 在 Android 不会自动停，
    // 否则看不见画面了声音还在放。回到前台不自动续播（避免突兀），用户自己点。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _player?.pause();
    }
  }

  @override
  void didUpdateWidget(covariant MediaViewer old) {
    super.didUpdateWidget(old);
    // 防御：items 被上层删短后 _current 可能越界，夹回合法范围，避免 build 时 RangeError
    if (widget.items.isNotEmpty && _current >= widget.items.length) {
      _current = widget.items.length - 1;
      _initVideo();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageCtrl.dispose();
    _enterCtrl.dispose();
    _videoErrSub?.cancel();
    _videoOpenWatchdog?.cancel();
    _player?.dispose();
    _photoCtrl?.dispose();
    super.dispose();
  }

  MediaItem get _item => widget.items[_current];
  bool get _isImage => _item.isImage;
  bool get _isCurSelected => _selected.contains(_item.id);

  /// 选择态下切换当前项选中，并同步回相册网格（底部操作条随之更新）
  void _toggleSelectCurrent() {
    final id = _item.id;
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
    widget.onToggleSelect?.call(id);
  }

  void _resetPhotoCtrl() {
    _photoCtrl?.dispose();
    _photoCtrl = PhotoViewController();
    _scale = 1.0;
    _baseScale = 1.0;
    _photoCtrl!.outputStateStream.listen((s) {
      final raw = s.scale ?? 1.0;
      if (_baseScale == 1.0 && raw > 0) _baseScale = raw;
      if (mounted) setState(() => _scale = raw);
    });
  }

  void _initVideo() {
    _player?.dispose();
    _player = null;
    _videoCtrl = null;
    _videoErrSub?.cancel();
    _videoErrSub = null;
    _videoOpenWatchdog?.cancel();
    _videoOpenWatchdog = null;
    _videoFailed = false;
    _resetPhotoCtrl();
    if (_item.isVideo) {
      _player = Player();
      _videoCtrl = VideoController(_player!);
      // media_kit 解码/拉流出错会往这个流里发消息；不监听的话就是黑屏
      _videoErrSub = _player!.stream.error.listen((_) => _markVideoFailed());
      _openVideo(_item);
      // 兜底看门狗：有些失败（比如网络掐了）不走 error 流，
      // 30 秒既没播起来也没解析出时长，就当作加载失败，别让用户干等黑屏
      _videoOpenWatchdog = Timer(const Duration(seconds: 30), () {
        final p = _player;
        if (p == null || _videoFailed) return;
        if (!p.state.playing && p.state.duration.inMilliseconds <= 0) {
          _markVideoFailed();
        }
      });
    }
  }

  void _markVideoFailed() {
    if (!mounted || _videoFailed) return;
    setState(() => _videoFailed = true);
    _player?.pause();
  }

  /// 用户点"重试"：重新打开当前视频
  void _retryVideo() {
    setState(() => _videoFailed = false);
    _videoOpenWatchdog?.cancel();
    _videoOpenWatchdog = Timer(const Duration(seconds: 30), () {
      final p = _player;
      if (p == null || _videoFailed) return;
      if (!p.state.playing && p.state.duration.inMilliseconds <= 0) {
        _markVideoFailed();
      }
    });
    _openVideo(_item);
  }

  /// 视频：命中缓存直接播本地，否则同时启动播放 (http) 和后台下载
  void _openVideo(MediaItem item) {
    final cached = DiskCache.instance.cachedMediaSync(item.id);
    if (cached != null) {
      _player?.open(Media(cached.path));
      return;
    }
    _player?.open(Media(
      widget.service.fullUrl(item.id),
      httpHeaders: widget.service.authHeaders,
    ));
    // 后台缓存（小视频 <= 50MB），播完再看下次就是本地
    unawaited(DiskCache.instance.getMedia(
      item.id,
      widget.service.fullUrl(item.id),
      widget.service.authHeaders,
      isVideo: true,
      knownSize: item.size,
    ));
  }

  // ── 关闭（带动画）──
  void _close() {
    _enterCtrl.reverse().then((_) => widget.onClose());
  }

  // ── 缩放：相对于 contained 的百分比，10% 步进 ──
  int get _zoomPercent => _baseScale > 0 ? ((_scale / _baseScale) * 100).round() : 100;

  void _zoomByPercent(int delta) {
    final current = _zoomPercent;
    final target = ((current + delta) / 10).round() * 10; // snap to 10%
    _photoCtrl?.scale = (_baseScale * target / 100).clamp(_baseScale * 0.1, _baseScale * 10);
  }
  static const _zoomSteps = [100, 150, 200, 50];
  void _cycleZoom() {
    final cur = _zoomPercent;
    final idx = _zoomSteps.indexWhere((s) => s > cur);
    final target = idx >= 0 ? _zoomSteps[idx] : _zoomSteps[0];
    _photoCtrl?.scale = (_baseScale * target / 100).clamp(_baseScale * 0.1, _baseScale * 10);
  }
  void _resetZoom() { _photoCtrl?.scale = _baseScale; }

  // ── 导航 ──
  void _goTo(int i) {
    if (i < 0 || i >= widget.items.length) return;
    _pageCtrl.animateToPage(i, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  // ── 删除 ──
  Future<void> _delete() async {
    final ok = await appConfirmDialog(context, title: '删除', message: '确定删除 ${_item.filename}？',
        confirmLabel: '删除', destructive: true);
    if (!ok || !mounted) return;
    final id = _item.id;
    final name = _item.filename;
    try {
      await widget.service.delete(id);
    } on ApiException catch (e) {
      if (mounted) showToast(context, '删除失败: ${e.displayMessage}', kind: ToastKind.error);
      return;
    } catch (_) {
      if (mounted) showToast(context, '删除失败', kind: ToastKind.error);
      return;
    }
    if (!mounted) return;
    showToast(context, '已删除 $name', kind: ToastKind.success);
    HashSync.instance.syncFromServer();
    // 移除交给上层 onDeleted：它从共享列表(shell 的 _viewerItems / 桌面的 _viewerSnapshot)
    // 摘掉该项，列表空了顺带关掉查看器。旧写法在这里既 removeWhere 又用 length<=1 判断，
    // 会在还剩 1 张时误关查看器（本该显示幸存的那张）。
    widget.onDeleted?.call(id);
    if (!mounted || widget.items.isEmpty) return;
    setState(() {
      if (_current >= widget.items.length) _current = widget.items.length - 1;
      _initVideo();
    });
  }

  Future<void> _toggleFavorite() async {
    final item = _item;
    final target = !item.isFavorite;
    try {
      final updated = await widget.service.updateFields(item.id, {'favorite': target});
      final idx = widget.items.indexWhere((m) => m.id == item.id);
      if (idx >= 0) {
        widget.items[idx] = updated ?? item.copyWith(favorite: target ? 1 : 0);
      }
      if (mounted) {
        setState(() {});
        showToast(context, target ? '已收藏' : '已取消收藏', kind: ToastKind.success);
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, '操作失败: ${e.displayMessage}', kind: ToastKind.error);
    }
  }

  void _toggleDetails() {
    setState(() {
      _showDetails = !_showDetails;
      if (!_isImage && _player != null) {
        if (_showDetails) {
          _player!.pause();
          _videoPausedForDetails = true;
        } else if (_videoPausedForDetails) {
          _player!.play();
          _videoPausedForDetails = false;
        }
      }
    });
  }

  Future<void> _downloadCurrent([MediaItem? target]) async {
    final item = target ?? _item;
    try {
      final savePath = await DownloadService.instance
          .downloadSingle(widget.service, item.id, item.filename);
      if (!mounted) return;
      if (savePath == null) return; // 用户取消
      final name = savePath.split(Platform.pathSeparator).last;
      final viewLocal = widget.onViewLocal;
      showToast(
        context,
        isMobile ? '已保存到系统相册 iGallery' : '已下载 $name',
        kind: ToastKind.success,
        actionLabel: isMobile && viewLocal != null ? '查看' : null,
        onAction: isMobile && viewLocal != null ? viewLocal : null,
      );
    } on ApiException catch (e) {
      if (mounted) showToast(context, '下载失败: ${e.displayMessage}', kind: ToastKind.error);
    } catch (_) {
      if (mounted) showToast(context, '下载失败', kind: ToastKind.error);
    }
  }

  Future<void> _shareCurrent() async {
    final item = _item;
    try {
      var file = DiskCache.instance.cachedMediaSync(item.id);
      file ??= await DiskCache.instance.getMedia(
        item.id,
        widget.service.fullUrl(item.id),
        widget.service.authHeaders,
        isVideo: item.isVideo,
        knownSize: item.size,
      );
      if (file == null || !mounted) {
        if (mounted) showToast(context, '无法获取文件', kind: ToastKind.error);
        return;
      }
      final mime = item.isVideo ? 'video/*' : 'image/*';
      await Share.shareXFiles(
        [XFile(file.path, mimeType: mime)],
      );
    } catch (e) {
      if (mounted) showToast(context, '分享失败: $e', kind: ToastKind.error);
    }
  }

  Future<void> _rename() async {
    final c = context.colors;
    final result = await showDialog<String>(context: context, builder: (ctx) {
      final ctrl = TextEditingController(text: _item.filename);
      return AlertDialog(
        title: Text('重命名', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
        content: TextField(controller: ctrl, autofocus: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.md),
            decoration: InputDecoration(filled: true, fillColor: c.surface2,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.chip), borderSide: BorderSide.none))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: c.onSurfaceVariant))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text('确认', style: TextStyle(color: c.brand, fontWeight: FontWeight.w600))),
        ],
      );
    });
    if (result != null && result.isNotEmpty && result != _item.filename && mounted) {
      try {
        final updated = await widget.service.updateFields(_item.id, {'filename': result});
        final idx = widget.items.indexWhere((m) => m.id == _item.id);
        if (idx >= 0) {
          widget.items[idx] = updated ?? _item.copyWith(filename: result);
        }
        if (mounted) {
          setState(() {});
          showToast(context, '已重命名', kind: ToastKind.success);
        }
      } on ApiException catch (e) {
        if (mounted) showToast(context, '重命名失败: ${e.displayMessage}', kind: ToastKind.error);
      }
    }
  }

  // ── 格式化 ──
  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  String _fmtDate(String? s) => fmtDateTime(s);

  String _fmtDuration(double secs) => _fmtClock(Duration(seconds: secs.round()));

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mq = MediaQuery.of(context);
    final prefs = context.watch<DisplayPrefs>();
    final transition = prefs.viewerTransition;

    Widget viewer = _buildContent(c, mq);

    // mobile: system back gesture closes viewer (handled by PopScope above)
    // no custom edge swipe needed — PopScope + gallery_view handle it

    Widget content = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _close(); },
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            _close();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: viewer,
      ),
    );

    // 进入/退出动画
    switch (transition) {
      case ViewerTransition.fade:
        content = FadeTransition(opacity: _enterCtrl, child: content);
      case ViewerTransition.scale:
        content = ScaleTransition(scale: CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOutCubic), child: content);
      case ViewerTransition.none:
        break;
    }

    // 查看器是深色全屏，状态栏随之变深色（与主页亮色状态栏区分）
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.black,
        statusBarIconBrightness: Brightness.light,  // Android
        statusBarBrightness: Brightness.dark,       // iOS
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: content,
    );
  }

  Widget _buildContent(AppColors c, MediaQueryData mq) {
    return MouseRegion(
      onHover: (_) { if (!_showUI) setState(() => _showUI = true); },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 模糊背景 — 点击关闭
          GestureDetector(
            onTap: _close,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(color: Colors.black.withValues(alpha: 0.85)),
            ),
          ),

          // 图片/视频主体 — 占满全屏，详情浮在上面
          Positioned.fill(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: widget.items.length,
                onPageChanged: (i) {
                  setState(() {
                    _current = i;
                    _videoPausedForDetails = false;
                    _showDetails = widget.items[i].isImage;
                  });
                  _initVideo();
                },
                itemBuilder: (_, i) {
                  final item = widget.items[i];
                  if (item.isVideo && i == _current) {
                    if (_videoFailed) {
                      return GestureDetector(
                        onTap: () => setState(() => _showUI = !_showUI),
                        child: _VideoErrorView(onRetry: _retryVideo),
                      );
                    }
                    if (_videoCtrl != null && _player != null) {
                      return _VideoView(
                        // 按 item.id key 化：删除当前视频后 _initVideo 会换新 Player，
                        // key 变→整棵控件子树重建→各控件 State 重新订阅新 player。
                        // 否则控件仍订阅已 dispose 的旧 player，播放/进度/倍速全冻住、seek 到错位。
                        key: ValueKey(item.id),
                        player: _player!,
                        controller: _videoCtrl!,
                        visible: _showUI,
                        onVisibleChanged: (v) {
                          if (_showUI != v) setState(() => _showUI = v);
                        },
                      );
                    }
                  }
                  // 非当前页的视频：只放缩略图占位，绝不要把整个视频文件喂给 PhotoView/NetworkImage
                  // 当图片解码——那会把整条视频拉进内存（broken_image 闪烁 + 带宽/内存尖峰，
                  // 服务端日志里刷 "Invalid image data"）。成为当前页时 onPageChanged 再切真视频。
                  if (item.isVideo) {
                    return GestureDetector(
                      onTap: () => setState(() => _showUI = !_showUI),
                      child: ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Image.network(
                            widget.service.thumbUrl(item.id),
                            headers: widget.service.authHeaders,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.play_circle_outline,
                                color: Colors.white24, size: 64),
                          ),
                        ),
                      ),
                    );
                  }
                  // 非图片非视频（音频/其它文件）：没法预览，明说并给下载入口，
                  // 别让 PhotoView 去拉它然后只剩一个碎图标
                  if (!item.isImage && !item.isVideo) {
                    return GestureDetector(
                      onTap: () => setState(() => _showUI = !_showUI),
                      child: _UnsupportedView(
                        item: item,
                        onDownload: () => _downloadCurrent(item),
                      ),
                    );
                  }
                  return GestureDetector(
                    onTap: () => setState(() => _showUI = !_showUI),
                    onDoubleTap: () { _zoomPercent > 110 ? _resetZoom() : _zoomByPercent(50); },
                    child: PhotoView(
                      controller: i == _current ? _photoCtrl : null,
                      imageProvider: NetworkImage(
                        widget.service.fullUrl(item.id),
                        headers: widget.service.authHeaders,
                      ),
                      backgroundDecoration: const BoxDecoration(color: Colors.transparent),
                      minScale: PhotoViewComputedScale.contained * 0.5,
                      maxScale: PhotoViewComputedScale.covered * 5,
                      initialScale: PhotoViewComputedScale.contained,
                      loadingBuilder: (_, event) => Center(child: SizedBox(width: 22, height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: _kViewerAccent,
                              value: event == null ? null : event.cumulativeBytesLoaded / (event.expectedTotalBytes ?? 1)))),
                      errorBuilder: (_, __, ___) => const Center(
                          child: Icon(Icons.broken_image, color: Colors.white30, size: 48)),
                    ),
                  );
                },
              ),
            ),

          // 左右箭头
          if (_showUI && widget.items.length > 1) ...[
            if (_current > 0)
              Positioned(left: 12, top: 0, bottom: 0, child: Center(
                  child: _ArrowBtn(icon: Icons.chevron_left, onTap: () => _goTo(_current - 1)))),
            if (_current < widget.items.length - 1)
              Positioned(right: 12, top: 0, bottom: 0, child: Center(
                  child: _ArrowBtn(icon: Icons.chevron_right, onTap: () => _goTo(_current + 1)))),
          ],

          // 顶部栏
          if (_showUI)
            Positioned(top: 0, left: 0, right: 0, child: AnimatedOpacity(
              opacity: _showUI ? 1.0 : 0.0, duration: const Duration(milliseconds: 150),
              child: Container(
                decoration: const BoxDecoration(gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent])),
                padding: EdgeInsets.only(top: mq.padding.top + 4, left: 4, right: 4, bottom: 12),
                child: Row(children: [
                  _IcoBtn(Icons.close, onTap: _close, tooltip: '关闭'),
                  const SizedBox(width: 4),
                  if (widget.selecting) ...[
                    // 选择态：中间显示已选数量，右上角是选择圆圈（可切换当前项）
                    Expanded(child: Center(child: Text(
                      '已选 ${_selected.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 13,
                          fontWeight: FontWeight.w600)))),
                    const SizedBox(width: 4),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleSelectCurrent,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Container(
                          width: 26, height: 26,
                          decoration: BoxDecoration(
                            // 选中=蓝色（与网格/本地选择态一致）；深色底上用提亮的 _kViewerAccent
                            color: _isCurSelected
                                ? _kViewerAccent
                                : Colors.white.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _isCurSelected ? _kViewerAccent : Colors.white,
                              width: 2,
                            ),
                          ),
                          child: _isCurSelected
                              ? const Icon(Icons.check, size: 16, color: Colors.white)
                              : null,
                        ),
                      ),
                    ),
                  ] else ...[
                    Expanded(child: Text(_item.filename, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12))),
                    const SizedBox(width: 4),
                    if (_isImage)
                      GestureDetector(
                        onTap: _cycleZoom,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                          child: Text('$_zoomPercent%',
                              style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    _IcoBtn(
                      _item.isFavorite ? Icons.favorite : Icons.favorite_border,
                      onTap: _toggleFavorite,
                      color: _item.isFavorite ? _kViewerFav : null,
                      tooltip: _item.isFavorite ? '取消收藏' : '收藏'),
                    _IcoBtn(Icons.share, onTap: _shareCurrent, tooltip: '分享'),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, color: Colors.white70, size: 20),
                      color: Colors.grey[900],
                      onSelected: (v) {
                        switch (v) {
                          case 'download': _downloadCurrent();
                          case 'rename': _rename();
                          case 'details': _toggleDetails();
                          case 'delete': _delete();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'download', child: _MenuRow(Icons.file_download_outlined, '下载')),
                        const PopupMenuItem(value: 'rename', child: _MenuRow(Icons.edit_outlined, '重命名')),
                        PopupMenuItem(value: 'details', child: _MenuRow(
                          _showDetails ? Icons.info : Icons.info_outline,
                          _showDetails ? '隐藏详情' : '查看详情',
                        )),
                        const PopupMenuItem(value: 'delete', child: _MenuRow(Icons.delete_outline, '删除', danger: true)),
                      ],
                    ),
                  ],
                ]),
              ),
            )),

          // 底部详情（视频时暂停播放后显示）；选择态下隐藏，专注"边看边选"
          if (_showUI && _showDetails && !widget.selecting)
            Positioned(bottom: 0, left: 0, right: 0, child: AnimatedOpacity(
              opacity: 1.0, duration: const Duration(milliseconds: 150),
              child: Container(
                decoration: const BoxDecoration(gradient: LinearGradient(
                    begin: Alignment.bottomCenter, end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent])),
                padding: EdgeInsets.only(left: 16, right: 16, top: 24, bottom: mq.padding.bottom + 12),
                child: _buildDetails(c),
              ),
            )),

        ],
      ),
    );
  }

  Widget _buildDetails(AppColors c) {
    final item = _item;
    final rows = <(String, String)>[
      ('文件名', item.filename),
      ('类型', '${item.mediaType} · ${item.mime}'),
      ('大小', _fmtSize(item.size)),
      if (item.width != null && item.height != null) ('尺寸', '${item.width}×${item.height}'),
      if (item.duration != null) ('时长', _fmtDuration(item.duration!)),
      if (item.takenAt != null) ('拍摄时间', _fmtDate(item.takenAt)),
      ('上传时间', _fmtDate(item.createdAt)),
      if (item.exifMake != null || item.exifModel != null)
        ('相机', [item.exifMake, item.exifModel].whereType<String>().join(' ')),
      if (item.exifGpsLat != null && item.exifGpsLng != null)
        ('位置', '${item.exifGpsLat!.toStringAsFixed(4)}, ${item.exifGpsLng!.toStringAsFixed(4)}'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (label, value) in rows)
          Padding(padding: const EdgeInsets.only(bottom: 5), child: Row(children: [
            SizedBox(width: 60, child: Text(label, style: const TextStyle(color: Colors.white30, fontSize: 11))),
            Expanded(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 12))),
          ])),
      ],
    );
  }
}

// ── 小按钮 ──

class _IcoBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final String? tooltip;
  const _IcoBtn(this.icon, {required this.onTap, this.color, this.tooltip});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: color ?? Colors.white70, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;
  const _MenuRow(this.icon, this.label, {this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? _kViewerDanger : Colors.white70;
    return Row(children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(color: color, fontSize: 13)),
    ]);
  }
}

// ── 左右箭头 ──

class _ArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: Container(
      width: 36, height: 36,
      decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
      child: Icon(icon, color: Colors.white70, size: 24),
    ));
  }
}

/// 视频加载失败。旧行为是一片黑屏 + 缓冲转圈永不停，用户不知道发生了什么。
/// 这里明确说明并给重试入口。
class _VideoErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  const _VideoErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white30, size: 48),
          const SizedBox(height: 12),
          const Text('视频加载失败',
              style: TextStyle(color: Colors.white70, fontSize: AppType.sm)),
          const SizedBox(height: 4),
          const Text('检查网络或服务器后重试',
              style: TextStyle(color: Colors.white30, fontSize: AppType.xs)),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: _kViewerAccent,
              side: const BorderSide(color: _kViewerAccent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill)),
            ),
            child: const Text('重试',
                style: TextStyle(fontSize: AppType.sm, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// 非图片非视频的文件（音频、文档等）没法预览。
/// 明确告诉用户并给下载入口，而不是让图片组件去拉然后显示碎图标。
class _UnsupportedView extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onDownload;
  const _UnsupportedView({required this.item, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, color: Colors.white30, size: 48),
          const SizedBox(height: 12),
          Text(item.filename,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: AppType.sm)),
          const SizedBox(height: 4),
          const Text('该类型不支持预览',
              style: TextStyle(color: Colors.white30, fontSize: AppType.xs)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: const Text('下载',
                style: TextStyle(fontSize: AppType.sm, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kViewerAccent,
              side: const BorderSide(color: _kViewerAccent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 视频（media_kit 播放内核 + 自绘控件）──
//
// 不用 media_kit_video 自带的 MaterialVideoControls / MaterialDesktopVideoControls：
// 那是两份互不相干的实现，theme 字段名都不一致（移动端 seekBarPositionColor、
// 桌面端也叫 seekBarPositionColor 但归属不同的 ThemeData 类），四端行为无法统一。
// 移动端那份还在进度条外面套了一层 GestureDetector 且 onHorizontalDragUpdate 是空回调，
// 嵌在 PageView 里拖动会被手势竞技场吃掉。
// 这里只用 Player（解码/seek）+ Video（渲染），控件全部自绘，两端共用一份。

class _VideoView extends StatelessWidget {
  final Player player;
  final VideoController controller;
  final bool visible;
  final ValueChanged<bool> onVisibleChanged;
  const _VideoView({
    super.key,
    required this.player,
    required this.controller,
    required this.visible,
    required this.onVisibleChanged,
  });

  @override
  Widget build(BuildContext context) {
    // controls 走 Video 的 builder 而不是外面套 Stack：builder 里的 context 位于
    // VideoStateInheritedWidget 之下，toggleFullscreen(context) 才能用；且库进入
    // 全屏时复用同一个 builder，全屏页面自动拿到同一套控件，不用写第二份。
    return Video(
      controller: controller,
      controls: (_) => _VideoControls(
        player: player,
        visible: visible,
        onVisibleChanged: onVisibleChanged,
      ),
    );
  }
}

/// 底部控件条：进度条在上，按钮行在下（与桌面一致）。
/// 显隐状态由 MediaViewer 的 _showUI 单点持有，顶栏和这里永远同步。
class _VideoControls extends StatefulWidget {
  final Player player;
  final bool visible;
  final ValueChanged<bool> onVisibleChanged;
  const _VideoControls({
    required this.player,
    required this.visible,
    required this.onVisibleChanged,
  });

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  static const _autoHideDelay = Duration(seconds: 3);

  Timer? _hideTimer;
  StreamSubscription<bool>? _playingSub;
  late bool _playing = widget.player.state.playing;

  @override
  void initState() {
    super.initState();
    // 恢复上次音量
    KvStore.instance.get('video_volume').then((s) {
      if (s != null && mounted) {
        final v = double.tryParse(s);
        if (v != null) widget.player.setVolume(v);
      }
    });
    _playingSub = widget.player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
      _restartHideTimer();
    });
    _restartHideTimer();
  }

  @override
  void didUpdateWidget(_VideoControls old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playingSub?.cancel();
    super.dispose();
  }

  /// 只在播放中自动隐藏。暂停时控件常驻 —— 暂停往往就是为了操作。
  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (!widget.visible || !_playing) return;
    _hideTimer = Timer(_autoHideDelay, () {
      if (mounted && widget.visible) widget.onVisibleChanged(false);
    });
  }

  void _keepAlive() => _restartHideTimer();

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 轻点画面切换控件显隐。tap 不与 PageView 的水平拖动冲突，左右滑切换视频不受影响。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onVisibleChanged(!widget.visible),
          child: const SizedBox.expand(),
        ),
        // 缓冲转圈不跟随 visible：控件隐藏时也得看得到“在加载”，否则局域网拉大视频会像卡死。
        IgnorePointer(child: _BufferingIndicator(player: widget.player)),
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: IgnorePointer(
            ignoring: !widget.visible,
            child: AnimatedOpacity(
              opacity: widget.visible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              // 控件条自己吸收 tap，否则点到 Spacer 空白会穿透到下层把控件关掉。
              child: GestureDetector(
                onTap: _keepAlive,
                child: Container(
                  decoration: const BoxDecoration(gradient: LinearGradient(
                      begin: Alignment.bottomCenter, end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent])),
                  padding: EdgeInsets.only(
                    left: AppSpace.md, right: AppSpace.md,
                    top: AppSpace.xl, bottom: bottomInset + AppSpace.sm,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _VideoSeekBar(player: widget.player, onInteract: _keepAlive),
                      SizedBox(
                        height: 44,
                        child: Row(children: [
                          _PlayPauseButton(player: widget.player, onInteract: _keepAlive),
                          const SizedBox(width: AppSpace.xs),
                          _PositionText(player: widget.player),
                          const Spacer(),
                          _VolumeButton(player: widget.player, onInteract: _keepAlive),
                          _SpeedButton(player: widget.player, onInteract: _keepAlive),
                          const SizedBox(width: AppSpace.xs),
                          const _FullscreenButton(),
                        ]),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── 拖动条 ──

/// 横向拖动条。进度条和音量条共用 —— 两者的手势与视觉完全同构，
/// 差别只在有没有缓冲层。本身不持有值，值由父级给。
///
/// 手势用 RawGestureDetector 显式注册 tap + horizontal drag。
/// 查看器嵌在 PageView 里，水平拖动必须由这里赢下竞技场，否则会被翻页抢走；
/// 同时注册 tap 才能支持"点一下跳到该处"。（参见 AGENTS.md §3.1.1）
class _DragBar extends StatelessWidget {
  static const _touchHeight = 28.0;

  final double percent;        // 0-1
  final double bufferPercent;  // 0 = 不画缓冲层
  final bool active;           // 拖动中：轨道变粗 + thumb 放大
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  const _DragBar({
    required this.percent,
    required this.active,
    required this.onChanged,
    required this.onEnd,
    this.bufferPercent = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth;
      final track = active ? 5.0 : 3.0;
      final thumb = active ? 16.0 : 12.0;
      // 音量条收起时宽度动画会走到 0，除零要挡掉。
      void emit(double dx) {
        if (w <= 0) return;
        onChanged((dx / w).clamp(0.0, 1.0));
      }
      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(),
            (r) {
              r.onTapDown = (d) => emit(d.localPosition.dx);
              r.onTapUp = (_) => onEnd();
              r.onTapCancel = onEnd;
            },
          ),
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(),
            (r) {
              r.onDown = (d) => emit(d.localPosition.dx);
              r.onUpdate = (d) => emit(d.localPosition.dx);
              r.onEnd = (_) => onEnd();
              r.onCancel = onEnd;
            },
          ),
        },
        child: SizedBox(
          height: _touchHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _bar(w, track, Colors.white24),
              if (bufferPercent > 0) _bar(w * bufferPercent, track, Colors.white38),
              _bar(w * percent, track, _kViewerAccent),
              Positioned(
                left: (w - thumb) * percent,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: thumb, height: thumb,
                  decoration: const BoxDecoration(
                    color: _kViewerAccent, shape: BoxShape.circle),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _bar(double width, double height, Color color) => Positioned(
    left: 0,
    child: Container(
      width: width, height: height,
      decoration: BoxDecoration(
        color: color, borderRadius: BorderRadius.circular(AppRadius.pill)),
    ),
  );
}

// ── 进度条 ──

class _VideoSeekBar extends StatefulWidget {
  final Player player;
  final VoidCallback onInteract;
  const _VideoSeekBar({required this.player, required this.onInteract});

  @override
  State<_VideoSeekBar> createState() => _VideoSeekBarState();
}

class _VideoSeekBarState extends State<_VideoSeekBar> {
  final _subs = <StreamSubscription>[];
  late Duration _position = widget.player.state.position;
  late Duration _duration = widget.player.state.duration;
  late Duration _buffer = widget.player.state.buffer;

  bool _dragging = false;
  double _dragPercent = 0.0;

  @override
  void initState() {
    super.initState();
    final p = widget.player;
    _subs.addAll([
      // 拖动中忽略播放位置推送，否则 thumb 会在手指和真实位置之间来回跳。
      p.stream.position.listen((v) { if (!_dragging) setState(() => _position = v); }),
      p.stream.duration.listen((v) => setState(() => _duration = v)),
      p.stream.buffer.listen((v) => setState(() => _buffer = v)),
      p.stream.completed.listen((_) { if (!_dragging) setState(() => _position = Duration.zero); }),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    super.dispose();
  }

  @override
  void setState(VoidCallback fn) {
    if (mounted) super.setState(fn);
  }

  double get _percent {
    if (_dragging) return _dragPercent;
    if (_duration.inMilliseconds <= 0) return 0.0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  double get _bufferPercent {
    if (_duration.inMilliseconds <= 0) return 0.0;
    return (_buffer.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  void _preview(double p) {
    widget.onInteract();
    setState(() {
      _dragging = true;
      _dragPercent = p;
    });
  }

  void _commit() {
    if (!_dragging) return;
    final target = _duration * _dragPercent;
    setState(() {
      _dragging = false;
      _position = target; // 先落位，避免松手瞬间弹回旧位置
    });
    widget.player.seek(target);
    widget.onInteract();
  }

  @override
  Widget build(BuildContext context) {
    return _DragBar(
      percent: _percent,
      bufferPercent: _bufferPercent,
      active: _dragging,
      onChanged: _preview,
      onEnd: _commit,
    );
  }
}

// ── 控件按钮 ──
//
// 每个按钮自己订阅自己关心的 stream。父级 setState 不重建它们，
// 也避免播放位置每秒推送时整条控件条跟着重建。

/// 深色空间里的统一按钮壳。44×44 满足移动端可点击目标 ≥ 40×40。
class _CtrlBtn extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;
  const _CtrlBtn({required this.child, required this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final btn = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(width: 44, height: 44, child: Center(child: child)),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

class _PlayPauseButton extends StatefulWidget {
  final Player player;
  final VoidCallback onInteract;
  const _PlayPauseButton({required this.player, required this.onInteract});

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> {
  StreamSubscription<bool>? _sub;
  late bool _playing = widget.player.state.playing;

  @override
  void initState() {
    super.initState();
    _sub = widget.player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _CtrlBtn(
      tooltip: _playing ? '暂停' : '播放',
      onTap: () {
        widget.player.playOrPause();
        widget.onInteract();
      },
      child: Icon(_playing ? Icons.pause : Icons.play_arrow,
          color: Colors.white, size: AppIconSize.xl),
    );
  }
}

class _PositionText extends StatefulWidget {
  final Player player;
  const _PositionText({required this.player});

  @override
  State<_PositionText> createState() => _PositionTextState();
}

class _PositionTextState extends State<_PositionText> {
  final _subs = <StreamSubscription>[];
  late Duration _position = widget.player.state.position;
  late Duration _duration = widget.player.state.duration;

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      widget.player.stream.position.listen((v) {
        if (mounted) setState(() => _position = v);
      }),
      widget.player.stream.duration.listen((v) {
        if (mounted) setState(() => _duration = v);
      }),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '${_fmtClock(_position)} / ${_fmtClock(_duration)}',
      style: const TextStyle(
        color: Colors.white70, fontSize: AppType.xs, fontWeight: FontWeight.w500,
        fontFeatures: [ui.FontFeature.tabularFigures()], // 数字等宽，秒数跳动时不抖
      ),
    );
  }
}

class _SpeedButton extends StatefulWidget {
  final Player player;
  final VoidCallback onInteract;
  const _SpeedButton({required this.player, required this.onInteract});

  @override
  State<_SpeedButton> createState() => _SpeedButtonState();
}

class _SpeedButtonState extends State<_SpeedButton> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  late double _speed = widget.player.state.rate;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.player.stream.rate.listen((rate) {
      if (mounted && rate != _speed) setState(() => _speed = rate);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _cycle() {
    // 找到最接近当前速率的档位，再取下一档（浮点比较不能用 indexOf）
    var idx = 0;
    var best = double.infinity;
    for (var i = 0; i < _speeds.length; i++) {
      final d = (_speeds[i] - _speed).abs();
      if (d < best) { best = d; idx = i; }
    }
    widget.player.setRate(_speeds[(idx + 1) % _speeds.length]);
    widget.onInteract();
  }

  String get _label {
    final s = _speed;
    final text = s == s.roundToDouble() ? s.toStringAsFixed(0) : '$s';
    return '${text}x';
  }

  @override
  Widget build(BuildContext context) {
    final isNormal = (_speed - 1.0).abs() < 0.01;
    return _CtrlBtn(
      tooltip: '播放速度',
      onTap: _cycle,
      child: Text(_label, style: TextStyle(
        color: isNormal ? Colors.white70 : _kViewerAccent,
        fontSize: AppType.xs, fontWeight: FontWeight.w600,
      )),
    );
  }
}

class _FullscreenButton extends StatelessWidget {
  const _FullscreenButton();

  @override
  Widget build(BuildContext context) {
    final full = isFullscreen(context);
    return _CtrlBtn(
      tooltip: full ? '退出全屏' : '全屏',
      onTap: () => toggleFullscreen(context),
      child: Icon(full ? Icons.fullscreen_exit : Icons.fullscreen,
          color: Colors.white70, size: AppIconSize.xl),
    );
  }
}

/// 音量：点图标展开/收起滑条，拖到底就是静音。
/// 不做“hover 展开” —— 那是桌面特例，手机没有 hover，两端行为就不一致了。
/// 滑条靠展开而不是常驻：长视频的时间文字能到 "1:23:45 / 2:00:00"，
/// 小屏上常驻滑条会把整行挤溢出。
class _VolumeButton extends StatefulWidget {
  final Player player;
  final VoidCallback onInteract;
  const _VolumeButton({required this.player, required this.onInteract});

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  static const _barWidth = 64.0;

  StreamSubscription<double>? _sub;
  late double _volume = widget.player.state.volume;
  bool _expanded = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.player.stream.volume.listen((v) {
      if (mounted && !_dragging) setState(() => _volume = v);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  IconData get _icon {
    if (_volume <= 0) return Icons.volume_off;
    if (_volume < 50) return Icons.volume_down;
    return Icons.volume_up;
  }

  void _set(double percent) {
    widget.onInteract();
    final v = (percent * 100).clamp(0.0, 100.0);
    setState(() {
      _dragging = true;
      _volume = v;
    });
    widget.player.setVolume(v);
    KvStore.instance.set('video_volume', v.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      _CtrlBtn(
        tooltip: '音量',
        onTap: () {
          widget.onInteract();
          setState(() => _expanded = !_expanded);
        },
        child: Icon(_icon, color: Colors.white70, size: AppIconSize.xl),
      ),
      // 收起时宽度动画到 0，thumb 会超出边界，靠 ClipRect 裁掉。
      ClipRect(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: _expanded ? _barWidth : 0,
          child: _DragBar(
            percent: (_volume / 100).clamp(0.0, 1.0),
            active: _dragging,
            onChanged: _set,
            onEnd: () => setState(() => _dragging = false),
          ),
        ),
      ),
    ]);
  }
}

/// 缓冲转圈。尺寸与图片加载时的一致。
class _BufferingIndicator extends StatefulWidget {
  final Player player;
  const _BufferingIndicator({required this.player});

  @override
  State<_BufferingIndicator> createState() => _BufferingIndicatorState();
}

class _BufferingIndicatorState extends State<_BufferingIndicator> {
  StreamSubscription<bool>? _sub;
  late bool _buffering = widget.player.state.buffering;

  @override
  void initState() {
    super.initState();
    _sub = widget.player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_buffering) return const SizedBox.shrink();
    return const Center(
      child: SizedBox(
        width: 22, height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: _kViewerAccent),
      ),
    );
  }
}
