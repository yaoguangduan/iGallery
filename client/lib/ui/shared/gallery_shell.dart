import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/kv_store.dart';
import '../../core/media_permission.dart';
import '../../core/media_service.dart';
import '../../core/platform.dart';
import '../../core/server_state.dart';
import '../../core/time_fmt.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
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

  // 文件夹层级（GalleryView 通过 updateFolderDepth 上报）
  int _folderDepth = 0;
  VoidCallback? _onGoBackFolder;

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
  // 查看器选择态上下文（相册 tab 选择模式下打开查看器时用）
  bool _viewerSelecting = false;
  Set<String> _viewerSelectedIds = const {};
  ValueChanged<String>? _viewerOnToggleSelect;

  bool _wasUploading = false;

  @override
  void initState() {
    super.initState();
    UploadManager.instance.addListener(_onUploadChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _promptManageMedia());
  }

  @override
  void dispose() {
    UploadManager.instance.removeListener(_onUploadChanged);
    super.dispose();
  }

  /// 上次弹 MANAGE_MEDIA 引导的时间戳(ms)，用于冷却，别天天骚扰
  static const String _kManageMediaPromptAt = 'manage_media_prompt_at';

  /// 启动检测（仅 Android 12+ 未授权时会走到弹框）：授予「允许管理所有媒体文件」后，
  /// 本地 tab 删除照片不再被系统弹「允许删除?」二次确认。
  /// 3 天冷却：点过「取消」短期内不再弹；之后仍没授权会再提醒。
  Future<void> _promptManageMedia() async {
    if (!await MediaPermission.needsManageMedia()) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last =
        int.tryParse(await KvStore.instance.get(_kManageMediaPromptAt) ?? '');
    if (last != null && now - last < Duration(days: 3).inMilliseconds) {
      return;
    }
    if (!mounted) return;
    // 写库与弹框放在同一同步 turn(unawaited 只丢 future,insert 已入队自会完成):
    // 若 await 写库后再弹框,MobileShell 的通知横幅重建可能正好在 await 期间 dispose 本
    // shell——写入落地了、弹框却被 mounted 拦下,变成"记了 3 天冷却却从没弹过"。
    // 同 turn 内帧无法插入,要么写+弹都发生要么都不发生;重建出的新实例也能读到
    // 时间戳,不会叠弹第二个框。
    unawaited(KvStore.instance.set(_kManageMediaPromptAt, '$now'));
    final go = await appConfirmDialog(
      context,
      title: '删除照片免二次确认',
      message: 'Android 12 及以上，删除不是本应用保存的照片时，'
          '系统每次还会再弹一个「允许删除?」确认框。\n\n'
          '授予「允许管理所有媒体文件」后，删除将不再弹框。',
      confirmLabel: '去授权',
    );
    if (!go) return;
    final opened = await MediaPermission.openManageMediaSettings();
    if (!opened && mounted) {
      showToast(context, '当前系统不支持该设置页', kind: ToastKind.error);
    }
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
    bool selecting = false,
    Set<String> selectedIds = const {},
    ValueChanged<String>? onToggleSelect,
  }) {
    // #15 守卫：调用方传的是 indexOf，item 可能已被后台刷新移除得到 -1，
    // 直接进查看器会在 initState items[-1] 崩溃。
    if (index < 0 || index >= items.length) return;
    setState(() {
      _viewerItems = items;
      _viewerIndex = index;
      _viewerService = service;
      _onViewerDeleted = onDeleted;
      _viewerSelecting = selecting;
      _viewerSelectedIds = selectedIds;
      _viewerOnToggleSelect = onToggleSelect;
    });
  }

  void _closeViewer() {
    setState(() {
      _viewerItems = null;
      _viewerIndex = null;
      _viewerService = null;
      _onViewerDeleted = null;
      _viewerSelecting = false;
      _viewerSelectedIds = const {};
      _viewerOnToggleSelect = null;
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
  void updateFolderDepth(int depth, {VoidCallback? onGoBack}) {
    if (_folderDepth == depth) return;
    setState(() {
      _folderDepth = depth;
      _onGoBackFolder = onGoBack;
    });
  }

  @override
  void switchToTab(int index) {
    setState(() => _tab = index);
  }

  /// 下载成功后"查看"：收起可能浮着的查看器，切到本地 tab。
  /// LocalPhotosTab 变 active 时会强制全量刷新，新下载的文件会出现在最前。
  @override
  void showLocalDownloads() {
    if (_viewerIndex != null) _closeViewer();
    switchToTab(2);
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
      files = (picked?.files ?? [])
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
      canPop: _viewerIndex == null && !_selecting && _tab == 0 && _folderDepth == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_viewerIndex != null) return;
        if (_selecting) {
          _onExitSelection?.call();
          return;
        }
        if (_tab == 0 && _folderDepth > 0) {
          _onGoBackFolder?.call();
          return;
        }
        if (_tab != 0) {
          setState(() => _tab = 0);
          return;
        }
      },
      child: Scaffold(
        backgroundColor: c.bg,
        // 查看器打开时隐藏底栏：否则它能盖不住底部的 tab/选择操作条，
        // 用户会在"全屏"查看时误切 tab、误点删除（也是查看器共享列表被刷新截断崩溃的触发器）。
        bottomNavigationBar: _viewerIndex != null ? null : _buildBottomBar(c),
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
                  onViewLocal: showLocalDownloads,
                  selecting: _viewerSelecting,
                  selectedIds: _viewerSelectedIds,
                  onToggleSelect: _viewerOnToggleSelect,
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

  final GlobalKey _cameraKey = GlobalKey();

  Widget _cameraButton(AppColors c) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showCapturePopup,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              key: _cameraKey,
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

  void _showCapturePopup() {
    final renderBox =
        _cameraKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final pos = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final cx = pos.dx + size.width / 2;
    final bottom = pos.dy;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _CapturePopup(
        centerX: cx,
        bottomY: bottom - 12,
        onChoice: (video) {
          entry.remove();
          _capture(video: video);
        },
        onDismiss: () => entry.remove(),
      ),
    );
    Overlay.of(context).insert(entry);
  }

  Future<void> _capture({required bool video}) async {
    try {
      final picker = ImagePicker();
      final XFile? xfile;
      if (video) {
        xfile = await picker.pickVideo(
          source: ImageSource.camera,
          maxDuration: const Duration(minutes: 30),
        );
      } else {
        xfile = await picker.pickImage(source: ImageSource.camera);
      }
      if (xfile == null || !mounted) return;
      final file = File(xfile.path);
      String? takenAtIso;
      try {
        takenAtIso = toServerRfc3339((await file.stat()).modified);
      } catch (_) {}
      if (!mounted) return;
      await showFolderPickerAndUpload(context, [
        PendingUpload(file, takenAtIso: takenAtIso),
      ]);
    } catch (e) {
      if (mounted) showToast(context, '无法打开相机: $e', kind: ToastKind.error);
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
                      label: '上传',
                      color: c.brand,
                      onTap: _onUpload,
                    ),
                    _selectionAction(
                      c,
                      icon: Icons.delete_outline,
                      label: '删除本地',
                      color: c.error,
                      onTap: _onDelete,
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
                    // 只显示当前 tab 真正注册了回调的动作：搜索 tab 只接了"全选+删除"，
                    // 收藏/移动/下载没注册就不画，免得出现点了没反应的死按钮。
                    if (_onFavorite != null)
                      _selectionAction(
                        c,
                        icon: _allFavorite
                            ? Icons.favorite
                            : Icons.favorite_border,
                        label: _allFavorite ? '取消收藏' : '收藏',
                        color: _allFavorite ? c.brand : c.onSurfaceVariant,
                        onTap: _onFavorite,
                      ),
                    if (_onMove != null)
                      _selectionAction(
                        c,
                        icon: Icons.drive_file_move_outlined,
                        label: '移动',
                        color: c.onSurfaceVariant,
                        onTap: _onMove,
                      ),
                    if (_onDownload != null)
                      _selectionAction(
                        c,
                        icon: Icons.file_download_outlined,
                        label: '下载',
                        color: c.onSurfaceVariant,
                        onTap: _onDownload,
                      ),
                    if (_onDelete != null)
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
    final retrying = m.retrying;
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
                  // 彩色旋转外环 + 百分比 / 断网图标
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: retrying
                        ? Center(
                            child: Icon(
                              Icons.wifi_off_rounded,
                              size: 36,
                              color: c.onMuted,
                            ),
                          )
                        : AnimatedBuilder(
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
                    retrying
                        ? '网络断开，重试中…'
                        : uploading
                            ? '正在上传 ${m.completed}/${m.total}'
                            : '正在准备上传…',
                    style: TextStyle(
                      color: c.onSurface,
                      fontSize: AppType.md,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (retrying)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '已完成 ${m.completed}/${m.total}，等待网络恢复',
                        style: TextStyle(
                          color: c.onMuted,
                          fontSize: AppType.xs,
                        ),
                      ),
                    ),
                  // 速度 + ETA
                  if (uploading && !retrying)
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

// ── 相机弹出菜单 ──

class _CapturePopup extends StatefulWidget {
  final double centerX;
  final double bottomY;
  final void Function(bool video) onChoice;
  final VoidCallback onDismiss;

  const _CapturePopup({
    required this.centerX,
    required this.bottomY,
    required this.onChoice,
    required this.onDismiss,
  });

  @override
  State<_CapturePopup> createState() => _CapturePopupState();
}

class _CapturePopupState extends State<_CapturePopup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  // 两个按钮错峰弹出：拍照先冒、录像随后，收起时倒序
  late final Animation<double> _photoScale;
  late final Animation<double> _videoScale;
  late final Animation<double> _rise;
  // 从中心"绽放"：间距由 0 展开到 gap，两枚按钮边放大边向两侧滑开
  late final Animation<double> _spread;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5));
    _photoScale = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.72, curve: Curves.easeOutBack),
    );
    _videoScale = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.14, 0.86, curve: Curves.easeOutBack),
    );
    _rise = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.8, curve: Curves.easeOutCubic),
    );
    _spread = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.85, curve: Curves.easeOutCubic),
    );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _dismiss() {
    _ctrl.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    const btnSize = 60.0;
    const gap = 26.0;
    const totalW = btnSize * 2 + gap;

    // Material 包裹，给浮层一个正确的主题/手势上下文
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismiss,
              child: FadeTransition(
                opacity: _fade,
                child: const ColoredBox(color: Colors.black38),
              ),
            ),
          ),
          Positioned(
            left: widget.centerX - totalW / 2,
            top: widget.bottomY - btnSize - 16,
            width: totalW,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => Transform.translate(
                offset: Offset(0, 18 * (1 - _rise.value)),
                child: FadeTransition(
                  opacity: _fade,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CaptureBtn(
                        scale: _photoScale,
                        icon: Icons.photo_camera_rounded,
                        // 品牌蓝渐变 + 同色辉光
                        colors: const [Color(0xFF4C97F7), Color(0xFF065FD4)],
                        onTap: () => widget.onChoice(false),
                      ),
                      // 间距随动画展开：两枚按钮从中心向两侧"绽放"
                      SizedBox(width: gap * _spread.value),
                      _CaptureBtn(
                        scale: _videoScale,
                        icon: Icons.videocam_rounded,
                        // 录像用红色（相机录像键的行业惯例）
                        colors: const [Color(0xFFFF6B6B), Color(0xFFD61B1B)],
                        onTap: () => widget.onChoice(true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureBtn extends StatelessWidget {
  final Animation<double> scale;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;

  const _CaptureBtn({
    required this.scale,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 只有圆形图标，不带文字标签（拍照/录像人人都懂）；从中心缩放，配合间距展开成"绽放"效果
    return ScaleTransition(
      scale: scale,
      alignment: Alignment.center,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            boxShadow: [
              BoxShadow(
                color: colors.last.withValues(alpha: 0.55),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 28),
        ),
      ),
    );
  }
}
