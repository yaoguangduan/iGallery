import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/display_prefs.dart';
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
import 'gallery_groups.dart';
import 'gallery_widgets.dart';
import 'media_viewer.dart';
import 'settings_sheet.dart';
import 'upload_bar.dart';
import 'upload_history_page.dart';

bool get _isDesktop => isDesktop;

class GalleryView extends StatefulWidget {
  const GalleryView({super.key});

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _scrollCtrl = ScrollController();
  final List<MediaItem> _items = [];
  bool _loading = false;
  String? _nextCursor;
  int _total = 0;
  bool _showScrollTop = false;
  final _reloadSeq = Seq();

  bool _selecting = false;
  final Set<String> _selected = {};

  // 下载进度（仅"逐个下载"模式使用；上传走 UploadManager）
  bool _downloading = false;
  int _downloadCompleted = 0;
  int _downloadTotal = 0;

  int? _viewerIndex;
  MediaService? _service;

  DisplayPrefs? _lastPrefs;

  // folder navigation
  String? _currentFolderId;
  final List<({String id, String name})> _folderPath = [];
  List<FolderItem> _folders = [];

  // search
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // pinch-to-zoom grid
  double _pinchBaseScale = 1.0;

  bool get _hasMore => _nextCursor != null;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final pos = _scrollCtrl.position;

    // 回到顶部按钮
    final show = pos.pixels > 800;
    if (show != _showScrollTop) setState(() => _showScrollTop = show);

    // 底部加载更多：距离底部 200px 时触发
    if (pos.pixels >= pos.maxScrollExtent - 200 && !_loading && _hasMore) {
      final prefs = context.read<DisplayPrefs>();
      _loadPage(prefs);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.watch<ServerState>();
    final prefs = context.watch<DisplayPrefs>();

    if (state.status == ConnectionStatus.connected && _service == null) {
      _service = MediaService(state);
      _lastPrefs = prefs;
      _reload(prefs);
    } else if (state.status != ConnectionStatus.connected) {
      _service = null;
    }
  }

