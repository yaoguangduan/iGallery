import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_view/photo_view.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as image_lib;

import '../../core/api.dart';
import '../../core/disk_cache.dart';
import '../../core/display_prefs.dart';
import '../../core/download_service.dart';
import '../../core/media_service.dart';
import '../../core/platform.dart';
import '../../core/time_fmt.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';
import 'cached_thumb.dart';

bool get _isDesktop => isDesktop;

/// 查看器是"永远深色"的独立空间（YouTube 播放器同理）。
/// 黑底上主题的 brand(#065FD4) 对比度不足，这里用提亮版本。
const Color _kViewerAccent = Color(0xFF5B9DFF);
const Color _kViewerDanger = Color(0xFFFF6B6B);
const Color _kViewerStar = Color(0xFFFFC107);

class MediaViewer extends StatefulWidget {
  final List<MediaItem> items;
  final int initialIndex;
  final MediaService service;
  final void Function(String id)? onDeleted;
  final VoidCallback onClose;

  const MediaViewer({super.key, required this.items, required this.initialIndex,
    required this.service, required this.onClose, this.onDeleted});

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> with TickerProviderStateMixin {
  late final PageController _pageCtrl;
  late final AnimationController _enterCtrl;
  late int _current;
  Player? _player;
  VideoController? _videoCtrl;

  bool _showUI = true;
  late bool _showDetails;
  bool _videoPausedForDetails = false;
  bool _cropMode = false;
  bool _renaming = false;

  PhotoViewController? _photoCtrl;
  double _scale = 1.0;
  double _baseScale = 1.0; // contained scale (fit-to-view)

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _showDetails = widget.items[_current].isImage;
    _pageCtrl = PageController(initialPage: _current);
    _enterCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _enterCtrl.forward();
    _resetPhotoCtrl();
    _initVideo();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _enterCtrl.dispose();
    _player?.dispose();
    _photoCtrl?.dispose();
    super.dispose();
  }

