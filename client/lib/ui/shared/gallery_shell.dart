import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/media_service.dart';
import '../../core/platform.dart';
import '../../core/server_state.dart';
import '../../core/time_fmt.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_toast.dart';
import 'folder_picker.dart';
import 'gallery_view.dart';
import 'local_photos_tab.dart';
import 'media_picker.dart';
import 'media_viewer.dart';
import 'profile_tab.dart';
import 'search_tab.dart';
import 'upload_bar.dart';
import 'upload_history_page.dart';

/// 移动端主框架：底部 5 tab (资源·相册·+·搜索·主页) + 选择态操作条。
/// 桌面端仍走原有单页 GalleryView。
class GalleryShell extends StatefulWidget {
  const GalleryShell({super.key});

  @override
  State<GalleryShell> createState() => _GalleryShellState();
}

class _GalleryShellState extends State<GalleryShell>
    implements GalleryShellHost {
  int _tab = 0;
  bool _resolving = false;

  // 各 tab 通过回调传上来的选择状态
  bool _selecting = false;
  Set<String> _selectedIds = {};
  bool _allSelected = false;
  bool _allFavorite = false;
  SelectionActionMode _selectionMode = SelectionActionMode.media;

  // 当前活跃 tab 的操作回调（由 tab 注册）
  VoidCallback? _onToggleSelectAll;
  VoidCallback? _onFavorite;
  VoidCallback? _onMove;
  VoidCallback? _onDownload;
  VoidCallback? _onDelete;
  VoidCallback? _onUpload;
  VoidCallback? _onExitSelection;

  // MediaViewer 提升到 shell 层
  List<MediaItem>? _viewerItems;
  int? _viewerIndex;
  MediaService? _viewerService;
  void Function(String)? _onViewerDeleted;

  bool _wasUploading = false;

  @override
  void initState() {
    super.initState();
    UploadManager.instance.addListener(_onUploadChanged);
  }

  @override
  void dispose() {
    UploadManager.instance.removeListener(_onUploadChanged);
    super.dispose();
  }

  void _onUploadChanged() {
    final uploading = UploadManager.instance.uploading;
    if (!_wasUploading && uploading) {
      setState(() => _resolving = true);
    }
    if (_wasUploading && !uploading && _resolving) {
      setState(() => _resolving = false);
    }
    _wasUploading = uploading;
  }

  @override
  void openViewer({
    required List<MediaItem> items,
    required int index,
    required MediaService service,
    void Function(String)? onDeleted,
  }) {
    setState(() {
      _viewerItems = items;
      _viewerIndex = index;
      _viewerService = service;
      _onViewerDeleted = onDeleted;
    });
  }

  void _closeViewer() {
    setState(() {
      _viewerItems = null;
      _viewerIndex = null;
      _viewerService = null;
      _onViewerDeleted = null;
    });
  }

  @override
  void updateSelection({
    required int sourceTab,
    required bool selecting,
    required Set<String> selectedIds,
    required bool allSelected,
    required bool allFavorite,
    SelectionActionMode mode = SelectionActionMode.media,
    VoidCallback? onToggleSelectAll,
    VoidCallback? onFavorite,
    VoidCallback? onMove,
    VoidCallback? onDownload,
    VoidCallback? onDelete,
    VoidCallback? onUpload,
    VoidCallback? onExitSelection,
  }) {
    if (sourceTab != _tab) return;
    setState(() {
      _selecting = selecting;
      _selectedIds = selectedIds;
      _allSelected = allSelected;
      _allFavorite = allFavorite;
      _selectionMode = mode;
      _onToggleSelectAll = onToggleSelectAll;
      _onFavorite = onFavorite;
      _onMove = onMove;
      _onDownload = onDownload;
      _onDelete = onDelete;
      _onUpload = onUpload;
      _onExitSelection = onExitSelection;
    });
  }

  // ── 上传 ──

  @override
  void switchToTab(int index) {
    setState(() => _tab = index);
  }

  @override
  Future<void> pickAndUpload({String? folderId}) async {
    final state = context.read<ServerState>();
    if (state.status != ConnectionStatus.connected) return;
    if (UploadManager.instance.uploading) {
      showToast(context, '正在上传中，请稍候', kind: ToastKind.info);
      return;
    }
    final service = MediaService(state);

    final List<PendingUpload> files;
    final source = isDesktop
        ? UploadSource.files
        : await showUploadSourcePicker(context);
    if (!mounted || source == null) return;
    if (source == UploadSource.files) {
      final picked = await FilePicker.pickFiles(type: FileType.any);
      files = picked
          .where((file) => file.path != null)
          .map((file) => PendingUpload(File(file.path!)))
          .toList();
    } else {
      final result = await Navigator.of(context).push<List<PendingUpload>>(
        MaterialPageRoute(builder: (_) => const MediaPickerPage()),
      );
      files = result ?? [];
    }
    if (files.isEmpty || !mounted) return;

    final serverUrl = state.baseUrl;
    final result = await UploadManager.instance.enqueue(
      service,
      files,
      folderId: folderId,
      serverUrl: serverUrl,
    );

    if (mounted) {
      final parts = <String>['已上传 ${result.uploaded} 个'];
      if (result.dedup > 0) parts.add('${result.dedup} 个已存在跳过');
      if (result.failed > 0) parts.add('${result.failed} 个失败');
      if (result.cancelled > 0) parts.add('${result.cancelled} 个已取消');
      showToast(
        context,
        parts.join(' · '),
        kind: result.allOk ? ToastKind.success : ToastKind.error,
      );
    }
  }

  void _openUploadHistory() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const UploadHistoryPage()));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return PopScope(
      canPop: _viewerIndex == null && !_selecting && _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_viewerIndex != null) return;
        if (_selecting) {
          _onExitSelection?.call();
          return;
        }
        if (_tab != 0) {
          setState(() => _tab = 0);
          return;
        }
      },
      child: Scaffold(
        backgroundColor: c.bg,
        bottomNavigationBar: _buildBottomBar(c),
        body: SafeArea(
          bottom: false,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  UploadBar(onTap: _openUploadHistory),
                  Expanded(
                    child: IndexedStack(
                      index: _tab,
                      children: [
                        GalleryView(
                          key: const ValueKey('albums'),
                          mode: GalleryMode.albums,
                          shell: this,
                        ),
                        SearchTab(shell: this),
                        LocalPhotosTab(shell: this, active: _tab == 2),
                        const ProfileTab(),
                      ],
                    ),
                  ),
                ],
              ),
              if (_viewerIndex != null &&
                  _viewerItems != null &&
                  _viewerService != null)
                MediaViewer(
                  items: _viewerItems!,
                  initialIndex: _viewerIndex!,
                  service: _viewerService!,
                  onClose: _closeViewer,
                  onDeleted: (id) {
                    _onViewerDeleted?.call(id);
                    setState(() {
                      _viewerItems!.removeWhere((m) => m.id == id);
                      if (_viewerItems!.isEmpty) _closeViewer();
                    });
                  },
                ),
              if (_resolving)
                _UploadOverlay(
                  onHide: () {
                    UploadManager.instance.showBar();
                    setState(() => _resolving = false);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // keep the closing structure clean — removed AnnotatedRegion, added SafeArea

  Widget _buildBottomBar(AppColors c) {
    if (_selecting) return _buildSelectionBar(c);
    return _buildTabBar(c);
  }

  Widget _buildTabBar(AppColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.outline, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              _tabItem(
                c,
                0,
                Icons.photo_library_outlined,
                Icons.photo_library,
                '相册',
              ),
              _tabItem(c, 1, Icons.search_outlined, Icons.search, '搜索'),
              _cameraButton(c),
              _tabItem(c, 2, Icons.photo_outlined, Icons.photo, '本地'),
              _tabItem(c, 3, Icons.person_outline, Icons.person, '我的'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cameraButton(AppColors c) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _capture(video: false),
        onLongPress: () {
          // 给一下震动，明确告诉用户"长按 = 录像"已生效，
          // 否则系统相机切到录像模式的瞬间没有任何反馈，用户会以为没反应。
          HapticFeedback.mediumImpact();
          _capture(video: true);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle),
              child: const Icon(
                Icons.camera_alt,
                size: 20,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _capture({required bool video}) async {
    try {
      final picker = ImagePicker();
      final xfile = video
          ? await picker.pickVideo(source: ImageSource.camera)
          : await picker.pickImage(source: ImageSource.camera);
      if (xfile == null || !mounted) return;
      final file = File(xfile.path);
      // 系统相机导出的副本可能没有 EXIF，使用文件时间保证新拍内容正确排序。
      String? takenAtIso;
      try {
        takenAtIso = toServerRfc3339((await file.stat()).modified);
      } catch (_) {}
      if (!mounted) return;
      await showFolderPickerAndUpload(context, [
        PendingUpload(file, takenAtIso: takenAtIso),
      ]);
    } catch (e) {
      if (mounted) showToast(context, '无法打开相机', kind: ToastKind.error);
    }
  }

  Widget _tabItem(
    AppColors c,
    int index,
    IconData icon,
    IconData activeIcon,
    String label,
  ) {
    final active = _tab == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              active ? activeIcon : icon,
              size: 24,
              color: active ? c.brand : c.onMuted,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: active ? c.brand : c.onMuted,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar(AppColors c) {
    final localUpload = _selectionMode == SelectionActionMode.localUpload;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.outline, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: localUpload
                ? [
                    _selectionAction(
                      c,
                      icon: _allSelected ? Icons.deselect : Icons.select_all,
                      label: _allSelected ? '取消全选' : '全选已加载',
                      color: _allSelected ? c.brand : c.onSurfaceVariant,
                      onTap: _onToggleSelectAll,
                    ),
                    _selectionAction(
                      c,
                      icon: Icons.upload_rounded,
                      label: '上传 ${_selectedIds.length} 项',
                      color: c.brand,
                      onTap: _onUpload,
                    ),
                  ]
                : [
                    _selectionAction(
                      c,
                      icon: _allSelected ? Icons.deselect : Icons.select_all,
                      label: _allSelected ? '取消全选' : '全选',
                      color: _allSelected ? c.brand : c.onSurfaceVariant,
                      onTap: _onToggleSelectAll,
                    ),
                    _selectionAction(
                      c,
                      icon: _allFavorite
                          ? Icons.favorite
                          : Icons.favorite_border,
                      label: _allFavorite ? '取消收藏' : '收藏',
                      color: _allFavorite ? c.brand : c.onSurfaceVariant,
                      onTap: _onFavorite,
                    ),
                    _selectionAction(
                      c,
                      icon: Icons.drive_file_move_outlined,
                      label: '移动',
                      color: c.onSurfaceVariant,
                      onTap: _onMove,
                    ),
                    _selectionAction(
                      c,
                      icon: Icons.file_download_outlined,
                      label: '下载',
                      color: c.onSurfaceVariant,
                      onTap: _onDownload,
                    ),
                    _selectionAction(
                      c,
                      icon: Icons.delete_outline,
                      label: '删除',
                      color: c.error,
                      onTap: _onDelete,
                    ),
                  ],
          ),
        ),
      ),
    );
  }

  Widget _selectionAction(
    AppColors c, {
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
    );
  }
}

// ── 上传进度浮层（居中，彩色旋转环 + 高对比度按钮） ──

class _UploadOverlay extends StatefulWidget {
  final VoidCallback onHide;
  const _UploadOverlay({required this.onHide});

  @override
  State<_UploadOverlay> createState() => _UploadOverlayState();
}

class _UploadOverlayState extends State<_UploadOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinCtrl;

  static const _ringColors = [
    Color(0xFFFF3B30), // red
    Color(0xFFFF9500), // orange
    Color(0xFFFFCC00), // yellow
    Color(0xFF34C759), // green
    Color(0xFF007AFF), // blue
    Color(0xFFAF52DE), // purple
    Color(0xFFFF3B30), // wrap back to red
  ];

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    UploadManager.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    UploadManager.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  String _fmtBytes(double bytes) {
    if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtEta(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = UploadManager.instance;
    final uploading = m.uploading;
    final progress = m.progress;
    final speed = m.speedBps;
    final eta = m.eta;
    final pct = (progress * 100).toInt();

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: Colors.black54,
          child: Center(
            child: Container(
              width: 280,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              decoration: BoxDecoration(
                color: c.bg,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 32,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 彩色旋转外环 + 百分比
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: AnimatedBuilder(
                      animation: _spinCtrl,
                      builder: (ctx, _) => CustomPaint(
                        painter: _RainbowRingPainter(
                          rotation: _spinCtrl.value * 2 * 3.14159265,
                          colors: _ringColors,
                          strokeWidth: 5,
                        ),
                        child: Center(
                          child: uploading
                              ? Text(
                                  '$pct%',
                                  style: TextStyle(
                                    color: c.onSurface,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                )
                              : Icon(
                                  Icons.cloud_upload_rounded,
                                  size: 28,
                                  color: c.brand,
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  // 上传状态文字
                  Text(
                    uploading ? '正在上传 ${m.completed}/${m.total}' : '正在准备上传…',
                    style: TextStyle(
                      color: c.onSurface,
                      fontSize: AppType.md,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // 速度 + ETA
                  if (uploading)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        [
                          if (speed > 0) '${_fmtBytes(speed)}/s',
                          if (speed <= 0) '计算中…',
                          if (eta != null) '剩余 ${_fmtEta(eta)}',
                        ].join(' · '),
                        style: TextStyle(
                          color: c.onMuted,
                          fontSize: AppType.xs,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  // 按钮
                  Row(
                    children: [
                      if (uploading && !m.cancelling)
                        Expanded(
                          child: _ActionButton(
                            label: '取消上传',
                            color: c.onSurface,
                            bg: c.surface2,
                            onTap: m.cancel,
                          ),
                        ),
                      if (uploading && m.cancelling)
                        Expanded(
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.onMuted,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ActionButton(
                          label: '后台运行',
                          color: Colors.white,
                          bg: c.brand,
                          onTap: widget.onHide,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 抖音风格相机面板 ──

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  final VoidCallback? onTap;
  const _ActionButton({
    required this.label,
    required this.color,
    required this.bg,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: AppType.sm,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _RainbowRingPainter extends CustomPainter {
  final double rotation;
  final List<Color> colors;
  final double strokeWidth;
  _RainbowRingPainter({
    required this.rotation,
    required this.colors,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    canvas.translate(-center.dx, -center.dy);
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(colors: colors).createShader(rect);
    final r = (size.width - strokeWidth) / 2;
    canvas.drawCircle(center, r, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RainbowRingPainter old) => old.rotation != rotation;
}
