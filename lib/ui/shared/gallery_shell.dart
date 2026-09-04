import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/media_service.dart';
import '../../core/platform.dart';
import '../../core/server_state.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_toast.dart';
import 'gallery_view.dart';
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

class _GalleryShellState extends State<GalleryShell> implements GalleryShellHost {
  int _tab = 0;
  bool _resolving = false;

  // 各 tab 通过回调传上来的选择状态
  bool _selecting = false;
  Set<String> _selectedIds = {};
  bool _allSelected = false;
  bool _allFavorite = false;
  // 当前活跃 tab 的操作回调（由 tab 注册）
  VoidCallback? _onToggleSelectAll;
  VoidCallback? _onFavorite;
  VoidCallback? _onMove;
  VoidCallback? _onDownload;
  VoidCallback? _onDelete;
  VoidCallback? _onExitSelection;

  // MediaViewer 提升到 shell 层
  List<MediaItem>? _viewerItems;
  int? _viewerIndex;
  MediaService? _viewerService;
  void Function(String)? _onViewerDeleted;

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
    required bool selecting,
    required Set<String> selectedIds,
    required bool allSelected,
    required bool allFavorite,
    VoidCallback? onToggleSelectAll,
    VoidCallback? onFavorite,
    VoidCallback? onMove,
    VoidCallback? onDownload,
    VoidCallback? onDelete,
    VoidCallback? onExitSelection,
  }) {
    if (_selecting == selecting &&
        _selectedIds.length == selectedIds.length &&
        _allSelected == allSelected &&
        _allFavorite == allFavorite) return;
    setState(() {
      _selecting = selecting;
      _selectedIds = selectedIds;
      _allSelected = allSelected;
      _allFavorite = allFavorite;
      _onToggleSelectAll = onToggleSelectAll;
      _onFavorite = onFavorite;
      _onMove = onMove;
      _onDownload = onDownload;
      _onDelete = onDelete;
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
    if (isDesktop) {
      final picked = await FilePicker.pickFiles(type: FileType.any);
      files = picked
          .where((f) => f.path != null)
          .map((f) => PendingUpload(File(f.path!)))
          .toList();
    } else {
      final result = await Navigator.of(context).push<List<PendingUpload>>(
        MaterialPageRoute(builder: (_) => const MediaPickerPage()),
      );
      files = result ?? [];
    }
    if (files.isEmpty || !mounted) return;

    setState(() => _resolving = true);

    final serverUrl = state.baseUrl;
    final result = await UploadManager.instance.enqueue(
      service, files,
      folderId: folderId,
      serverUrl: serverUrl,
    );
    if (mounted && _resolving) setState(() => _resolving = false);

    if (mounted) {
      final parts = <String>['已上传 ${result.uploaded} 个'];
      if (result.dedup > 0) parts.add('${result.dedup} 个已存在跳过');
      if (result.failed > 0) parts.add('${result.failed} 个失败');
      if (result.cancelled > 0) parts.add('${result.cancelled} 个已取消');
      showToast(context, parts.join(' · '),
          kind: result.allOk ? ToastKind.success : ToastKind.error);
    }
  }

  void _openUploadHistory() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UploadHistoryPage()));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return PopScope(
        canPop: _viewerIndex == null && !_selecting && _tab == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_viewerIndex != null) { _closeViewer(); return; }
          if (_selecting) { _onExitSelection?.call(); return; }
          if (_tab != 0) { setState(() => _tab = 0); return; }
        },
        child: Scaffold(
          backgroundColor: c.bg,
          bottomNavigationBar: _buildBottomBar(c),
          body: SafeArea(
            bottom: false,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(children: [
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
                        const ProfileTab(),
                      ],
                    ),
                  ),
                ]),
                if (_viewerIndex != null && _viewerItems != null && _viewerService != null)
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
                    onHide: () => setState(() => _resolving = false),
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
          child: Row(children: [
            _tabItem(c, 0, Icons.photo_library_outlined, Icons.photo_library, '相册'),
            _tabItem(c, 1, Icons.search_outlined, Icons.search, '搜索'),
            _tabItem(c, 2, Icons.person_outline, Icons.person, '我的'),
          ]),
        ),
      ),
    );
  }

  Widget _tabItem(AppColors c, int index, IconData icon, IconData activeIcon, String label) {
    final active = _tab == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(active ? activeIcon : icon, size: 24,
                color: active ? c.brand : c.onMuted),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(
              fontSize: 11.5,
              color: active ? c.brand : c.onMuted,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar(AppColors c) {
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
            children: [
              _selectionAction(
                c,
                icon: _allSelected ? Icons.deselect : Icons.select_all,
                label: _allSelected ? '取消全选' : '全选',
                color: _allSelected ? c.brand : c.onSurfaceVariant,
                onTap: _onToggleSelectAll,
              ),
              _selectionAction(
                c,
                icon: _allFavorite ? Icons.favorite : Icons.favorite_border,
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

  Widget _selectionAction(AppColors c, {
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

// ── 上传进度浮层（底部卡片风格，类似 Google Drive） ──

class _UploadOverlay extends StatefulWidget {
  final VoidCallback onHide;
  const _UploadOverlay({required this.onHide});

  @override
  State<_UploadOverlay> createState() => _UploadOverlayState();
}

class _UploadOverlayState extends State<_UploadOverlay> {
  @override
  void initState() {
    super.initState();
    UploadManager.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    UploadManager.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() { if (mounted) setState(() {}); }

  String _fmtBytes(double bytes) {
    if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Positioned.fill(child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ColoredBox(
        color: Colors.black26,
        child: Column(children: [
          const Spacer(),
          Container(
            margin: EdgeInsets.fromLTRB(12, 0, 12, 12 + bottomPad),
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(AppRadius.card),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                // 小圆环进度
                SizedBox(
                  width: 36, height: 36,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox(
                      width: 36, height: 36,
                      child: CircularProgressIndicator(
                        value: uploading ? progress.clamp(0, 1).toDouble() : null,
                        strokeWidth: 3,
                        color: c.brand,
                        backgroundColor: c.outline,
                      ),
                    ),
                    if (uploading)
                      Text('$pct', style: TextStyle(
                        color: c.onSurface, fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ))
                    else
                      Icon(Icons.cloud_upload_outlined, size: 16, color: c.brand),
                  ]),
                ),
                const SizedBox(width: 12),
                // 文本信息
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      uploading
                          ? '正在上传 ${m.completed}/${m.total}'
                          : '正在准备上传…',
                      style: TextStyle(
                        color: c.onSurface,
                        fontSize: AppType.xs,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (uploading && (speed > 0 || eta != null))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          [
                            if (speed > 0) '${_fmtBytes(speed)}/s',
                            if (eta != null) '剩余 ${_fmtEta(eta)}',
                          ].join(' · '),
                          style: TextStyle(color: c.onMuted, fontSize: AppType.xxs),
                        ),
                      ),
                  ],
                )),
                // 操作按钮
                if (uploading && !m.cancelling)
                  _PillButton(
                    label: '取消',
                    color: c.onSurfaceVariant,
                    outlined: true,
                    onTap: m.cancel,
                  ),
                if (uploading && m.cancelling)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: c.onMuted),
                    ),
                  ),
                const SizedBox(width: 4),
                _PillButton(
                  label: '后台',
                  color: c.brand,
                  onTap: widget.onHide,
                ),
              ]),
              // 底部线性进度条
              if (uploading) Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0, 1).toDouble(),
                    minHeight: 3,
                    backgroundColor: c.surface2,
                    valueColor: AlwaysStoppedAnimation(c.brand),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    ));
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final Color color;
  final bool outlined;
  final VoidCallback? onTap;
  const _PillButton({required this.label, required this.color, this.outlined = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: outlined ? Colors.transparent : color,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: outlined ? Border.all(color: color.withValues(alpha: 0.3)) : null,
        ),
        child: Text(label, style: TextStyle(
          color: outlined ? color : Colors.white,
          fontSize: AppType.xxs,
          fontWeight: FontWeight.w600,
        )),
      ),
    );
  }
}