  MediaItem get _item => widget.items[_current];
  bool get _isImage => _item.isImage;

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
    _resetPhotoCtrl();
    if (_item.isVideo) {
      _player = Player();
      _videoCtrl = VideoController(_player!);
      _openVideo(_item);
    }
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
  void _zoomIn() => _zoomByPercent(10);
  void _zoomOut() => _zoomByPercent(-10);
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
    await widget.service.delete(id);
    widget.onDeleted?.call(id);
    if (widget.items.length <= 1) { _close(); return; }
    setState(() {
      widget.items.removeWhere((m) => m.id == id);
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
      if (mounted) setState(() {});
    } on ApiException catch (e) {
      if (mounted) showToast(context, '操作失败: ${e.userMessage}', kind: ToastKind.error);
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

  Future<void> _downloadCurrent() async {
    final item = _item;
    try {
      final savePath = await DownloadService.instance
          .downloadSingle(widget.service, item.id, item.filename);
      if (!mounted) return;
      if (savePath == null) return; // 用户取消
      final name = savePath.split(Platform.pathSeparator).last;
      showToast(context, '已下载 $name', kind: ToastKind.success);
    } on ApiException catch (e) {
      if (mounted) showToast(context, '下载失败: ${e.userMessage}', kind: ToastKind.error);
    } catch (_) {
      if (mounted) showToast(context, '下载失败', kind: ToastKind.error);
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
        if (mounted) setState(() {});
      } on ApiException catch (e) {
        if (mounted) showToast(context, '重命名失败: ${e.userMessage}', kind: ToastKind.error);
      }
    }
  }

  // ── 裁剪执行 ──
  Future<void> _executeCrop(Rect cropRect, Size imageDispSize) async {
    final prefs = context.read<DisplayPrefs>();
    final item = _item;

    // 决定保存模式
    CropSaveMode mode = prefs.cropSaveMode;
    if (mode == CropSaveMode.ask) {
      final c = context.colors;
      final chosen = await showDialog<CropSaveMode>(context: context, builder: (ctx) => AlertDialog(
        title: Text('保存裁剪', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
        content: Text('选择保存方式', style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.md)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: c.onSurfaceVariant))),
          TextButton(onPressed: () => Navigator.pop(ctx, CropSaveMode.overwrite),
              child: Text('覆盖原图', style: TextStyle(color: c.warn, fontWeight: FontWeight.w600))),
          TextButton(onPressed: () => Navigator.pop(ctx, CropSaveMode.saveAsNew),
              child: Text('另存为', style: TextStyle(color: c.brand, fontWeight: FontWeight.w600))),
        ],
      ));
      if (chosen == null) { setState(() => _cropMode = false); return; }
      mode = chosen;
    }

    setState(() => _cropMode = false);

    // 下载原图
    final bytes = await widget.service.downloadBytes(item.id);

    // 解码 → 裁剪 → 编码（在 isolate 里跑避免卡 UI）
    final cropped = await compute(_cropImage, _CropParams(
      bytes: bytes,
      cropLeft: cropRect.left / imageDispSize.width,
      cropTop: cropRect.top / imageDispSize.height,
      cropWidth: cropRect.width / imageDispSize.width,
      cropHeight: cropRect.height / imageDispSize.height,
    ));

    if (cropped == null || !mounted) return;

    // 时间
    final takenAt = prefs.cropTimeMode == CropTimeMode.keepOriginal
        ? item.takenAt
        : DateTime.now().toIso8601String();

    // 文件名
    final ext = item.ext.isEmpty ? 'jpg' : item.ext;
    final newFilename = mode == CropSaveMode.overwrite
        ? item.filename
        : '${item.filename.replaceAll(RegExp(r'\.[^.]+$'), '')}_cropped.$ext';

    // 上传裁剪后的图片
    final result = await widget.service.uploadBytes(
      bytes: cropped, filename: newFilename, takenAt: takenAt, folderId: item.folderId);

    if (result == null || !mounted) return;
    final newItem = result.item;

    if (mode == CropSaveMode.overwrite) {
      // 删除原图
      await widget.service.delete(item.id);
      widget.onDeleted?.call(item.id);
      // 替换列表中的项
      final idx = widget.items.indexWhere((m) => m.id == item.id);
      if (idx >= 0) {
        widget.items[idx] = newItem;
      } else {
        widget.items.add(newItem);
      }
    } else {
      // 另存为：加到列表开头
      widget.items.insert(_current + 1, newItem);
    }

    setState(() {});
  }

  // ── 格式化 ──
  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  String _fmtDate(String? s) => fmtDateTime(s);

  String _fmtDuration(double secs) {
    final d = Duration(seconds: secs.round());
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mq = MediaQuery.of(context);
    final prefs = context.watch<DisplayPrefs>();
    final transition = prefs.viewerTransition;

    Widget viewer = _buildContent(c, mq);

    // mobile: edge swipe to close
    if (!_isDesktop) {
      viewer = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 300) _close();
        },
        child: viewer,
      );
    }

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
          if (_cropMode && _isImage)
            _CropView(
              imageUrl: widget.service.fullUrl(_item.id),
              headers: widget.service.authHeaders,
              onCancel: () => setState(() => _cropMode = false),
              onCrop: (cropRect, dispSize) => _executeCrop(cropRect, dispSize),
            )
          else
            Positioned.fill(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: widget.items.length,
                onPageChanged: (i) {
                  setState(() {
                    _current = i; _cropMode = false;
                    _videoPausedForDetails = false;
                    _showDetails = widget.items[i].isImage;
                  });
                  _initVideo();
                },
                itemBuilder: (_, i) {
                  final item = widget.items[i];
                  if (item.isVideo && i == _current && _videoCtrl != null && _player != null) {
                    return _VideoView(
                      player: _player!,
                      controller: _videoCtrl!,
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
          if (_showUI && widget.items.length > 1 && !_cropMode) ...[
            if (_current > 0)
              Positioned(left: 12, top: 0, bottom: 0, child: Center(
                  child: _ArrowBtn(icon: Icons.chevron_left, onTap: () => _goTo(_current - 1)))),
            if (_current < widget.items.length - 1)
              Positioned(right: 12, top: 0, bottom: 0, child: Center(
                  child: _ArrowBtn(icon: Icons.chevron_right, onTap: () => _goTo(_current + 1)))),
          ],

          // 顶部栏
          if (_showUI && !_cropMode)
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
                  Expanded(child: Text(_item.filename, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12))),
                  const SizedBox(width: 4),
                  if (_isImage) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                      child: Text('$_zoomPercent%',
                          style: const TextStyle(color: Colors.white60, fontSize: 11, fontWeight: FontWeight.w500)),
                    ),
                    _IcoBtn(Icons.remove, onTap: _zoomOut, tooltip: '缩小'),
                    _IcoBtn(Icons.add, onTap: _zoomIn, tooltip: '放大'),
                    _IcoBtn(Icons.crop, onTap: () => setState(() => _cropMode = true), tooltip: '裁剪'),
                  ],
                  _IcoBtn(
                    _item.isFavorite ? Icons.star : Icons.star_border,
                    onTap: _toggleFavorite,
                    color: _item.isFavorite ? _kViewerStar : null,
                    tooltip: _item.isFavorite ? '取消收藏' : '收藏'),
                  _IcoBtn(Icons.file_download_outlined, onTap: _downloadCurrent, tooltip: '下载'),
                  _IcoBtn(Icons.edit_outlined, onTap: _rename, tooltip: '重命名'),
                  _IcoBtn(_showDetails ? Icons.info : Icons.info_outline,
                      onTap: _toggleDetails,
                      color: _showDetails ? _kViewerAccent : null, tooltip: '详情'),
                  _IcoBtn(Icons.delete_outline, onTap: _delete, color: _kViewerDanger, tooltip: '删除'),
                ]),
              ),
            )),

          // 底部详情（视频时暂停播放后显示）
          if (_showUI && _showDetails && !_cropMode)
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