  void _onPrefsChanged(DisplayPrefs prefs) {
    _lastPrefs = prefs;
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(0);
    }
    _reload(prefs);
  }

  Future<void> _reload(DisplayPrefs prefs) async {
    if (_service == null) return;
    final seq = _reloadSeq.bump();
    setState(() => _loading = true);
    try {
      final isSearching = _searchQuery.isNotEmpty;
      final showFolders = !isSearching && prefs.mediaFilter != MediaFilter.favoritesOnly;
      final futures = <Future>[
        _service!.query(size: 40, filter: _buildFilter(prefs), sort: _buildSort(prefs), withTotal: true),
      ];
      if (showFolders) {
        futures.add(_service!.listFolders(parentId: _currentFolderId));
      }
      final results = await Future.wait(futures);
      if (!mounted || !_reloadSeq.valid(seq)) return;
      final mediaResult = results[0] as QueryResult;
      final folders = showFolders ? results[1] as List<FolderItem> : <FolderItem>[];
      setState(() {
        _items.clear();
        _items.addAll(mediaResult.items);
        _total = mediaResult.total ?? mediaResult.items.length;
        _nextCursor = mediaResult.nextCursor;
        _folders = folders;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() => _loading = false);
      showToast(context, e.userMessage, kind: ToastKind.error);
    } catch (e) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() => _loading = false);
      showToast(context, '加载失败', kind: ToastKind.error);
    }
  }

  Map<String, dynamic> _buildFilter(DisplayPrefs prefs) {
    final conditions = <Map<String, dynamic>>[
      {'field': 'deleted_at', 'op': 'is_null'},
    ];

    if (_searchQuery.isNotEmpty) {
      conditions.add({'field': 'filename', 'op': 'like', 'value': '%$_searchQuery%'});
    } else if (_currentFolderId == null) {
      conditions.add({'field': 'folder_id', 'op': 'is_null'});
    } else {
      conditions.add({'field': 'folder_id', 'op': '=', 'value': _currentFolderId});
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
        'field': 'taken_at', 'op': 'between',
        'value': [toServerRfc3339(prefs.dateFrom!),
                   toServerRfc3339(prefs.dateTo!.add(const Duration(days: 1)))],
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
    return [{'field': field, 'dir': dir}];
  }

  Future<void> _loadPage(DisplayPrefs prefs) async {
    if (_loading || !_hasMore || _service == null) return;
    final seq = _reloadSeq.bump();
    setState(() => _loading = true);
    try {
      final result = await _service!.query(
        size: 40,
        filter: _buildFilter(prefs),
        sort: _buildSort(prefs),
        cursor: _nextCursor,
      );
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() {
        _items.addAll(result.items);
        _nextCursor = result.nextCursor;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() => _loading = false);
      showToast(context, e.userMessage, kind: ToastKind.error);
    } catch (e) {
      if (!mounted || !_reloadSeq.valid(seq)) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    final state = context.read<ServerState>();
    if (state.status != ConnectionStatus.connected) {
      await state.tryLocalhost();
      return;
    }
    final prefs = context.read<DisplayPrefs>();
    await _reload(prefs);
  }

  // ── 文件夹导航 ──

  void _enterFolder(FolderItem folder) {
    _folderPath.add((id: folder.id, name: folder.name));
    _currentFolderId = folder.id;
    _selected.clear();
    _selecting = false;
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
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _reload(context.read<DisplayPrefs>());
  }

  void _goBack() {
    if (_folderPath.isEmpty) return;
    _folderPath.removeLast();
    _currentFolderId = _folderPath.isEmpty ? null : _folderPath.last.id;
    _selected.clear();
    _selecting = false;
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _reload(context.read<DisplayPrefs>());
  }

  // ── 搜索 ──

  void _openSearch() {
    setState(() { _searching = true; _searchQuery = ''; });
    _searchCtrl.clear();
  }

  void _closeSearch() {
    setState(() { _searching = false; _searchQuery = ''; });
    _searchCtrl.clear();
    _reload(context.read<DisplayPrefs>());
  }

  void _onSearchSubmit(String query) {
    final q = query.trim();
    if (q == _searchQuery) return;
    _searchQuery = q;
    _reload(context.read<DisplayPrefs>());
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
          title: Text('新建文件夹', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
          content: TextField(
            controller: ctrl, autofocus: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.md),
            decoration: InputDecoration(
              hintText: '文件夹名称', hintStyle: TextStyle(color: c.onMuted),
              filled: true, fillColor: c.surface2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.chip), borderSide: BorderSide.none),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: c.onSurfaceVariant))),
            TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text('创建', style: TextStyle(color: c.brand, fontWeight: FontWeight.w600))),
          ],
        );
      },
    );
    if (name != null && name.isNotEmpty && mounted) {
      try {
        await _service!.createFolder(name: name, parentId: _currentFolderId);
        _refresh();
      } catch (e) {
        if (mounted) showToast(context, '创建失败: $e');
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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 32, height: 4, margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: c.outline, borderRadius: BorderRadius.circular(2)),
          ),
          ListTile(
            leading: Icon(Icons.edit, color: c.onSurfaceVariant),
            title: Text('重命名', style: TextStyle(color: c.onSurface)),
            onTap: () { Navigator.pop(ctx); _renameFolder(folder); },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: c.error),
            title: Text('删除文件夹', style: TextStyle(color: c.error)),
            onTap: () { Navigator.pop(ctx); _deleteFolderConfirm(folder); },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
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
          title: Text('重命名', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
          content: TextField(
            controller: ctrl, autofocus: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.md),
            decoration: InputDecoration(
              hintText: '文件夹名称', hintStyle: TextStyle(color: c.onMuted),
              filled: true, fillColor: c.surface2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.chip), borderSide: BorderSide.none),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: c.onSurfaceVariant))),
            TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text('确定', style: TextStyle(color: c.brand, fontWeight: FontWeight.w600))),
          ],
        );
      },
    );
    if (name != null && name.isNotEmpty && mounted) {
      try {
        await _service!.renameFolder(folder.id, name);
        _refresh();
      } catch (e) {
        if (mounted) showToast(context, '重命名失败: $e');
      }
    }
  }

  Future<void> _deleteFolderConfirm(FolderItem folder) async {
    if (_service == null) return;
    final confirmed = await appConfirmDialog(context,
        title: '删除文件夹',
        message: '确定删除文件夹「${folder.name}」？\n文件夹必须为空才能删除。',
        confirmLabel: '删除', destructive: true);
    if (!confirmed || !mounted) return;
    try {
      await _service!.deleteFolder(folder.id);
      _refresh();
    } catch (e) {
      if (mounted) showToast(context, '删除失败: $e');
    }
  }

  Future<void> _moveSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final targetId = await _showFolderPicker();
    if (targetId == null || !mounted) return;
    try {
      await _service!.batchMove(_selected.toList(), folderId: targetId.isEmpty ? null : targetId);
      showToast(context, '已移动 ${_selected.length} 个文件');
      _exitSelection();
      _refresh();
    } catch (e) {
      if (mounted) showToast(context, '移动失败: $e');
    }
  }

  Future<String?> _showFolderPicker() async {
    if (_service == null) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => FolderPickerDialog(service: _service!, currentFolderId: _currentFolderId),
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
  }

  void _exitSelection() {
    setState(() { _selecting = false; _selected.clear(); });
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
        showToast(context, target ? '已收藏 ${_selected.length} 个' : '已取消收藏 ${_selected.length} 个',
            kind: ToastKind.success);
        _exitSelection();
        _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, '操作失败: ${e.userMessage}', kind: ToastKind.error);
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final confirmed = await appConfirmDialog(context,
        title: '删除',
        message: '确定删除选中的 ${_selected.length} 个文件？',
        confirmLabel: '删除', destructive: true);
    if (!confirmed || !mounted) return;
    await _service!.batchDelete(_selected.toList());
    _exitSelection();
    await _refresh();
  }

  Future<void> _downloadSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final count = _selected.length;
    final c = context.colors;
    final choice = await showDialog<_DownloadMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('下载 $count 个文件',
            style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus,
                fontWeight: FontWeight.w600)),
        content: Text('请选择下载方式',
            style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.md)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DownloadMode.direct),
            child: Text('逐个下载', style: TextStyle(color: c.brand)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DownloadMode.zip),
            child: Text('打包下载', style: TextStyle(color: c.brand,
                fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == _DownloadMode.zip) {
      try {
        final savePath = await DownloadService.instance.pickSavePath('igallery.zip');
        if (savePath == null || !mounted) return; // 用户取消
        await _service!.downloadBatch(_selected.toList(), savePath: savePath);
        if (mounted) { showToast(context, '已下载为 zip', kind: ToastKind.success); _exitSelection(); }
      } on ApiException catch (e) {
        if (mounted) showToast(context, '下载失败: ${e.userMessage}', kind: ToastKind.error);
      } catch (_) {
        if (mounted) showToast(context, '下载失败', kind: ToastKind.error);
      }
    } else {
      final dir = await DownloadService.instance.pickSaveDir();
      if (dir == null || !mounted) return; // 用户取消
      setState(() { _downloading = true; _downloadCompleted = 0; _downloadTotal = count; });
      try {
        await _service!.downloadIndividual(
          _selected.toList(),
          saveDir: dir.path,
          onProgress: (c, t) {
            if (mounted) setState(() { _downloadCompleted = c; _downloadTotal = t; });
          },
        );
        if (mounted) { showToast(context, '已下载 $count 个文件', kind: ToastKind.success); _exitSelection(); }
      } on ApiException catch (e) {
        if (mounted) showToast(context, '下载失败: ${e.userMessage}', kind: ToastKind.error);
      } catch (e) {
        if (mounted) showToast(context, '下载失败', kind: ToastKind.error);
      } finally {
        if (mounted) setState(() => _downloading = false);
      }
    }
  }

  // ── 上传 ──

  Future<void> _pickAndUpload() async {
    if (_service == null) return;
    if (UploadManager.instance.uploading) {
      showToast(context, '正在上传中，请稍候', kind: ToastKind.info);
      return;
    }
    final List<PlatformFile> picked;
    if (_isDesktop) {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif',
          'mp4', 'mov', 'avi', 'mkv',
        ],
      );
    } else {
      picked = await FilePicker.pickFiles(type: FileType.media);
    }
    final files = picked
        .where((f) => f.path != null)
        .map((f) => File(f.path!))
        .toList();
    if (files.isEmpty || !mounted) return;

    final serverUrl = context.read<ServerState>().baseUrl;
    final result = await UploadManager.instance.enqueue(
      _service!, files,
      folderId: _currentFolderId,
      serverUrl: serverUrl,
    );

    if (mounted) {
      final parts = <String>['已上传 ${result.uploaded} 个'];
      if (result.dedup > 0) parts.add('${result.dedup} 个已存在跳过');
      if (result.failed > 0) parts.add('${result.failed} 个失败');
      showToast(context, parts.join(' · '),
          kind: result.failed > 0 ? ToastKind.error : ToastKind.success);
      _refresh();
    }
  }

  void _openUploadHistory() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UploadHistoryPage()));
  }

  // ── 导航 ──

  void _openProfile() {
    if (_isDesktop) {
      _scaffoldKey.currentState?.openDrawer();
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MobileProfilePage()),
      );
    }
  }

  void _openDisplaySettings() {
    if (_isDesktop) {
      _scaffoldKey.currentState?.openEndDrawer();
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => DisplaySettingsSheet(onChanged: () {
          final prefs = context.read<DisplayPrefs>();
          _onPrefsChanged(prefs);
        }),
      );
    }
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<ServerState>();
    final prefs = context.watch<DisplayPrefs>();

    return PopScope(
      canPop: _currentFolderId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bg,
      drawer: _isDesktop ? _buildLeftDrawer(c) : null,
      endDrawer: _isDesktop ? _buildRightDrawer(c, prefs) : null,
      floatingActionButton: _showScrollTop && _viewerIndex == null
          ? FloatingActionButton.small(
              onPressed: () {
                _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                _refresh();
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
          Column(
            children: [
              _buildToolbar(c, state, prefs),
              if (state.status == ConnectionStatus.connected && !_searching)
                _buildFilterChips(c, prefs),
              UploadBar(onTap: _openUploadHistory),
              if (_downloading) _buildDownloadBar(c),
              Expanded(child: _buildBody(c, state, prefs)),
            ],
          ),
          if (_viewerIndex != null && _service != null)
            MediaViewer(
              items: _items,
              initialIndex: _viewerIndex!,
              service: _service!,
              onClose: () => setState(() => _viewerIndex = null),
              onDeleted: (id) {
                setState(() {
                  _items.removeWhere((m) => m.id == id);
                  if (_items.isEmpty) _viewerIndex = null;
                });
              },
            ),
        ],
      ),
    ),
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
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('设置', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, size: AppIconSize.lg, color: c.onSurfaceVariant)),
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

  Widget _buildRightDrawer(AppColors c, DisplayPrefs prefs) {
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
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('显示设置', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (prefs.hasActiveFilter)
                    TextButton(
                      onPressed: () { prefs.clearFilters(); _onPrefsChanged(prefs); },
                      child: Text('重置', style: TextStyle(color: c.brand, fontSize: AppType.xs)),
                    ),
                  IconButton(onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, size: AppIconSize.lg, color: c.onSurfaceVariant)),
                ],
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: c.outline),
            Expanded(child: DisplaySettingsContent(onChanged: () => _onPrefsChanged(prefs))),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(AppColors c, ServerState state, DisplayPrefs prefs) {
    final connected = state.status == ConnectionStatus.connected;
    final inFolder = _currentFolderId != null;

    if (_searching) {
      return Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.outline, width: 0.5)),
        ),
        child: Row(children: [
          IconButton(
            onPressed: _closeSearch,
            icon: Icon(Icons.arrow_back, size: AppIconSize.lg, color: c.onSurface),
          ),
          Expanded(child: TextField(
            controller: _searchCtrl,
            autofocus: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
            decoration: InputDecoration(
              hintText: '搜索文件名…',
              hintStyle: TextStyle(color: c.onMuted, fontSize: AppType.sm),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: _onSearchSubmit,
            onChanged: (q) {
              if (q.isEmpty && _searchQuery.isNotEmpty) _onSearchSubmit('');
            },
          )),
          IconButton(
            onPressed: () {
              if (_searchCtrl.text.isNotEmpty) {
                _searchCtrl.clear();
                _onSearchSubmit('');
              } else {
                _closeSearch();
              }
            },
            icon: Icon(Icons.close, size: AppIconSize.lg, color: c.onSurfaceVariant),
          ),
        ]),
      );
    }

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outline, width: 0.5)),
      ),
      child: Row(
        children: [
          if (inFolder) ...[
            IconButton(
              onPressed: _goBack,
              icon: Icon(Icons.arrow_back, size: AppIconSize.lg, color: c.onSurface),
              tooltip: '返回',
            ),
            Expanded(child: _buildBreadcrumb(c)),
          ] else ...[
            IconButton(
              onPressed: _openProfile,
              icon: Icon(Icons.menu, size: AppIconSize.lg, color: c.onSurface),
              tooltip: '设置',
            ),
            if (!connected)
              Text(state.status == ConnectionStatus.needAuth ? '需令牌' : '未连接',
                  style: TextStyle(
                    color: state.status == ConnectionStatus.needAuth ? c.warn : c.onMuted,
                    fontSize: AppType.xs)),
            if (connected && _total > 0)
              Text('$_total', style: TextStyle(color: c.onMuted, fontSize: AppType.xs)),
            const Spacer(),
          ],

          if (_selecting) ...[
            TextButton(
              onPressed: _toggleSelectAll,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(_allSelected ? '取消全选' : '全选',
                  style: TextStyle(color: c.brand, fontSize: AppType.xs, fontWeight: FontWeight.w600)),
            ),
            Text('${_selected.length}',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm, fontWeight: FontWeight.w600)),
            IconButton(onPressed: _favoriteSelected,
                icon: Icon(
                  _selectedAllFavorite ? Icons.star : Icons.star_border,
                  size: AppIconSize.lg,
                  color: _selectedAllFavorite ? c.warn : c.onSurfaceVariant,
                ), tooltip: _selectedAllFavorite ? '取消收藏' : '收藏'),
            IconButton(onPressed: _moveSelected,
                icon: Icon(Icons.drive_file_move_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '移动'),
            IconButton(onPressed: _downloadSelected,
                icon: Icon(Icons.file_download_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '下载'),
            IconButton(onPressed: _deleteSelected,
                icon: Icon(Icons.delete_outline, size: AppIconSize.lg, color: c.error), tooltip: '删除'),
            IconButton(onPressed: _exitSelection,
                icon: Icon(Icons.close_rounded, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '取消'),
          ] else ...[
            if (connected)
              IconButton(onPressed: _openSearch,
                  icon: Icon(Icons.search, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '搜索'),
            if (connected && _items.isNotEmpty)
              IconButton(onPressed: () => setState(() => _selecting = true),
                  icon: Icon(Icons.library_add_check_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '多选'),
            if (connected)
              IconButton(onPressed: _createFolder,
                  icon: Icon(Icons.create_new_folder_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '新建文件夹'),
            if (connected)
              IconButton(
                  onPressed: _pickAndUpload,
                  icon: Icon(Icons.upload_rounded, size: AppIconSize.lg,
                      color: c.onSurfaceVariant), tooltip: '上传'),
            IconButton(
              onPressed: _openDisplaySettings,
              icon: Stack(children: [
                Icon(Icons.tune, size: AppIconSize.lg, color: c.onSurfaceVariant),
                if (prefs.hasActiveFilter)
                  Positioned(right: 0, top: 0,
                      child: Container(width: 6, height: 6,
                          decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle))),
              ]),
              tooltip: '显示设置',
            ),
          ],
        ],
      ),
    );
  }

  // ── 顶栏下筛选 chips（全部/图片/视频/收藏）──
  Widget _buildFilterChips(AppColors c, DisplayPrefs prefs) {
    const options = <(MediaFilter, String, IconData?)>[
      (MediaFilter.all, '全部', null),
      (MediaFilter.photosOnly, '图片', null),
      (MediaFilter.videosOnly, '视频', null),
      (MediaFilter.favoritesOnly, '收藏', null),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final (filter, label, _) = options[i];
          final active = prefs.mediaFilter == filter;
          return GestureDetector(
            onTap: active
                ? null
                : () {
                    prefs.setMediaFilter(filter);
                    _onPrefsChanged(prefs);
                  },
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: active ? c.brandSoft : c.surface2,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(
                  color: active ? c.brand : Colors.transparent,
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (filter == MediaFilter.favoritesOnly) ...[
                    Icon(active ? Icons.star : Icons.star_border,
                        size: AppIconSize.sm,
                        color: active ? c.brand : c.onSurfaceVariant),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? c.brand : c.onSurfaceVariant,
                      fontSize: AppType.sm,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBreadcrumb(AppColors c) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _navigateToPathIndex(-1),
            child: Text('首页', style: TextStyle(color: c.brand, fontSize: AppType.xs)),
          ),
          for (var i = 0; i < _folderPath.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.chevron_right, size: 14, color: c.onMuted),
            ),
            GestureDetector(
              onTap: i < _folderPath.length - 1 ? () => _navigateToPathIndex(i) : null,
              child: Text(
                _folderPath[i].name,
                style: TextStyle(
                  color: i < _folderPath.length - 1 ? c.brand : c.onSurface,
                  fontSize: AppType.xs,
                  fontWeight: i == _folderPath.length - 1 ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDownloadBar(AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(children: [
        SizedBox(width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.brand,
                value: _downloadTotal > 0 ? _downloadCompleted / _downloadTotal : null)),
        const SizedBox(width: 10),
        Text('下载中 $_downloadCompleted / $_downloadTotal',
            style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs)),
      ]),
    );
  }

  Widget _buildBody(AppColors c, ServerState state, DisplayPrefs prefs) {
    if (state.status != ConnectionStatus.connected) {
      final needAuth = state.status == ConnectionStatus.needAuth;
      return AppEmptyState(
        icon: needAuth ? Icons.vpn_key_outlined : Icons.wifi_off,
        message: needAuth ? '服务器需要访问令牌' : '未连接到服务器',
        action: AppButton(label: needAuth ? '输入令牌' : '去连接', onTap: _openProfile),
      );
    }

    if (_items.isEmpty && !_loading && _folders.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh, color: c.brand,
        child: ListView(children: [
          const SizedBox(height: 120),
          AppEmptyState(
            icon: Icons.photo_library_outlined,
            message: prefs.hasActiveFilter ? '没有匹配的项目' : '还没有照片',
            action: prefs.hasActiveFilter
                ? AppButton(label: '清除筛选', onTap: () { prefs.clearFilters(); _refresh(); }, primary: false)
                : AppButton(label: '上传照片', icon: Icons.add, onTap: _pickAndUpload),
          ),
        ]),
      );
    }

    final groups = buildGroups(_items, prefs);

    return GestureDetector(
      onScaleStart: (_) => _pinchBaseScale = 1.0,
      onScaleUpdate: (d) {
        if (d.pointerCount < 2) return;
        final delta = d.scale / _pinchBaseScale;
        if (delta > 1.3) { prefs.pinchZoomTransient(1.5); _pinchBaseScale = d.scale; }
        else if (delta < 0.7) { prefs.pinchZoomTransient(0.5); _pinchBaseScale = d.scale; }
      },
      onScaleEnd: (_) => prefs.pinchZoomCommit(),
      child: RefreshIndicator(
      onRefresh: _refresh, color: c.brand,
      notificationPredicate: (_) => true,
      child: CustomScrollView(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // folders section
          if (_folders.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                child: Text('文件夹',
                    style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w700)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 130,
                  mainAxisSpacing: 12, crossAxisSpacing: 10,
                  childAspectRatio: 0.86,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => FolderThumb(
                    folder: _folders[i],
                    service: _service!,
                    onTap: () => _enterFolder(_folders[i]),
                    onLongPress: () => _showFolderActions(_folders[i]),
                  ),
                  childCount: _folders.length,
                ),
              ),
            ),
          ],
          // media section
          for (final group in groups) ...[
            if (group.label.isNotEmpty)
              SliverToBoxAdapter(
                child: GestureDetector(
                  behavior: _selecting ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
                  onTap: _selecting ? () => _toggleGroupSelect(group) : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
                    child: Row(children: [
                      Text(group.label,
                          style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      if (_selecting)
                        Icon(
                          group.items.every((m) => _selected.contains(m.id))
                              ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 18,
                          color: group.items.every((m) => _selected.contains(m.id))
                              ? c.brand : c.onMuted,
                        ),
                    ]),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: prefs.gridColumns,
                  mainAxisSpacing: 12, crossAxisSpacing: 10,
                  childAspectRatio: prefs.labelPosition == LabelPosition.below && prefs.hasLabel ? 0.76 : 1.0,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => MediaThumb(
                    item: group.items[i], service: _service!,
                    selected: _selected.contains(group.items[i].id),
                    selecting: _selecting, prefs: prefs,
                    onTap: () {
                      if (_selecting) { _toggleSelect(group.items[i].id); }
                      else { setState(() => _viewerIndex = _items.indexOf(group.items[i])); }
                    },
                    onLongPress: () {
                      if (!_selecting) setState(() => _selecting = true);
                      _toggleSelect(group.items[i].id);
                    },
                  ),
                  childCount: group.items.length,
                ),
              ),
            ),
          ],
          if (_loading && _items.isNotEmpty)
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: c.brand)),
                const SizedBox(width: 10),
                Text('加载中 ${_items.length} / $_total',
                    style: TextStyle(color: c.onMuted, fontSize: AppType.xs)),
              ]),
            )),
          if (_loading && _items.isEmpty)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(24), child: AppSpinner())),
          if (!_hasMore && _items.isNotEmpty)
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(child: Text('已加载全部 $_total 项',
                  style: TextStyle(color: c.onMuted, fontSize: AppType.xs))),
            )),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    ),
    );
  }
}

// ── 下载模式 ──

enum _DownloadMode { direct, zip }

// ── 分组：见 gallery_groups.dart ──

