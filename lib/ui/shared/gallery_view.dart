import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/display_prefs.dart';
import '../../core/hash_sync.dart';
import '../../core/download_service.dart';
import '../../core/media_service.dart';
import '../../core/platform.dart';
import '../../core/server_state.dart';
import '../../core/time_fmt.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';
import 'cached_thumb.dart';
import 'drag_select.dart';
import 'gallery_groups.dart';
import 'gallery_widgets.dart';
import 'media_picker.dart';
import 'media_viewer.dart';
import 'settings_sheet.dart';
import 'upload_bar.dart';
import 'upload_history_page.dart';

enum SelectionActionMode { media, localUpload }

/// Shell 层回调接口，避免 gallery_view 和 gallery_shell 循环依赖。
abstract class GalleryShellHost {
  void openViewer({
    required List<MediaItem> items,
    required int index,
    required MediaService service,
    void Function(String)? onDeleted,
  });
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
  });
  void updateFolderDepth(int depth, {VoidCallback? onGoBack});
  void pickAndUpload({String? folderId});
  void switchToTab(int index);
}

bool get _isDesktop => isDesktop;

enum GalleryMode { allMedia, albums }

class GalleryView extends StatefulWidget {
  final GalleryMode mode;
  final GalleryShellHost? shell;
  const GalleryView({super.key, this.mode = GalleryMode.albums, this.shell});

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView>
    with SingleTickerProviderStateMixin {
  static const int _pageSize = 80;

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _scrollCtrl = ScrollController();
  final List<MediaItem> _items = [];
  final Set<String> _itemIds = {};
  bool _loading = false;
  bool _paginationBlocked = false;
  String? _nextCursor;
  int _total = 0;
  bool _showScrollTop = false;
  final _reloadSeq = Seq();

  bool _selecting = false;
  final Set<String> _selected = {};
  final Set<String> _unlockedFolderIds = {};

  // 滑选（多选模式下按住拖动）
  int? _sweepAnchor;
  bool _sweepAdding = true;
  Set<String> _sweepBaseline = {};

  // 下载进度（仅"逐个下载"模式使用；上传走 UploadManager）
  bool _downloading = false;
  bool _resolving = false;
  int _downloadCompleted = 0;

  // (unused state removed — floating bar deleted)
  int _downloadTotal = 0;

  int? _viewerIndex;
  MediaService? _service;

  // folder navigation
  String? _currentFolderId;
  final List<({String id, String name})> _folderPath = [];
  List<FolderItem> _folders = [];
  bool _breadcrumbExpanded = false;

  // 双指缩放列数：自己数指针，不用 ScaleGestureRecognizer（会被 scroll 抢走）
  final Set<int> _activePointers = {};
  final Map<int, Offset> _pointerPos = {};
  double _pinchStartDist = 0;
  double _pinchScale = 1.0;
  // 松手后把新列数从"接上手指离开时的视觉大小"平滑收回 1.0，
  // 否则重排是一帧硬切，看着很跳
  late final AnimationController _settleCtrl;
  double _settleFrom = 1.0;

  bool get _hasMore => _nextCursor != null;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _settleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() => setState(() {}));
    if (_embedded) UploadManager.instance.addListener(_onUploadChanged);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _settleCtrl.dispose();
    if (_embedded) UploadManager.instance.removeListener(_onUploadChanged);
    super.dispose();
  }

  bool _wasUploading = false;
  void _onUploadChanged() {
    final uploading = UploadManager.instance.uploading;
    if (_wasUploading && !uploading) {
      _refresh();
      HashSync.instance.syncFromServer();
    }
    _wasUploading = uploading;
  }

  void _onScroll() {
    final pos = _scrollCtrl.position;

    final show = pos.pixels > 800;
    if (show != _showScrollTop) setState(() => _showScrollTop = show);

    if (pos.extentAfter <= 320 &&
        !_loading &&
        _hasMore &&
        !_paginationBlocked) {
      _loadPage(context.read<DisplayPrefs>());
    }
  }

  void _scheduleViewportFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      if (_loading || !_hasMore || _paginationBlocked) return;
      if (_scrollCtrl.position.extentAfter <= 320) {
        _loadPage(context.read<DisplayPrefs>());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.watch<ServerState>();
    final prefs = context.watch<DisplayPrefs>();

    if (state.status == ConnectionStatus.connected && _service == null) {
      _service = MediaService(state);
      _reload(prefs);
      HashSync.instance.syncFromServer();
    } else if (state.status != ConnectionStatus.connected) {
      _service = null;
    }
  }

  void _onPrefsChanged(DisplayPrefs prefs) {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(0);
    }
    _reload(prefs);
  }

  Future<void> _reload(DisplayPrefs prefs) async {
    if (_service == null) return;
    final seq = _reloadSeq.bump();
    setState(() {
      _loading = true;
      _nextCursor = null;
      _paginationBlocked = false;
    });
    try {
      final showFolders =
          widget.mode == GalleryMode.albums &&
          prefs.mediaFilter != MediaFilter.favoritesOnly;
      final futures = <Future>[
        _service!.query(
          size: _pageSize,
          filter: _buildFilter(prefs),
          sort: _buildSort(prefs),
          withTotal: true,
        ),
      ];
      if (showFolders) {
        futures.add(_service!.listFolders(parentId: _currentFolderId));
      }
      final results = await Future.wait(futures);
      if (!mounted || !_reloadSeq.valid(seq)) return;
      final mediaResult = results[0] as QueryResult;
      final folders = showFolders
          ? results[1] as List<FolderItem>
          : <FolderItem>[];
      setState(() {
        _items
          ..clear()
          ..addAll(mediaResult.items);
        _itemIds
          ..clear()
          ..addAll(mediaResult.items.map((item) => item.id));
        _total = mediaResult.total ?? mediaResult.items.length;
        _nextCursor = mediaResult.nextCursor;
        _folders = folders;
        _loading = false;
      });
      _scheduleViewportFill();
    } on ApiException catch (e) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() => _loading = false);
      showToast(context, e.userMessage, kind: ToastKind.error);
    } catch (_) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() => _loading = false);
      showToast(context, '加载失败', kind: ToastKind.error);
    }
  }

  Map<String, dynamic> _buildFilter(DisplayPrefs prefs) {
    final conditions = <Map<String, dynamic>>[
      {'field': 'deleted_at', 'op': 'is_null'},
    ];

    if (widget.mode == GalleryMode.allMedia) {
      // 跨文件夹查全部，不加 folder_id 条件
    } else if (_currentFolderId == null) {
      conditions.add({'field': 'folder_id', 'op': 'is_null'});
    } else {
      conditions.add({
        'field': 'folder_id',
        'op': '=',
        'value': _currentFolderId,
      });
    }

    if (prefs.mediaFilter == MediaFilter.photosOnly) {
      conditions.add({'field': 'media_type', 'op': '=', 'value': 'image'});
    } else if (prefs.mediaFilter == MediaFilter.videosOnly) {
      conditions.add({'field': 'media_type', 'op': '=', 'value': 'video'});
    } else if (prefs.mediaFilter == MediaFilter.favoritesOnly) {
      conditions.add({'field': 'favorite', 'op': '=', 'value': 1});
    }
    if (prefs.minSize != null) {
      conditions.add({'field': 'size', 'op': '>=', 'value': prefs.minSize});
    }
    if (prefs.maxSize != null) {
      conditions.add({'field': 'size', 'op': '<=', 'value': prefs.maxSize});
    }
    if (prefs.dateFrom != null && prefs.dateTo != null) {
      conditions.add({
        'field': 'taken_at',
        'op': '>=',
        'value': toServerRfc3339(prefs.dateFrom!),
      });
      conditions.add({
        'field': 'taken_at',
        'op': '<',
        'value': toServerRfc3339(prefs.dateTo!.add(const Duration(days: 1))),
      });
    }

    return {'and': conditions};
  }

  List<Map<String, String>> _buildSort(DisplayPrefs prefs) {
    final field = switch (prefs.sortField) {
      SortField.takenAt => 'taken_at',
      SortField.createdAt => 'created_at',
      SortField.size => 'size',
      SortField.filename => 'filename',
    };
    final dir = prefs.sortOrder == SortOrder.asc ? 'asc' : 'desc';
    return [
      {'field': field, 'dir': dir},
    ];
  }

  Future<void> _loadPage(DisplayPrefs prefs) async {
    if (_loading || !_hasMore || _service == null || _paginationBlocked) return;
    final cursor = _nextCursor;
    if (cursor == null) return;
    final seq = _reloadSeq.bump();
    setState(() => _loading = true);
    try {
      final result = await _service!.query(
        size: _pageSize,
        filter: _buildFilter(prefs),
        sort: _buildSort(prefs),
        cursor: cursor,
      );
      if (!mounted || !_reloadSeq.valid(seq)) return;
      final freshItems = result.items
          .where((item) => !_itemIds.contains(item.id))
          .toList(growable: false);
      final stalled =
          result.nextCursor == cursor ||
          (freshItems.isEmpty && result.nextCursor != null);
      setState(() {
        _items.addAll(freshItems);
        _itemIds.addAll(freshItems.map((item) => item.id));
        _nextCursor = stalled ? null : result.nextCursor;
        _paginationBlocked = stalled;
        _loading = false;
      });
      _scheduleViewportFill();
    } on ApiException catch (e) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() {
        _loading = false;
        _paginationBlocked = true;
      });
      showToast(context, '${e.userMessage}，下拉刷新后可重试', kind: ToastKind.error);
    } catch (_) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() {
        _loading = false;
        _paginationBlocked = true;
      });
      showToast(context, '加载更多失败，下拉刷新后可重试', kind: ToastKind.error);
    }
  }

  Future<void> _refresh() async {
    final state = context.read<ServerState>();
    if (state.status != ConnectionStatus.connected) {
      await state.tryLocalhost();
      return;
    }
    // 关键：先把滚动位置重置到顶部，再重新拉数据。
    // 不这么做会有一串连锁问题：_reload 会把 _items 清空只留第一页，
    // 但 ScrollController 还停在原先的高位（比如 5000px）。列表变短后
    // Flutter 把位置钳到新的 maxScrollExtent（就贴到新短列表的底部了），
    // 立刻触发 _onScroll 的"距底 200px 加载下一页"，然后一路自动分页 —
    // 表现就是"刷新完滚到了底部"或"图片不全滑一下才出来"。
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    final prefs = context.read<DisplayPrefs>();
    await _reload(prefs);
  }

  // ── 文件夹导航 ──

  void _enterFolder(FolderItem folder) async {
    if (folder.hasPassword && !_unlockedFolderIds.contains(folder.id)) {
      final ok = await _showUnlockDialog(folder);
      if (!ok) return;
      _unlockedFolderIds.add(folder.id);
    }
    _folderPath.add((id: folder.id, name: folder.name));
    _currentFolderId = folder.id;
    _selected.clear();
    _selecting = false;
    _breadcrumbExpanded = false;
    _syncFolderDepth();
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _reload(context.read<DisplayPrefs>());
  }

  void _navigateToPathIndex(int index) {
    if (index < 0) {
      _folderPath.clear();
      _currentFolderId = null;
    } else {
      _currentFolderId = _folderPath[index].id;
      _folderPath.removeRange(index + 1, _folderPath.length);
    }
    _selected.clear();
    _selecting = false;
    _breadcrumbExpanded = false;
    _syncFolderDepth();
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _reload(context.read<DisplayPrefs>());
  }

  void _goBack() {
    if (_folderPath.isEmpty) return;
    _folderPath.removeLast();
    _currentFolderId = _folderPath.isEmpty ? null : _folderPath.last.id;
    _selected.clear();
    _selecting = false;
    _breadcrumbExpanded = false;
    _syncFolderDepth();
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _reload(context.read<DisplayPrefs>());
  }

  void _syncFolderDepth() {
    if (widget.shell != null) {
      widget.shell!.updateFolderDepth(_folderPath.length, onGoBack: _goBack);
    }
  }

  /// 系统返回手势/返回键的唯一处理入口。
  /// 顺序必须和 PopScope.canPop 枚举的状态一一对应，见那里的注释。
  void _handleBack() {
    // 查看器有自己的 PopScope，同一次 pop 两个都会收到回调。
    // 这里必须**只拦截、不处理** —— 让查看器自己走关闭动画。
    // 但这个分支不能删：删了会继续往下落到"回上一级"，
    // 变成"在查看器里按返回，直接退出了当前文件夹"。
    if (_viewerIndex != null) return;
    if (_selecting) {
      _exitSelection();
      return;
    }
    if (_currentFolderId != null) {
      _goBack();
      return;
    }
    // canPop 为 true 时系统已经自己 pop 了，走不到这里
  }

  // ── 文件夹 CRUD ──

  Future<void> _createFolder() async {
    if (_service == null) return;
    final c = context.colors;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text(
            '新建文件夹',
            style: TextStyle(
              color: c.onSurface,
              fontSize: AppType.mdPlus,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.md),
            decoration: InputDecoration(
              hintText: '文件夹名称',
              hintStyle: TextStyle(color: c.onMuted),
              filled: true,
              fillColor: c.surface2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.chip),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: c.onSurfaceVariant)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(
                '创建',
                style: TextStyle(color: c.brand, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
    if (name != null && name.isNotEmpty && mounted) {
      try {
        await _service!.createFolder(name: name, parentId: _currentFolderId);
        if (mounted) showToast(context, '已创建「$name」', kind: ToastKind.success);
        _refresh();
      } catch (e) {
        if (mounted) {
          showToast(context, '创建失败: ${errorText(e)}', kind: ToastKind.error);
        }
      }
    }
  }

  void _showFolderActions(FolderItem folder) {
    final c = context.colors;
    showModalBottomSheet(
      context: context,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: c.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(Icons.edit, color: c.onSurfaceVariant),
              title: Text('重命名', style: TextStyle(color: c.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _renameFolder(folder);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.drive_file_move_outlined,
                color: c.onSurfaceVariant,
              ),
              title: Text('移动文件夹', style: TextStyle(color: c.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _moveFolder(folder);
              },
            ),
            ListTile(
              leading: Icon(
                folder.hasPassword ? Icons.lock_open : Icons.lock_outline,
                color: c.onSurfaceVariant,
              ),
              title: Text(
                folder.hasPassword ? '修改/取消密码' : '设置密码',
                style: TextStyle(color: c.onSurface),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showSetPasswordDialog(folder);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: c.error),
              title: Text('删除文件夹', style: TextStyle(color: c.error)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteFolderConfirm(folder);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _moveFolder(FolderItem folder) async {
    if (_service == null) return;
    final targetId = await _showFolderPicker(excludeFolderId: folder.id);
    if (targetId == null || !mounted) return;
    try {
      await _service!.moveFolder(
        folder.id,
        parentId: targetId.isEmpty ? null : targetId,
      );
      if (mounted) {
        showToast(context, '已移动文件夹「${folder.name}」', kind: ToastKind.success);
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        showToast(context, '移动失败: ${errorText(e)}', kind: ToastKind.error);
      }
    }
  }

  Future<void> _renameFolder(FolderItem folder) async {
    if (_service == null) return;
    final c = context.colors;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: folder.name);
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text(
            '重命名',
            style: TextStyle(
              color: c.onSurface,
              fontSize: AppType.mdPlus,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.md),
            decoration: InputDecoration(
              hintText: '文件夹名称',
              hintStyle: TextStyle(color: c.onMuted),
              filled: true,
              fillColor: c.surface2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.chip),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: c.onSurfaceVariant)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(
                '确定',
                style: TextStyle(color: c.brand, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
    if (name != null && name.isNotEmpty && mounted) {
      try {
        await _service!.renameFolder(folder.id, name);
        if (mounted) showToast(context, '已重命名', kind: ToastKind.success);
        _refresh();
      } catch (e) {
        if (mounted) {
          showToast(context, '重命名失败: ${errorText(e)}', kind: ToastKind.error);
        }
      }
    }
  }

  Future<void> _deleteFolderConfirm(FolderItem folder) async {
    if (_service == null) return;
    final confirmed = await appConfirmDialog(
      context,
      title: '删除文件夹',
      message: '确定删除文件夹「${folder.name}」？\n文件夹必须为空才能删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await _service!.deleteFolder(folder.id);
      if (mounted) showToast(context, '已删除文件夹', kind: ToastKind.success);
      _refresh();
    } catch (e) {
      if (mounted) {
        showToast(context, '删除失败: ${errorText(e)}', kind: ToastKind.error);
      }
    }
  }

  Future<bool> _showUnlockDialog(FolderItem folder) async {
    final c = context.colors;
    final ctrl = TextEditingController();
    String? error;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: c.surface,
          title: Row(
            children: [
              Icon(Icons.lock_rounded, size: 20, color: c.onMuted),
              const SizedBox(width: 8),
              Text('输入密码', style: TextStyle(
                color: c.onSurface, fontSize: AppType.mdPlus,
                fontWeight: FontWeight.w600,
              )),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(folder.name, style: TextStyle(
                color: c.onMuted, fontSize: AppType.sm,
              )),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '文件夹密码',
                  errorText: error,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onSubmitted: (_) async {
                  if (ctrl.text.isEmpty) return;
                  final ok = await _service!.unlockFolder(folder.id, ctrl.text);
                  if (ok) {
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } else {
                    setDialogState(() => error = '密码错误');
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: c.onMuted)),
            ),
            TextButton(
              onPressed: () async {
                if (ctrl.text.isEmpty) return;
                final ok = await _service!.unlockFolder(folder.id, ctrl.text);
                if (ok) {
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } else {
                  setDialogState(() => error = '密码错误');
                }
              },
              child: Text('确认', style: TextStyle(color: c.brand)),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return result == true;
  }

  Future<void> _showSetPasswordDialog(FolderItem folder) async {
    if (_service == null) return;
    final c = context.colors;

    if (folder.hasPassword) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: c.bg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              ListTile(
                leading: Icon(Icons.lock_reset, color: c.onSurfaceVariant),
                title: Text('修改密码', style: TextStyle(color: c.onSurface)),
                onTap: () => Navigator.pop(ctx, 'change'),
              ),
              ListTile(
                leading: Icon(Icons.lock_open, color: c.error),
                title: Text('取消密码', style: TextStyle(color: c.error)),
                onTap: () => Navigator.pop(ctx, 'clear'),
              ),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'clear') {
        try {
          await _service!.setFolderPassword(folder.id, null);
          _unlockedFolderIds.remove(folder.id);
          if (mounted) showToast(context, '已取消密码', kind: ToastKind.success);
          _refresh();
        } catch (e) {
          if (mounted) showToast(context, errorText(e), kind: ToastKind.error);
        }
        return;
      }
    }

    final pwCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: c.surface,
          title: Text(
            folder.hasPassword ? '修改密码' : '设置密码',
            style: TextStyle(
              color: c.onSurface, fontSize: AppType.mdPlus,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pwCtrl,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '输入密码',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: '确认密码',
                  errorText: error,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: c.onMuted)),
            ),
            TextButton(
              onPressed: () {
                if (pwCtrl.text.isEmpty) {
                  setDialogState(() => error = '请输入密码');
                  return;
                }
                if (pwCtrl.text != confirmCtrl.text) {
                  setDialogState(() => error = '两次密码不一致');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text('确认', style: TextStyle(color: c.brand)),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) {
      pwCtrl.dispose();
      confirmCtrl.dispose();
      return;
    }
    try {
      await _service!.setFolderPassword(folder.id, pwCtrl.text);
      if (mounted) showToast(context, '密码已设置', kind: ToastKind.success);
      _refresh();
    } catch (e) {
      if (mounted) showToast(context, errorText(e), kind: ToastKind.error);
    }
    pwCtrl.dispose();
    confirmCtrl.dispose();
  }

  Future<void> _moveSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final targetId = await _showFolderPicker();
    if (targetId == null || !mounted) return;
    try {
      await _service!.batchMove(
        _selected.toList(),
        folderId: targetId.isEmpty ? null : targetId,
      );
      if (!mounted) return;
      showToast(
        context,
        '已移动 ${_selected.length} 个文件',
        kind: ToastKind.success,
      );
      _exitSelection();
      _refresh();
    } catch (e) {
      if (mounted) {
        showToast(context, '移动失败: ${errorText(e)}', kind: ToastKind.error);
      }
    }
  }

  Future<String?> _showFolderPicker({String? excludeFolderId}) async {
    if (_service == null) return null;
    final c = context.colors;
    final picker = FolderPickerSheet(
      service: _service!,
      currentFolderId: _currentFolderId,
      excludeFolderId: excludeFolderId,
    );
    if (_isDesktop) {
      return showDialog<String>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: c.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sheet),
          ),
          child: SizedBox(width: 380, height: 480, child: picker),
        ),
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (ctx, _) => picker,
      ),
    );
  }

  // ── 多选 ──

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(id);
      }
    });
    _syncSelection();
  }

  bool get _allSelected =>
      _items.isNotEmpty && _selected.length == _items.length;

  bool get _selectedAllFavorite {
    if (_selected.isEmpty) return false;
    final sel = _items.where((m) => _selected.contains(m.id));
    return sel.isNotEmpty && sel.every((m) => m.isFavorite);
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(_items.map((e) => e.id));
      }
    });
    _syncSelection();
  }

  void _toggleGroupSelect(GalleryGroup group) {
    setState(() {
      final groupIds = group.items.map((e) => e.id).toSet();
      if (groupIds.every(_selected.contains)) {
        _selected.removeAll(groupIds);
      } else {
        _selected.addAll(groupIds);
      }
    });
    _syncSelection();
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    _syncSelection();
  }

  // ── 滑选（多选模式下按住拖动，命中判定见 drag_select.dart）──

  bool _sweepStart(int index) {
    if (index < 0 || index >= _items.length) return false;
    _sweepAnchor = index;
    _sweepAdding = !_selected.contains(_items[index].id);
    _sweepBaseline = Set<String>.from(_selected);
    setState(() {
      if (_sweepAdding) {
        _selected.add(_items[index].id);
      } else {
        _selected.remove(_items[index].id);
      }
    });
    return true;
  }

  void _sweepTo(int index) {
    final anchor = _sweepAnchor;
    if (anchor == null) return;
    if (index < 0 || index >= _items.length) return;
    final lo = anchor < index ? anchor : index;
    final hi = anchor < index ? index : anchor;
    setState(() {
      // 区间外还原到按下前的状态，区间内整段应用 —— 回拖能正确取消
      for (var i = 0; i < _items.length; i++) {
        final id = _items[i].id;
        final on = (i >= lo && i <= hi)
            ? _sweepAdding
            : _sweepBaseline.contains(id);
        if (on) {
          _selected.add(id);
        } else {
          _selected.remove(id);
        }
      }
    });
  }

  void _sweepEnd() {
    _sweepAnchor = null;
    _sweepBaseline = {};
    if (_selected.isEmpty && _selecting) setState(() => _selecting = false);
    _syncSelection();
  }

  Future<void> _favoriteSelected() async {
    if (_selected.isEmpty || _service == null) return;
    // 若选中项全部已收藏 → 取消收藏；否则 → 全部收藏
    final selItems = _items.where((m) => _selected.contains(m.id)).toList();
    final allFav = selItems.isNotEmpty && selItems.every((m) => m.isFavorite);
    final target = !allFav;
    try {
      await _service!.batchFavorite(_selected.toList(), favorite: target);
      // 本地同步收藏态
      for (var i = 0; i < _items.length; i++) {
        if (_selected.contains(_items[i].id)) {
          _items[i] = _items[i].copyWith(favorite: target ? 1 : 0);
        }
      }
      if (mounted) {
        showToast(
          context,
          target ? '已收藏 ${_selected.length} 个' : '已取消收藏 ${_selected.length} 个',
          kind: ToastKind.success,
        );
        _exitSelection();
        _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) {
        showToast(context, '操作失败: ${e.displayMessage}', kind: ToastKind.error);
      }
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final confirmed = await appConfirmDialog(
      context,
      title: '删除',
      message: '确定删除选中的 ${_selected.length} 个文件？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final count = _selected.length;
    try {
      await _service!.batchDelete(_selected.toList());
      if (mounted) {
        showToast(context, '已删除 $count 个文件', kind: ToastKind.success);
      }
      _exitSelection();
      await _refresh();
      HashSync.instance.syncFromServer();
    } on ApiException catch (e) {
      if (mounted) {
        showToast(context, '删除失败: ${e.displayMessage}', kind: ToastKind.error);
      }
    } catch (_) {
      if (mounted) showToast(context, '删除失败', kind: ToastKind.error);
    }
  }

  Future<void> _downloadSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final count = _selected.length;
    final c = context.colors;
    final choice = await showDialog<_DownloadMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '下载 $count 个文件',
          style: TextStyle(
            color: c.onSurface,
            fontSize: AppType.mdPlus,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          '请选择下载方式',
          style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.md),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DownloadMode.direct),
            child: Text('逐个下载', style: TextStyle(color: c.brand)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DownloadMode.zip),
            child: Text(
              '打包下载',
              style: TextStyle(color: c.brand, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == _DownloadMode.zip) {
      try {
        final dir = await DownloadService.instance.pickSaveDir();
        if (dir == null || !mounted) return; // 用户取消
        // 已存在同名 zip 就换个名，别把用户上次下的包盖掉
        final savePath = uniqueFile(dir.path, 'igallery.zip').path;
        await _service!.downloadBatch(_selected.toList(), savePath: savePath);
        if (mounted) {
          final name = savePath.split(Platform.pathSeparator).last;
          showToast(context, '已下载为 $name', kind: ToastKind.success);
          _exitSelection();
        }
      } on ApiException catch (e) {
        if (mounted) {
          showToast(
            context,
            '下载失败: ${e.displayMessage}',
            kind: ToastKind.error,
          );
        }
      } catch (_) {
        if (mounted) showToast(context, '下载失败', kind: ToastKind.error);
      }
    } else {
      final dir = await DownloadService.instance.pickSaveDir();
      if (dir == null || !mounted) return; // 用户取消
      setState(() {
        _downloading = true;
        _downloadCompleted = 0;
        _downloadTotal = count;
      });
      try {
        final report = await _service!.downloadIndividual(
          _selected.toList(),
          saveDir: dir.path,
          onProgress: (c, t) {
            if (mounted) {
              setState(() {
                _downloadCompleted = c;
                _downloadTotal = t;
              });
            }
          },
        );
        if (mounted) {
          // 如实汇报成功/失败数，不再一律"已下载 N 个"
          if (report.failed == 0) {
            showToast(
              context,
              isMobile
                  ? '已保存 ${report.ok} 个到系统相册 iGallery'
                  : '已下载 ${report.ok} 个文件',
              kind: ToastKind.success,
            );
          } else if (report.ok == 0) {
            showToast(
              context,
              '下载失败（${report.failed} 个）',
              kind: ToastKind.error,
            );
          } else {
            showToast(
              context,
              '已下载 ${report.ok} 个，${report.failed} 个失败',
              kind: ToastKind.error,
            );
          }
          if (report.ok > 0) _exitSelection();
        }
      } on ApiException catch (e) {
        if (mounted) {
          showToast(
            context,
            '下载失败: ${e.displayMessage}',
            kind: ToastKind.error,
          );
        }
      } catch (_) {
        if (mounted) showToast(context, '下载失败', kind: ToastKind.error);
      } finally {
        if (mounted) setState(() => _downloading = false);
      }
    }
  }

  // ── 上传 ──

  Future<void> _pickAndUpload({bool fromFiles = false}) async {
    if (_service == null) return;
    if (UploadManager.instance.uploading) {
      showToast(context, '正在上传中，请稍候', kind: ToastKind.info);
      return;
    }
    final List<PendingUpload> files;
    if (_isDesktop || fromFiles) {
      // 桌面 / 移动端"从文件":任意类型,交由服务端判断能否入库
      final picked = await FilePicker.pickFiles(type: FileType.any);
      files = (picked?.files ?? [])
          .where((f) => f.path != null)
          .map((f) => PendingUpload(File(f.path!)))
          .toList();
    } else {
      // 移动端"从相册":photo_manager 拿到 AssetEntity.createDateTime
      final result = await Navigator.of(context).push<List<PendingUpload>>(
        MaterialPageRoute(builder: (_) => const MediaPickerPage()),
      );
      files = result ?? [];
    }
    if (files.isEmpty || !mounted) return;

    setState(() => _resolving = true);

    final serverUrl = context.read<ServerState>().baseUrl;
    final result = await UploadManager.instance.enqueue(
      _service!,
      files,
      folderId: _currentFolderId,
      serverUrl: serverUrl,
    );
    if (mounted && _resolving) setState(() => _resolving = false);

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
      _refresh();
    }
  }

  Future<void> _showUploadSourceSheet() async {
    if (_isDesktop) {
      await _pickAndUpload(fromFiles: true);
      return;
    }
    final source = await showUploadSourcePicker(context);
    if (!mounted || source == null) return;
    await _pickAndUpload(fromFiles: source == UploadSource.files);
  }

  void _openUploadHistory() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const UploadHistoryPage()));
  }

  // ── 桌面右键菜单 ──

  void _showGridContextMenu(Offset pos, AppColors c) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      color: c.surface,
      items: [
        PopupMenuItem(
          value: 'new_folder',
          child: Row(
            children: [
              Icon(
                Icons.create_new_folder_outlined,
                size: 18,
                color: c.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                '新建文件夹',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'refresh',
          child: Row(
            children: [
              Icon(Icons.refresh, size: 18, color: c.onSurfaceVariant),
              const SizedBox(width: 12),
              Text(
                '刷新',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'upload',
          child: Row(
            children: [
              Icon(Icons.upload_rounded, size: 18, color: c.onSurfaceVariant),
              const SizedBox(width: 12),
              Text(
                '上传',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
              ),
            ],
          ),
        ),
      ],
    ).then((v) {
      if (v == 'new_folder') _createFolder();
      if (v == 'refresh') _refresh();
      if (v == 'upload') _showUploadSourceSheet();
    });
  }

  void _showItemContextMenu(Offset pos, MediaItem item, AppColors c) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      color: c.surface,
      items: [
        PopupMenuItem(
          value: 'open',
          child: Row(
            children: [
              Icon(Icons.open_in_new, size: 18, color: c.onSurfaceVariant),
              const SizedBox(width: 12),
              Text(
                '打开',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'favorite',
          child: Row(
            children: [
              Icon(
                item.isFavorite ? Icons.favorite : Icons.favorite_border,
                size: 18,
                color: item.isFavorite ? c.onSurface : c.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                item.isFavorite ? '取消收藏' : '收藏',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'move',
          child: Row(
            children: [
              Icon(
                Icons.drive_file_move_outlined,
                size: 18,
                color: c.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                '移动',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: c.error),
              const SizedBox(width: 12),
              Text(
                '删除',
                style: TextStyle(color: c.error, fontSize: AppType.sm),
              ),
            ],
          ),
        ),
      ],
    ).then((v) async {
      if (!mounted) return;
      if (v == 'open') {
        _openViewer(_items.indexOf(item));
      } else if (v == 'favorite') {
        try {
          final target = !item.isFavorite;
          await _service!.batchFavorite([item.id], favorite: target);
          final idx = _items.indexWhere((m) => m.id == item.id);
          if (idx >= 0) {
            _items[idx] = _items[idx].copyWith(favorite: target ? 1 : 0);
          }
          if (mounted) {
            setState(() {});
            showToast(
              context,
              target ? '已收藏' : '已取消收藏',
              kind: ToastKind.success,
            );
          }
        } on ApiException catch (e) {
          if (mounted) {
            showToast(
              context,
              '操作失败: ${e.displayMessage}',
              kind: ToastKind.error,
            );
          }
        }
      } else if (v == 'move') {
        _selected.clear();
        _selected.add(item.id);
        _selecting = true;
        _moveSelected();
      } else if (v == 'delete') {
        final ok = await appConfirmDialog(
          context,
          title: '删除',
          message: '确定删除 ${item.filename}？',
          confirmLabel: '删除',
          destructive: true,
        );
        if (!ok || !mounted) return;
        try {
          await _service!.delete(item.id);
          if (mounted) {
            showToast(context, '已删除 ${item.filename}', kind: ToastKind.success);
          }
          _refresh();
          HashSync.instance.syncFromServer();
        } on ApiException catch (e) {
          if (mounted) {
            showToast(
              context,
              '删除失败: ${e.displayMessage}',
              kind: ToastKind.error,
            );
          }
        } catch (_) {
          if (mounted) showToast(context, '删除失败', kind: ToastKind.error);
        }
      }
    });
  }

  // ── 导航 ──

  void _openProfile() {
    if (_embedded) {
      widget.shell!.switchToTab(3);
    } else if (_isDesktop) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const MobileProfilePage()));
    }
  }

  void _openSortSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SortSettingsSheet(
        onChanged: () => _onPrefsChanged(context.read<DisplayPrefs>()),
      ),
    );
  }

  void _openFilterSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FilterSettingsSheet(
        onChanged: () => _onPrefsChanged(context.read<DisplayPrefs>()),
      ),
    );
  }

  void _openDisplaySettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const DisplaySettingsSheet(),
    );
  }

  // ── build ──

  bool get _embedded => widget.shell != null;

  void _openViewer(int index) {
    if (_embedded && _service != null) {
      widget.shell!.openViewer(
        items: _items,
        index: index,
        service: _service!,
        onDeleted: (id) => setState(() {
          _items.removeWhere((m) => m.id == id);
          _itemIds.remove(id);
        }),
      );
    } else {
      setState(() => _viewerIndex = index);
    }
  }

  void _syncSelection() {
    if (!_embedded) return;
    widget.shell!.updateSelection(
      sourceTab: 0,
      selecting: _selecting,
      selectedIds: _selected,
      allSelected: _allSelected,
      allFavorite: _selectedAllFavorite,
      onToggleSelectAll: _toggleSelectAll,
      onFavorite: _favoriteSelected,
      onMove: _moveSelected,
      onDownload: _downloadSelected,
      onDelete: _deleteSelected,
      onExitSelection: _exitSelection,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<ServerState>();
    final prefs = context.watch<DisplayPrefs>();

    // 移动端嵌入 shell：只渲染内容区域，不包 Scaffold
    if (_embedded) return _buildContent(c, state, prefs);

    // 桌面端：完整 Scaffold（保持原有行为）
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: c.bg,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: c.bg,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: PopScope(
        canPop: _viewerIndex == null && !_selecting && _currentFolderId == null,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleBack();
        },
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: c.bg,
          drawer: _isDesktop ? _buildLeftDrawer(c) : null,
          floatingActionButton: _showScrollTop && _viewerIndex == null
              ? FloatingActionButton.small(
                  onPressed: () {
                    _scrollCtrl.animateTo(
                      0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                  },
                  backgroundColor: c.surface2,
                  foregroundColor: c.onSurface,
                  elevation: 0,
                  highlightElevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    side: BorderSide(color: c.outline, width: 0.5),
                  ),
                  child: Icon(Icons.keyboard_arrow_up, color: c.onSurface),
                )
              : null,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _buildContent(c, state, prefs),
              if (_viewerIndex != null && _service != null)
                MediaViewer(
                  items: _items,
                  initialIndex: _viewerIndex!,
                  service: _service!,
                  onClose: () => setState(() => _viewerIndex = null),
                  onDeleted: (id) {
                    setState(() {
                      _items.removeWhere((m) => m.id == id);
                      _itemIds.remove(id);
                      if (_items.isEmpty) _viewerIndex = null;
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

  Widget _buildContent(AppColors c, ServerState state, DisplayPrefs prefs) {
    return Column(
      children: [
        _buildToolbar(c, state, prefs),
        if (!_embedded) UploadBar(onTap: _openUploadHistory),
        if (_downloading) _buildDownloadBar(c),
        Expanded(child: _buildBody(c, state, prefs)),
      ],
    );
  }

  Widget _buildLeftDrawer(AppColors c) {
    return Drawer(
      width: 360,
      backgroundColor: c.bg,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.outline, width: 0.5),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    '设置',
                    style: TextStyle(
                      color: c.onSurface,
                      fontSize: AppType.mdPlus,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.close,
                      size: AppIconSize.lg,
                      color: c.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: c.outline),
            const Expanded(child: ProfileContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(AppColors c, ServerState state, DisplayPrefs prefs) {
    final connected = state.status == ConnectionStatus.connected;

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outline, width: 0.5)),
      ),
      child: Row(
        children: [
          if (_selecting)
            IconButton(
              onPressed: _exitSelection,
              icon: Icon(
                Icons.close_rounded,
                size: AppIconSize.lg,
                color: c.onSurface,
              ),
              tooltip: '退出多选',
            )
          else if (_embedded)
            _buildServerLabel(c, state)
          else
            _buildAvatar(c, state),
          if (_selecting) ...[
            Text(
              '已选 ${_selected.length}',
              style: TextStyle(
                color: c.onSurface,
                fontSize: AppType.sm,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
          ] else ...[
            if (!connected && !_embedded)
              Text(
                state.status == ConnectionStatus.needAuth ? '需令牌' : '未连接',
                style: TextStyle(
                  color: state.status == ConnectionStatus.needAuth
                      ? c.warn
                      : c.onMuted,
                  fontSize: AppType.xs,
                ),
              ),
            if (!_embedded &&
                connected &&
                _currentFolderId == null &&
                _total > 0)
              Text(
                '$_total',
                style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
              ),
            const Spacer(),
          ],

          // 选择态右侧按钮：桌面端在顶栏显示全部操作，移动端操作在 shell 底部条
          if (_selecting && _isDesktop) ...[
            IconButton(
              onPressed: _toggleSelectAll,
              icon: Icon(
                _allSelected ? Icons.deselect : Icons.select_all,
                size: AppIconSize.lg,
                color: _allSelected ? c.brand : c.onSurfaceVariant,
              ),
              tooltip: _allSelected ? '取消全选' : '全选',
            ),
            IconButton(
              onPressed: _favoriteSelected,
              icon: Icon(
                _selectedAllFavorite ? Icons.favorite : Icons.favorite_border,
                size: AppIconSize.lg,
                color: _selectedAllFavorite ? c.onSurface : c.onSurfaceVariant,
              ),
              tooltip: _selectedAllFavorite ? '取消收藏' : '收藏',
            ),
            IconButton(
              onPressed: _moveSelected,
              icon: Icon(
                Icons.drive_file_move_outlined,
                size: AppIconSize.lg,
                color: c.onSurfaceVariant,
              ),
              tooltip: '移动',
            ),
            IconButton(
              onPressed: _downloadSelected,
              icon: Icon(
                Icons.file_download_outlined,
                size: AppIconSize.lg,
                color: c.onSurfaceVariant,
              ),
              tooltip: '下载',
            ),
            IconButton(
              onPressed: _deleteSelected,
              icon: Icon(
                Icons.delete_outline,
                size: AppIconSize.lg,
                color: c.error,
              ),
              tooltip: '删除',
            ),
          ] else if (!_selecting) ...[
            if (_isDesktop && connected && _items.isNotEmpty)
              IconButton(
                onPressed: () {
                  setState(() => _selecting = true);
                  _syncSelection();
                },
                icon: Icon(
                  Icons.library_add_check_outlined,
                  size: AppIconSize.lg,
                  color: c.onSurfaceVariant,
                ),
                tooltip: '多选',
              ),
            if (connected)
              IconButton(
                onPressed: _openSortSettings,
                icon: Icon(
                  Icons.swap_vert_rounded,
                  size: AppIconSize.lg,
                  color: c.onSurfaceVariant,
                ),
                tooltip: '排序',
              ),
            if (connected)
              IconButton(
                onPressed: _openFilterSettings,
                icon: Stack(
                  children: [
                    Icon(
                      Icons.filter_alt_outlined,
                      size: AppIconSize.lg,
                      color: c.onSurfaceVariant,
                    ),
                    if (prefs.hasActiveFilter)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.brand,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
                tooltip: '筛选',
              ),
            if (connected)
              IconButton(
                onPressed: _openDisplaySettings,
                icon: Icon(
                  Icons.view_module_outlined,
                  size: AppIconSize.lg,
                  color: c.onSurfaceVariant,
                ),
                tooltip: '展示设置',
              ),
            if (connected && widget.mode == GalleryMode.albums)
              IconButton(
                onPressed: _createFolder,
                icon: Icon(
                  Icons.create_new_folder_outlined,
                  size: AppIconSize.lg,
                  color: c.onSurfaceVariant,
                ),
                tooltip: '新建文件夹',
              ),
            if (connected && widget.mode == GalleryMode.albums)
              IconButton(
                onPressed: _embedded
                    ? () => widget.shell!.pickAndUpload(
                        folderId: _currentFolderId,
                      )
                    : _showUploadSourceSheet,
                icon: Icon(
                  Icons.upload_rounded,
                  size: AppIconSize.lg,
                  color: c.onSurfaceVariant,
                ),
                tooltip: '上传',
              ),
          ],
        ],
      ),
    );
  }

  // 左上角头像进入全局设置；移动端首字母圆点同时表达连接状态。
  Widget _buildAvatar(AppColors c, ServerState state) {
    final name = state.active?.name.trim() ?? '';
    return IconButton(
      onPressed: _openProfile,
      tooltip: name.isEmpty ? '设置' : '$name · 设置',
      icon: Icon(
        Icons.person_outline,
        size: AppIconSize.lg,
        color: c.onSurfaceVariant,
      ),
    );
  }

  Widget _buildServerLabel(AppColors c, ServerState state) {
    final connected = state.status == ConnectionStatus.connected;
    final needAuth = state.status == ConnectionStatus.needAuth;
    final name = state.active?.name.trim() ?? '';
    final dotColor = connected ? c.ok : (needAuth ? c.warn : c.error);
    final initial = name.isEmpty ? '' : name.characters.first.toUpperCase();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: dotColor.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(color: dotColor, width: 1.5),
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              color: dotColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBreadcrumbs(AppColors c) {
    final style = TextStyle(
      color: c.onSurfaceVariant,
      fontSize: AppType.sm,
      height: 1.3,
    );
    final sepStyle = style.copyWith(color: c.onMuted);
    final depth = _folderPath.length;
    final last = depth - 1;
    final needCollapse = depth > 3 && !_breadcrumbExpanded;

    final segments = <InlineSpan>[];

    void addSep() {
      segments.add(TextSpan(text: ' / ', style: sepStyle));
    }

    void addTap(String label, VoidCallback onTap, {bool bold = false}) {
      segments.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: bold ? style.copyWith(
              color: c.onSurface, fontWeight: FontWeight.w600,
            ) : style,
          ),
        ),
      ));
    }

    addTap('首页', () => _navigateToPathIndex(-1));

    if (needCollapse) {
      addSep();
      segments.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => setState(() => _breadcrumbExpanded = true),
          behavior: HitTestBehavior.opaque,
          child: Text('...', style: style.copyWith(fontWeight: FontWeight.w600)),
        ),
      ));
      addSep();
      addTap(
        _folderPath[last - 1].name,
        () => _navigateToPathIndex(last - 1),
      );
    } else {
      for (var i = 0; i < depth - 1; i++) {
        addSep();
        addTap(_folderPath[i].name, () => _navigateToPathIndex(i));
      }
    }
    addSep();
    segments.add(TextSpan(
      text: _folderPath[last].name,
      style: style.copyWith(
        color: c.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ));

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.sm,
      ),
      child: GestureDetector(
        onTap: _breadcrumbExpanded
            ? () => setState(() => _breadcrumbExpanded = false)
            : null,
        child: Text.rich(
          TextSpan(children: segments),
          maxLines: _breadcrumbExpanded ? 5 : 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildDownloadBar(AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: c.brand,
              value: _downloadTotal > 0
                  ? _downloadCompleted / _downloadTotal
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '下载中 $_downloadCompleted / $_downloadTotal',
            style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppColors c, ServerState state, DisplayPrefs prefs) {
    if (state.status != ConnectionStatus.connected) {
      final needAuth = state.status == ConnectionStatus.needAuth;
      return AppEmptyState(
        icon: needAuth ? Icons.vpn_key_outlined : Icons.wifi_off,
        message: needAuth ? '服务器需要访问令牌' : '未连接到服务器',
        action: AppButton(
          label: needAuth ? '输入令牌' : '去连接',
          onTap: _openProfile,
        ),
      );
    }

    if (_items.isEmpty && !_loading && _folders.isEmpty) {
      return AppScrollbar(
        controller: _scrollCtrl,
        child: RefreshIndicator(
          onRefresh: _refresh,
          color: c.brand,
          child: ListView(
            controller: _scrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (_folderPath.isNotEmpty && widget.mode == GalleryMode.albums)
                _buildBreadcrumbs(c),
              const SizedBox(height: 120),
              AppEmptyState(
                icon: Icons.photo_library_outlined,
                message: prefs.hasActiveFilter ? '没有匹配的项目' : '还没有照片',
                action: prefs.hasActiveFilter
                    ? AppButton(
                        label: '清除筛选',
                        onTap: () {
                          prefs.clearFilters();
                          _onPrefsChanged(prefs);
                        },
                        primary: false,
                      )
                    : widget.mode == GalleryMode.albums
                    ? AppButton(
                        label: '上传照片',
                        icon: Icons.add,
                        onTap: _embedded
                            ? () => widget.shell!.pickAndUpload(
                                folderId: _currentFolderId,
                              )
                            : _showUploadSourceSheet,
                      )
                    : null,
              ),
            ],
          ),
        ),
      );
    }

    final groups = buildGroups(_items, prefs);
    // 滑选要全局下标（groups 是 _items 的有序分区）
    final indexOfId = <String, int>{
      for (var i = 0; i < _items.length; i++) _items[i].id: i,
    };

    return GestureDetector(
      // 到这里已经过了上面的未连接早退，必然是 connected
      onSecondaryTapDown: _isDesktop
          ? (d) => _showGridContextMenu(d.globalPosition, c)
          : null,
      child: Listener(
        // 自己数指针，而不是靠 ScaleGestureRecognizer：后者要和 ScrollView 的
        // VerticalDrag 抢竞技场，drag 经常先赢 —— 体感就是"双指缩放变成了上下滚动"。
        // 数到 2 指就把 physics 换成 NeverScrollable，scroll 直接退出竞争。
        onPointerDown: (e) {
          _activePointers.add(e.pointer);
          _pointerPos[e.pointer] = e.position;
          if (_activePointers.length == 2) {
            _pinchStartDist = _pointerDistance();
            setState(() => _pinchScale = 1.0);
          }
        },
        onPointerMove: (e) {
          _pointerPos[e.pointer] = e.position;
          if (_activePointers.length >= 2 && _pinchStartDist > 0) {
            final d = _pointerDistance();
            if (d > 0) setState(() => _pinchScale = d / _pinchStartDist);
          }
        },
        onPointerUp: (e) => _endPinch(e.pointer, prefs),
        onPointerCancel: (e) => _endPinch(e.pointer, prefs),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
          ),
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: c.brand,
            notificationPredicate: (_) => true,
            child: DragSelectDetector(
              enabled: _selecting,
              onStart: _sweepStart,
              onEnter: _sweepTo,
              onEnd: _sweepEnd,
              scrollController: _scrollCtrl,
              child: LayoutBuilder(
                builder: (ctx, box) {
                  // 格子高 = 列宽 + 标签高。用实测列宽算，不写死 childAspectRatio ——
                  // 写死的比例在列宽或标签行数变化时会让标签放不下（RenderFlex overflowed）。
                  const gridPad = 16.0, crossGap = 14.0;
                  final usable = box.maxWidth - gridPad * 2;
                  final mediaCol =
                      (usable - crossGap * (prefs.gridColumns - 1)) /
                      prefs.gridColumns;
                  final mediaLabel = labelExtent(prefs);
                  final mediaRatio = mediaCol / (mediaCol + mediaLabel);

                  return _pinchWrap(
                    AppScrollbar(
                      controller: _scrollCtrl,
                      child: CustomScrollView(
                        controller: _scrollCtrl,
                        scrollCacheExtent: const ScrollCacheExtent.pixels(600),
                        physics: _pinching
                            ? const NeverScrollableScrollPhysics()
                            : const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          if (_folderPath.isNotEmpty &&
                              widget.mode == GalleryMode.albums)
                            SliverToBoxAdapter(child: _buildBreadcrumbs(c)),
                          if (_folders.isNotEmpty &&
                              widget.mode == GalleryMode.albums) ...[
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (ctx, i) => _FolderListTile(
                                  key: ValueKey(_folders[i].id),
                                  name: _folders[i].name,
                                  coverId: _folders[i].coverId,
                                  itemCount: _folders[i].itemCount,
                                  hasPassword: _folders[i].hasPassword,
                                  service: _service!,
                                  onTap: () => _enterFolder(_folders[i]),
                                  onLongPress: () =>
                                      _showFolderActions(_folders[i]),
                                ),
                                childCount: _folders.length,
                              ),
                            ),
                            if (_folders.isNotEmpty && _items.isNotEmpty)
                              SliverToBoxAdapter(
                                child: Divider(height: 1, color: c.outline),
                              ),
                          ],
                          // media section
                          for (final group in groups) ...[
                            if (group.label.isNotEmpty)
                              SliverToBoxAdapter(
                                child: GestureDetector(
                                  behavior: _selecting
                                      ? HitTestBehavior.opaque
                                      : HitTestBehavior.deferToChild,
                                  onTap: _selecting
                                      ? () => _toggleGroupSelect(group)
                                      : null,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      32,
                                      16,
                                      14,
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          group.label,
                                          style: TextStyle(
                                            color: c.onSurface,
                                            fontSize: AppType.mdPlus,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -0.3,
                                          ),
                                        ),
                                        const Spacer(),
                                        if (_selecting)
                                          Icon(
                                            group.items.every(
                                                  (m) =>
                                                      _selected.contains(m.id),
                                                )
                                                ? Icons.check_box
                                                : Icons.check_box_outline_blank,
                                            size: AppIconSize.lg,
                                            color:
                                                group.items.every(
                                                  (m) =>
                                                      _selected.contains(m.id),
                                                )
                                                ? c.brand
                                                : c.onMuted,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: prefs.gridColumns,
                                      mainAxisSpacing: 16,
                                      crossAxisSpacing: crossGap,
                                      childAspectRatio: mediaRatio,
                                    ),
                                delegate: SliverChildBuilderDelegate(
                                  (ctx, i) => DragSelectItem(
                                    index: indexOfId[group.items[i].id] ?? -1,
                                    child: MediaThumb(
                                      key: ValueKey(group.items[i].id),
                                      item: group.items[i],
                                      service: _service!,
                                      selected: _selected.contains(
                                        group.items[i].id,
                                      ),
                                      selecting: _selecting,
                                      prefs: prefs,
                                      onTap: () => _openViewer(
                                        _items.indexOf(group.items[i]),
                                      ),
                                      onLongPress: () {
                                        HapticFeedback.mediumImpact();
                                        if (!_selecting) {
                                          setState(() => _selecting = true);
                                        }
                                        _toggleSelect(
                                          group.items[i].id,
                                        ); // _syncSelection called inside
                                      },
                                      onSecondaryTap: _isDesktop && !_selecting
                                          ? (pos) => _showItemContextMenu(
                                              pos,
                                              group.items[i],
                                              c,
                                            )
                                          : null,
                                    ),
                                  ),
                                  childCount: group.items.length,
                                ),
                              ),
                            ),
                          ],
                          if (_loading && _items.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 16,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: c.brand,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '加载中 ${_items.length} / $_total',
                                      style: TextStyle(
                                        color: c.onMuted,
                                        fontSize: AppType.xs,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (_loading && _items.isEmpty)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: AppSpinner(),
                              ),
                            ),
                          if (_paginationBlocked && _items.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpace.lg),
                                child: Center(
                                  child: Text(
                                    '加载已暂停，下拉刷新后重试',
                                    style: TextStyle(
                                      color: c.onMuted,
                                      fontSize: AppType.xs,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else if (!_hasMore && _items.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(AppSpace.lg),
                                child: Center(
                                  child: Text(
                                    '已加载全部 $_total 项',
                                    style: TextStyle(
                                      color: c.onMuted,
                                      fontSize: AppType.xs,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          SliverToBoxAdapter(
                            child: SizedBox(height: _isDesktop ? 24 : 88),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 双指缩放列数 ──

  bool get _pinching => _activePointers.length >= 2;

  /// 缩放中：整棵网格做视觉缩放，**不动列数**。
  /// 过程中就改列数的话每跨一档都要重建整棵网格，手感是一顿一顿的。
  /// 松手后：列数已经换成新的，从 `_settleFrom` 平滑收回 1.0 接上手感。
  ///
  /// 注意**永远**返回 Transform.scale，不做 `if (idle) return child` 的短路：
  /// 那样会让 child 的父节点在缩放前后变化，element 被卸载重建 ——
  /// 滚动位置丢失、所有 CachedThumb 状态清零（缩略图变空白）。
  /// scale == 1.0 时 Transform 本身没有可观测开销。
  Widget _pinchWrap(Widget child) {
    final double scale;
    if (_pinching) {
      scale = _pinchScale.clamp(0.5, 2.0);
    } else if (_settleCtrl.isAnimating) {
      scale =
          _settleFrom +
          (1.0 - _settleFrom) *
              Curves.easeOutCubic.transform(_settleCtrl.value);
    } else {
      scale = 1.0;
    }
    return Transform.scale(
      scale: scale,
      filterQuality: FilterQuality.low,
      child: child,
    );
  }

  double _pointerDistance() {
    final pts = _activePointers
        .map((p) => _pointerPos[p])
        .whereType<Offset>()
        .toList();
    if (pts.length < 2) return 0;
    return (pts[0] - pts[1]).distance;
  }

  void _endPinch(int pointer, DisplayPrefs prefs) {
    final wasPinching = _pinching;
    _activePointers.remove(pointer);
    _pointerPos.remove(pointer);
    // 只在从"2 指"掉到"少于 2 指"的那一刻定档
    if (!wasPinching || _pinching) return;

    final s = _pinchScale;
    final oldCols = prefs.gridColumns;
    _pinchStartDist = 0;
    _pinchScale = 1.0;

    final newCols = s > 1.25
        ? (oldCols - 1).clamp(1, 6)
        : s < 0.8
        ? (oldCols + 1).clamp(1, 6)
        : oldCols;

    if (newCols == oldCols) {
      // 没跨档：直接弹回原状
      _settleFrom = s;
      _settleCtrl.forward(from: 0);
      return;
    }

    // 跨了档。新布局的格子比旧布局大 oldCols/newCols 倍，
    // 想在切换那一帧视觉上接住手指离开时的大小，新布局得先按
    // s * newCols / oldCols 画，再动画收回 1.0。
    _settleFrom = (s * newCols / oldCols).clamp(0.5, 2.0);
    prefs.setGridColumns(newCols);
    _settleCtrl.forward(from: 0);
  }
}

// ── 下载模式 ──

enum _DownloadMode { direct, zip }

// ── 相册列表行 ──

class _FolderListTile extends StatelessWidget {
  final String name;
  final String? coverId;
  final int? itemCount;
  final bool hasPassword;
  final MediaService service;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _FolderListTile({
    super.key,
    required this.name,
    this.coverId,
    this.itemCount,
    this.hasPassword = false,
    required this.service,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget coverWidget;
    if (coverId != null && hasPassword) {
      coverWidget = Stack(
        fit: StackFit.expand,
        children: [
          CachedThumb(
            id: '${coverId!}_blur',
            url: service.thumbUrl(coverId!, blur: true),
            headers: service.authHeaders,
          ),
          Center(
            child: Icon(Icons.lock_rounded, color: Colors.white, size: 22,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
            ),
          ),
        ],
      );
    } else if (coverId != null) {
      coverWidget = CachedThumb(
        id: coverId!,
        url: service.thumbUrl(coverId!),
        headers: service.authHeaders,
      );
    } else {
      coverWidget = Container(
        color: c.surface2,
        child: Icon(
          hasPassword ? Icons.folder_off_outlined : Icons.folder_outlined,
          color: c.onMuted,
          size: AppIconSize.xl,
        ),
      );
    }

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: SizedBox(width: 60, height: 60, child: coverWidget),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (hasPassword) Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(Icons.lock_rounded, size: 14, color: c.onMuted),
                      ),
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.onSurface,
                            fontSize: AppType.sm,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    itemCount != null ? '$itemCount 项' : '',
                    style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.onMuted, size: AppIconSize.lg),
          ],
        ),
      ),
    );
  }
}

// ── 上传遮罩 ──

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

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: c.scrimSoft,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    value: uploading ? progress.clamp(0, 1).toDouble() : null,
                    strokeWidth: 4,
                    color: c.brand,
                    backgroundColor: c.outline,
                  ),
                ),
                const SizedBox(height: 16),
                if (!uploading)
                  Text(
                    '正在准备上传…',
                    style: TextStyle(
                      color: c.onSurfaceVariant,
                      fontSize: AppType.sm,
                    ),
                  )
                else ...[
                  Text(
                    '${m.completed}/${m.total}  ${(progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: c.onSurface,
                      fontSize: AppType.mdPlus,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (speed > 0)
                    Text(
                      '${_fmtBytes(speed)}/s${eta != null ? '  ETA ${_fmtEta(eta)}' : ''}',
                      style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton(
                        onPressed: m.cancelling ? null : m.cancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.error,
                          side: BorderSide(
                            color: c.error.withValues(alpha: 0.5),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.chip),
                          ),
                        ),
                        child: Text(m.cancelling ? '正在取消…' : '取消上传'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: widget.onHide,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.brand,
                          foregroundColor: c.onScrim,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.chip),
                          ),
                        ),
                        child: const Text('后台上传'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 分组：见 gallery_groups.dart ──