// ── 裁剪（四角+四边拖拽）──

class _CropView extends StatefulWidget {
  final String imageUrl;
  final Map<String, String> headers;
  final VoidCallback onCancel;
  final void Function(Rect cropRect, Size displaySize) onCrop;
  const _CropView({
    required this.imageUrl,
    this.headers = const {},
    required this.onCancel,
    required this.onCrop,
  });

  @override
  State<_CropView> createState() => _CropViewState();
}

enum _DragHandle { topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right, body }

class _CropViewState extends State<_CropView> {
  Rect _crop = Rect.zero;
  Size _dispSize = Size.zero;
  Offset _dispOffset = Offset.zero;
  double _scale = 1.0;
  bool _ready = false;
  _DragHandle? _activeHandle;

  @override
  void initState() {
    super.initState();
    final provider = NetworkImage(widget.imageUrl, headers: widget.headers);
    provider.resolve(const ImageConfiguration()).addListener(ImageStreamListener((info, _) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _layout(
          Size(info.image.width.toDouble(), info.image.height.toDouble())));
    }));
  }

  void _layout(Size imgSize) {
    final box = context.size;
    if (box == null) return;
    final availH = box.height - 60;
    final sx = box.width / imgSize.width;
    final sy = availH / imgSize.height;
    _scale = math.min(sx, sy);
    final dw = imgSize.width * _scale;
    final dh = imgSize.height * _scale;
    _dispSize = Size(dw, dh);
    _dispOffset = Offset((box.width - dw) / 2, (availH - dh) / 2);
    _crop = Rect.fromLTWH(dw * 0.1, dh * 0.1, dw * 0.8, dh * 0.8);
    setState(() => _ready = true);
  }

  _DragHandle? _hitTest(Offset pos) {
    const r = 18.0;
    if ((pos - _crop.topLeft).distance < r) return _DragHandle.topLeft;
    if ((pos - _crop.topRight).distance < r) return _DragHandle.topRight;
    if ((pos - _crop.bottomLeft).distance < r) return _DragHandle.bottomLeft;
    if ((pos - _crop.bottomRight).distance < r) return _DragHandle.bottomRight;
    if ((pos.dy - _crop.top).abs() < r && pos.dx > _crop.left && pos.dx < _crop.right) return _DragHandle.top;
    if ((pos.dy - _crop.bottom).abs() < r && pos.dx > _crop.left && pos.dx < _crop.right) return _DragHandle.bottom;
    if ((pos.dx - _crop.left).abs() < r && pos.dy > _crop.top && pos.dy < _crop.bottom) return _DragHandle.left;
    if ((pos.dx - _crop.right).abs() < r && pos.dy > _crop.top && pos.dy < _crop.bottom) return _DragHandle.right;
    if (_crop.contains(pos)) return _DragHandle.body;
    return null;
  }

  void _onDragUpdate(DragUpdateDetails d, Offset localBase) {
    if (_activeHandle == null) return;
    final dx = d.delta.dx;
    final dy = d.delta.dy;
    setState(() {
      switch (_activeHandle!) {
        case _DragHandle.topLeft:
          _crop = Rect.fromLTRB((_crop.left + dx).clamp(0, _crop.right - 30), (_crop.top + dy).clamp(0, _crop.bottom - 30), _crop.right, _crop.bottom);
        case _DragHandle.topRight:
          _crop = Rect.fromLTRB(_crop.left, (_crop.top + dy).clamp(0, _crop.bottom - 30), (_crop.right + dx).clamp(_crop.left + 30, _dispSize.width), _crop.bottom);
        case _DragHandle.bottomLeft:
          _crop = Rect.fromLTRB((_crop.left + dx).clamp(0, _crop.right - 30), _crop.top, _crop.right, (_crop.bottom + dy).clamp(_crop.top + 30, _dispSize.height));
        case _DragHandle.bottomRight:
          _crop = Rect.fromLTRB(_crop.left, _crop.top, (_crop.right + dx).clamp(_crop.left + 30, _dispSize.width), (_crop.bottom + dy).clamp(_crop.top + 30, _dispSize.height));
        case _DragHandle.top:
          _crop = Rect.fromLTRB(_crop.left, (_crop.top + dy).clamp(0, _crop.bottom - 30), _crop.right, _crop.bottom);
        case _DragHandle.bottom:
          _crop = Rect.fromLTRB(_crop.left, _crop.top, _crop.right, (_crop.bottom + dy).clamp(_crop.top + 30, _dispSize.height));
        case _DragHandle.left:
          _crop = Rect.fromLTRB((_crop.left + dx).clamp(0, _crop.right - 30), _crop.top, _crop.right, _crop.bottom);
        case _DragHandle.right:
          _crop = Rect.fromLTRB(_crop.left, _crop.top, (_crop.right + dx).clamp(_crop.left + 30, _dispSize.width), _crop.bottom);
        case _DragHandle.body:
          var moved = _crop.translate(dx, dy);
          if (moved.left < 0) moved = moved.translate(-moved.left, 0);
          if (moved.top < 0) moved = moved.translate(0, -moved.top);
          if (moved.right > _dispSize.width) moved = moved.translate(_dispSize.width - moved.right, 0);
          if (moved.bottom > _dispSize.height) moved = moved.translate(0, _dispSize.height - moved.bottom);
          _crop = moved;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Center(child: AppSpinner());

    return Column(children: [
      Expanded(child: Stack(children: [
        Positioned(left: _dispOffset.dx, top: _dispOffset.dy, width: _dispSize.width, height: _dispSize.height,
            child: Image.network(widget.imageUrl, fit: BoxFit.contain, headers: widget.headers)),
        Positioned(left: _dispOffset.dx, top: _dispOffset.dy, width: _dispSize.width, height: _dispSize.height,
          child: GestureDetector(
            onPanStart: (d) => _activeHandle = _hitTest(d.localPosition),
            onPanUpdate: (d) => _onDragUpdate(d, _dispOffset),
            onPanEnd: (_) => _activeHandle = null,
            child: CustomPaint(size: _dispSize, painter: _CropPainter(cropRect: _crop)),
          ),
        ),
      ])),
      Container(color: Colors.black, padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 8, top: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          TextButton(onPressed: widget.onCancel, child: const Text('取消', style: TextStyle(color: Colors.white70, fontSize: 14))),
          TextButton(onPressed: () => widget.onCrop(_crop, _dispSize), child: const Text('裁剪', style: TextStyle(color: _kViewerAccent, fontSize: 14, fontWeight: FontWeight.w600))),
        ])),
    ]);
  }
}

class _CropPainter extends CustomPainter {
  final Rect cropRect;
  _CropPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final mask = Paint()..color = Colors.black54;
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, cropRect.top), mask);
    canvas.drawRect(Rect.fromLTRB(0, cropRect.bottom, size.width, size.height), mask);
    canvas.drawRect(Rect.fromLTRB(0, cropRect.top, cropRect.left, cropRect.bottom), mask);
    canvas.drawRect(Rect.fromLTRB(cropRect.right, cropRect.top, size.width, cropRect.bottom), mask);

    final border = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5;
    canvas.drawRect(cropRect, border);

    // 三分线
    final grid = Paint()..color = Colors.white24..style = PaintingStyle.stroke..strokeWidth = 0.5;
    final w3 = cropRect.width / 3;
    final h3 = cropRect.height / 3;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(cropRect.left + w3 * i, cropRect.top), Offset(cropRect.left + w3 * i, cropRect.bottom), grid);
      canvas.drawLine(Offset(cropRect.left, cropRect.top + h3 * i), Offset(cropRect.right, cropRect.top + h3 * i), grid);
    }

    // 四角手柄
    final handle = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3;
    const len = 16.0;
    for (final corner in [cropRect.topLeft, cropRect.topRight, cropRect.bottomLeft, cropRect.bottomRight]) {
      final sx = corner.dx == cropRect.left ? 1.0 : -1.0;
      final sy = corner.dy == cropRect.top ? 1.0 : -1.0;
      canvas.drawLine(corner, corner + Offset(len * sx, 0), handle);
      canvas.drawLine(corner, corner + Offset(0, len * sy), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => cropRect != old.cropRect;
}

// ── 裁剪 isolate ──

class _CropParams {
  final Uint8List bytes;
  final double cropLeft, cropTop, cropWidth, cropHeight;
  _CropParams({required this.bytes, required this.cropLeft, required this.cropTop,
    required this.cropWidth, required this.cropHeight});
}

Uint8List? _cropImage(_CropParams p) {
  try {
    final image = image_lib.decodeImage(p.bytes);
    if (image == null) return null;
    final x = (p.cropLeft * image.width).round().clamp(0, image.width - 1);
    final y = (p.cropTop * image.height).round().clamp(0, image.height - 1);
    final w = (p.cropWidth * image.width).round().clamp(1, image.width - x);
    final h = (p.cropHeight * image.height).round().clamp(1, image.height - y);
    final cropped = image_lib.copyCrop(image, x: x, y: y, width: w, height: h);
    return Uint8List.fromList(image_lib.encodeJpg(cropped, quality: 95));
  } catch (_) {
    return null;
  }
}

// ── 视频（media_kit 全平台播放器）──

class _VideoView extends StatefulWidget {
  final Player player;
  final VideoController controller;
  const _VideoView({super.key, required this.player, required this.controller});

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  double _speed = 1.0;

  void _cycleSpeed() {
    final idx = _speeds.indexOf(_speed);
    final next = _speeds[(idx + 1) % _speeds.length];
    widget.player.setRate(next);
    setState(() => _speed = next);
  }

  Widget _speedButton({Color color = Colors.white}) {
    final label = _speed == 1.0 ? '1x' : '${_speed}x';
    return MaterialCustomButton(
      onPressed: _cycleSpeed,
      icon: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(label, style: TextStyle(
          color: _speed == 1.0 ? color.withValues(alpha: 0.7) : const Color(0xFF6B8AFF),
          fontSize: 12, fontWeight: FontWeight.w600,
        )),
      ),
    );
  }

  Widget _desktopSpeedButton() {
    final label = _speed == 1.0 ? '1x' : '${_speed}x';
    return MaterialDesktopCustomButton(
      onPressed: _cycleSpeed,
      icon: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(label, style: TextStyle(
          color: _speed == 1.0 ? Colors.white70 : _kViewerAccent,
          fontSize: 12, fontWeight: FontWeight.w600,
        )),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final theme = MaterialVideoControlsThemeData(
      bottomButtonBarMargin: EdgeInsets.only(left: 12, right: 12, bottom: bottomPad + 8),
      seekBarMargin: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
      seekBarThumbColor: const Color(0xFF6B8AFF),
      seekBarColor: const Color(0xFF6B8AFF),
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        _speedButton(),
        const MaterialFullscreenButton(),
      ],
    );
    final desktopTheme = MaterialDesktopVideoControlsThemeData(
      seekBarThumbColor: const Color(0xFF6B8AFF),
      seekBarPositionColor: const Color(0xFF6B8AFF),
      bottomButtonBar: [
        const MaterialDesktopSkipPreviousButton(),
        const MaterialDesktopPlayOrPauseButton(),
        const MaterialDesktopSkipNextButton(),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        _desktopSpeedButton(),
        const MaterialDesktopFullscreenButton(),
      ],
    );

    return MaterialVideoControlsTheme(
      normal: theme,
      fullscreen: theme,
      child: MaterialDesktopVideoControlsTheme(
        normal: desktopTheme,
        fullscreen: desktopTheme,
        child: Video(
          controller: widget.controller,
          controls: _isDesktop ? MaterialDesktopVideoControls : MaterialVideoControls,
        ),
      ),
    );
  }
}
