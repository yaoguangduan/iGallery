import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'drag_select.dart';
import 'gallery_groups.dart';
import 'gallery_widgets.dart';
import 'media_picker.dart';
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

class _GalleryViewState extends State<GalleryView>
    with SingleTickerProviderStateMixin {
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

  // 滑选（多选模式下按住拖动）
  int? _sweepAnchor;
  bool _sweepAdding = true;
  Set<String> _sweepBaseline = {};

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

  // search（内嵌在内容顶部，无"搜索模式"状态；有没有在搜由 _searchQuery 决定）
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

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
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _settleCtrl.dispose();
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
      // 新内容布局完成后再把搜索框滚出视野（此时 maxScrollExtent 才是准的）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _hideSearchBar();
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
    // 换目录必须清搜索：否则旧关键词会静默过滤新目录，连子文件夹一起藏掉
    _searchQuery = '';
    _searchCtrl.clear();
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
    // 换目录必须清搜索：否则旧关键词会静默过滤新目录，连子文件夹一起藏掉
    _searchQuery = '';
    _searchCtrl.clear();
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _reload(context.read<DisplayPrefs>());
  }

  void _goBack() {
    if (_folderPath.isEmpty) return;
    _folderPath.removeLast();
    _currentFolderId = _folderPath.isEmpty ? null : _folderPath.last.id;
    _selected.clear();
    _selecting = false;
    // 换目录必须清搜索：否则旧关键词会静默过滤新目录，连子文件夹一起藏掉
    _searchQuery = '';
    _searchCtrl.clear();
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _reload(context.read<DisplayPrefs>());
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
    if (_searchQuery.isNotEmpty) {
      _clearSearch();
      return;
    }
    if (_currentFolderId != null) {
      _goBack();
      return;
    }
    // canPop 为 true 时系统已经自己 pop 了，走不到这里
  }

  // ── 内容顶部：面包屑 + 搜索 ──
  //
  // 两者都躺在内容里，顶栏不显示任何目录信息 —— 顶栏宽度有限，
  // 深目录的面包屑放那儿必然被截断看不全。
  //
  // 搜索是微信/Apple 式：**默认藏在视野上方**，滚到顶再往下拉一点才露出，
  // 位置介于内容和刷新指示器之间。靠首帧把滚动位置设到 _headerScrollExtent 实现，
  // 不是靠隐藏 widget —— 它始终在树里，所以下拉能连续地把它带出来。
  // 没有"搜索模式"这个状态，有没有在搜索完全由 _searchQuery 是否为空决定。

  /// 搜索框那一段的高度：上下 padding(10+6) + 搜索框(40)。
  /// 面包屑已移出这里（是固定行），所以不再随目录层级变化。
  static const double _headerScrollExtent = 56;

  /// 首帧把搜索框滚出视野。列表内容不足一屏时不做（滚不动，做了也白做）。
  void _hideSearchBar() {
    if (!_scrollCtrl.hasClients) return;
    final target = _headerScrollExtent;
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent < target) return;
    if (pos.pixels > 0) return;   // 用户已经滚过了，别抢
    _scrollCtrl.jumpTo(target);
  }

  void _clearSearch() {
    if (_searchQuery.isEmpty && _searchCtrl.text.isEmpty) return;
    _searchCtrl.clear();
    _searchQuery = '';
    FocusScope.of(context).unfocus();
    _reload(context.read<DisplayPrefs>());
  }

  void _onSearchSubmit(String query) {
    final q = query.trim();
    if (q == _searchQuery) return;
    _searchQuery = q;
    FocusScope.of(context).unfocus();
    _reload(context.read<DisplayPrefs>());
  }

  /// 内容顶部只放搜索框（面包屑是固定行，在 chips 上方，不跟着滚）。
  /// 多选时整体淡出，但**保留占位**——增删 sliver 会让后面所有内容位移。
  Widget _buildInlineHeader(AppColors c) {
    final active = _searchQuery.isNotEmpty;
    return SliverOpacity(
      opacity: _selecting ? 0 : 1,
      sliver: SliverIgnorePointer(
        ignoring: _selecting,
        sliver: SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(children: [
                    Icon(Icons.search, size: AppIconSize.md, color: c.onMuted),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(
                      controller: _searchCtrl,
                      style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
                      decoration: InputDecoration(
                        hintText: '搜索文件名',
                        hintStyle: TextStyle(color: c.onMuted, fontSize: AppType.sm),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: _onSearchSubmit,
                      // 只为让清除按钮跟着输入出现/消失；不在这里发请求
                      onChanged: (_) => setState(() {}),
                    )),
                    if (active || _searchCtrl.text.isNotEmpty)
                      GestureDetector(
                        onTap: _clearSearch,
                        child: Icon(Icons.cancel, size: AppIconSize.md, color: c.onMuted),
                      ),
                  ]),
                ),
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(top: 10, left: 4),
                    child: Text('「$_searchQuery」的结果 · $_total 项',
                        style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
        if (mounted) showToast(context, '已创建「$name」', kind: ToastKind.success);
        _refresh();
      } catch (e) {
        if (mounted) showToast(context, '创建失败: ${errorText(e)}', kind: ToastKind.error);
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
        if (mounted) showToast(context, '已重命名', kind: ToastKind.success);
        _refresh();
      } catch (e) {
        if (mounted) showToast(context, '重命名失败: ${errorText(e)}', kind: ToastKind.error);
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
      if (mounted) showToast(context, '已删除文件夹', kind: ToastKind.success);
      _refresh();
    } catch (e) {
      if (mounted) showToast(context, '删除失败: ${errorText(e)}', kind: ToastKind.error);
    }
  }

  Future<void> _moveSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final targetId = await _showFolderPicker();
    if (targetId == null || !mounted) return;
    try {
      await _service!.batchMove(_selected.toList(), folderId: targetId.isEmpty ? null : targetId);
      showToast(context, '已移动 ${_selected.length} 个文件', kind: ToastKind.success);
      _exitSelection();
      _refresh();
    } catch (e) {
      if (mounted) showToast(context, '移动失败: ${errorText(e)}', kind: ToastKind.error);
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
        final on = (i >= lo && i <= hi) ? _sweepAdding : _sweepBaseline.contains(id);
        if (on) { _selected.add(id); } else { _selected.remove(id); }
      }
    });
  }

  void _sweepEnd() {
    _sweepAnchor = null;
    _sweepBaseline = {};
    // 滑到一个都不剩就退出多选，和点选的行为一致
    if (_selected.isEmpty && _selecting) setState(() => _selecting = false);
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
      if (mounted) showToast(context, '操作失败: ${e.displayMessage}', kind: ToastKind.error);
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _service == null) return;
    final confirmed = await appConfirmDialog(context,
        title: '删除',
        message: '确定删除选中的 ${_selected.length} 个文件？',
        confirmLabel: '删除', destructive: true);
    if (!confirmed || !mounted) return;
    final count = _selected.length;
    try {
      await _service!.batchDelete(_selected.toList());
      if (mounted) showToast(context, '已删除 $count 个文件', kind: ToastKind.success);
      _exitSelection();
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) showToast(context, '删除失败: ${e.displayMessage}', kind: ToastKind.error);
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
        if (mounted) showToast(context, '下载失败: ${e.displayMessage}', kind: ToastKind.error);
      } catch (_) {
        if (mounted) showToast(context, '下载失败', kind: ToastKind.error);
      }
    } else {
      final dir = await DownloadService.instance.pickSaveDir();
      if (dir == null || !mounted) return; // 用户取消
      setState(() { _downloading = true; _downloadCompleted = 0; _downloadTotal = count; });
      try {
        final report = await _service!.downloadIndividual(
          _selected.toList(),
          saveDir: dir.path,
          onProgress: (c, t) {
            if (mounted) setState(() { _downloadCompleted = c; _downloadTotal = t; });
          },
        );
        if (mounted) {
          // 如实汇报成功/失败数，不再一律"已下载 N 个"
          if (report.failed == 0) {
            showToast(context, '已下载 ${report.ok} 个文件', kind: ToastKind.success);
          } else if (report.ok == 0) {
            showToast(context, '下载失败（${report.failed} 个）', kind: ToastKind.error);
          } else {
            showToast(context, '已下载 ${report.ok} 个，${report.failed} 个失败',
                kind: ToastKind.error);
          }
          if (report.ok > 0) _exitSelection();
        }
      } on ApiException catch (e) {
        if (mounted) showToast(context, '下载失败: ${e.displayMessage}', kind: ToastKind.error);
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
      files = picked
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
      if (result.cancelled > 0) parts.add('${result.cancelled} 个已取消');
      showToast(context, parts.join(' · '),
          kind: result.allOk ? ToastKind.success : ToastKind.error);
      _refresh();
    }
  }

  /// 移动端上传入口:弹出"从相册 / 从文件"二选一。
  /// 相册走 photo_manager,拿得到拍摄时间和多选滑动;
  /// 文件走 SAF/Files,覆盖非相册目录、微信下载、第三方 app 存的文件。
  Future<void> _showUploadSourceSheet() async {
    if (_isDesktop) { _pickAndUpload(); return; }
    final c = context.colors;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SheetHandle(),
          ListTile(
            leading: Icon(Icons.photo_library_outlined, color: c.onSurface),
            title: Text('从相册选择',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
            subtitle: Text('图片和视频,可多选',
                style: TextStyle(color: c.onMuted, fontSize: AppType.xxs)),
            onTap: () => Navigator.pop(ctx, 'album'),
          ),
          ListTile(
            leading: Icon(Icons.folder_open_outlined, color: c.onSurface),
            title: Text('从文件选择',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
            subtitle: Text('任意目录、任意格式',
                style: TextStyle(color: c.onMuted, fontSize: AppType.xxs)),
            onTap: () => Navigator.pop(ctx, 'files'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == 'album') _pickAndUpload();
    if (choice == 'files') _pickAndUpload(fromFiles: true);
  }

  void _openUploadHistory() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UploadHistoryPage()));
  }

  // ── 桌面右键菜单 ──

  void _showGridContextMenu(Offset pos, AppColors c) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      color: c.surface,
      items: [
        PopupMenuItem(value: 'new_folder', child: Row(children: [
          Icon(Icons.create_new_folder_outlined, size: 18, color: c.onSurfaceVariant),
          const SizedBox(width: 12),
          Text('新建文件夹', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
        ])),
        PopupMenuItem(value: 'refresh', child: Row(children: [
          Icon(Icons.refresh, size: 18, color: c.onSurfaceVariant),
          const SizedBox(width: 12),
          Text('刷新', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
        ])),
        PopupMenuItem(value: 'upload', child: Row(children: [
          Icon(Icons.upload_rounded, size: 18, color: c.onSurfaceVariant),
          const SizedBox(width: 12),
          Text('上传', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
        ])),
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
        PopupMenuItem(value: 'open', child: Row(children: [
          Icon(Icons.open_in_new, size: 18, color: c.onSurfaceVariant),
          const SizedBox(width: 12),
          Text('打开', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
        ])),
        PopupMenuItem(value: 'favorite', child: Row(children: [
          Icon(item.isFavorite ? Icons.favorite : Icons.favorite_border, size: 18,
              color: item.isFavorite ? c.onSurface : c.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(item.isFavorite ? '取消收藏' : '收藏', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
        ])),
        PopupMenuItem(value: 'move', child: Row(children: [
          Icon(Icons.drive_file_move_outlined, size: 18, color: c.onSurfaceVariant),
          const SizedBox(width: 12),
          Text('移动', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
        ])),
        PopupMenuItem(value: 'delete', child: Row(children: [
          Icon(Icons.delete_outline, size: 18, color: c.error),
          const SizedBox(width: 12),
          Text('删除', style: TextStyle(color: c.error, fontSize: AppType.sm)),
        ])),
      ],
    ).then((v) async {
      if (v == 'open') {
        setState(() => _viewerIndex = _items.indexOf(item));
      } else if (v == 'favorite') {
        try {
          final target = !item.isFavorite;
          await _service!.batchFavorite([item.id], favorite: target);
          final idx = _items.indexWhere((m) => m.id == item.id);
          if (idx >= 0) _items[idx] = _items[idx].copyWith(favorite: target ? 1 : 0);
          if (mounted) { setState(() {}); showToast(context, target ? '已收藏' : '已取消收藏', kind: ToastKind.success); }
        } on ApiException catch (e) {
          if (mounted) showToast(context, '操作失败: ${e.displayMessage}', kind: ToastKind.error);
        }
      } else if (v == 'move') {
        _selected.clear(); _selected.add(item.id); _selecting = true;
        _moveSelected();
      } else if (v == 'delete') {
        final ok = await appConfirmDialog(context, title: '删除', message: '确定删除 ${item.filename}？', confirmLabel: '删除', destructive: true);
        if (!ok || !mounted) return;
        try {
          await _service!.delete(item.id);
          if (mounted) showToast(context, '已删除 ${item.filename}', kind: ToastKind.success);
          _refresh();
        } on ApiException catch (e) {
          if (mounted) showToast(context, '删除失败: ${e.displayMessage}', kind: ToastKind.error);
        } catch (_) {
          if (mounted) showToast(context, '删除失败', kind: ToastKind.error);
        }
      }
    });
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: c.bg,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: c.bg,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: PopScope(
      // 返回手势/返回键的处理顺序，从"最浮在上面"到"最底层"。
      //
      // canPop 和 _handleBack 必须**枚举同一组状态**，漏一个就是"返回键
      // 越级把上一层也退了"这类 bug。加新的可关闭状态时两处一起改。
      //
      //   1. 查看器打开   → 关查看器
      //   2. 多选中       → 退出多选
      //   3. 有搜索结果   → 清搜索
      //   4. 在子目录     → 回上一级
      //   5. 都没有       → 真的 pop（退出 app）
      canPop: _viewerIndex == null
          && !_selecting
          && _searchQuery.isEmpty
          && _currentFolderId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bg,
      drawer: _isDesktop ? _buildLeftDrawer(c) : null,
      endDrawer: _isDesktop ? _buildRightDrawer(c, prefs) : null,
      floatingActionButton: _showScrollTop && _viewerIndex == null
          ? FloatingActionButton.small(
              onPressed: () {
                // 回到"内容顶部"而不是 0 —— 0 会把搜索框亮出来，
                // 用户只是想回顶看第一批图，不是要搜索
                _scrollCtrl.animateTo(_headerScrollExtent,
                    duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
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
              // chips 在多选时**保留占位**，只是变灰不可点。
              // 直接摘掉会让下面整块内容往上顿一下 —— 长按进多选时尤其明显。
              if (state.status == ConnectionStatus.connected)
                IgnorePointer(
                  ignoring: _selecting,
                  child: Opacity(opacity: _selecting ? 0.35 : 1, child: _buildFilterChips(c, prefs)),
                ),
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
              height: 58,
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
              height: 58,
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

    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outline, width: 0.5)),
      ),
      child: Row(
        children: [
          // 左槽固定：非多选是设置，多选是退出。
          // 两者占同一个位置，进出多选时不会有 icon 满屏跳。
          if (_selecting)
            IconButton(
              onPressed: _exitSelection,
              icon: Icon(Icons.close_rounded, size: AppIconSize.lg, color: c.onSurface),
              tooltip: '退出多选',
            )
          else
            _buildAvatar(c, state),
          if (_selecting) ...[
            Text('已选 ${_selected.length}',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm, fontWeight: FontWeight.w600)),
            const Spacer(),
          ] else ...[
            // 路径紧挨头像。深目录折叠成 `…` 下拉，见 _buildToolbarPath。
            //
            // 必须 Flexible(fit: loose) + flex: 0：默认的 flex:1 会和后面的
            // Spacer 平分剩余空间，把右侧按钮从最右边推走。
            // flex: 0 表示"只要内容宽度，放不下才收缩"，剩余空间全归 Spacer。
            if (_currentFolderId != null)
              Flexible(flex: 0, child: _buildToolbarPath(c)),
            if (!connected)
              Text(state.status == ConnectionStatus.needAuth ? '需令牌' : '未连接',
                  style: TextStyle(
                    color: state.status == ConnectionStatus.needAuth ? c.warn : c.onMuted,
                    fontSize: AppType.xs)),
            if (connected && _currentFolderId == null && _total > 0)
              Text('$_total', style: TextStyle(color: c.onMuted, fontSize: AppType.xs)),
            const Spacer(),
          ],

          if (_selecting) ...[
            IconButton(onPressed: _toggleSelectAll,
                icon: Icon(
                  _allSelected ? Icons.deselect : Icons.select_all,
                  size: AppIconSize.lg,
                  color: _allSelected ? c.brand : c.onSurfaceVariant,
                ), tooltip: _allSelected ? '取消全选' : '全选'),
            IconButton(onPressed: _favoriteSelected,
                icon: Icon(
                  _selectedAllFavorite ? Icons.favorite : Icons.favorite_border,
                  size: AppIconSize.lg,
                  color: _selectedAllFavorite ? c.onSurface : c.onSurfaceVariant,
                ), tooltip: _selectedAllFavorite ? '取消收藏' : '收藏'),
            IconButton(onPressed: _moveSelected,
                icon: Icon(Icons.drive_file_move_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '移动'),
            IconButton(onPressed: _downloadSelected,
                icon: Icon(Icons.file_download_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '下载'),
            IconButton(onPressed: _deleteSelected,
                icon: Icon(Icons.delete_outline, size: AppIconSize.lg, color: c.error), tooltip: '删除'),
          ] else ...[
            if (connected && _items.isNotEmpty)
              IconButton(onPressed: () => setState(() => _selecting = true),
                  icon: Icon(Icons.library_add_check_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '多选'),
            if (connected)
              IconButton(onPressed: _createFolder,
                  icon: Icon(Icons.create_new_folder_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '新建文件夹'),
            if (connected)
              IconButton(
                  onPressed: _showUploadSourceSheet,
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

  // ── 顶栏下筛选 chips（YouTube 移动端风格）──
  Widget _buildFilterChips(AppColors c, DisplayPrefs prefs) {
    const options = <(MediaFilter, String)>[
      (MediaFilter.all, '全部'),
      (MediaFilter.photosOnly, '图片'),
      (MediaFilter.videosOnly, '视频'),
      (MediaFilter.favoritesOnly, '收藏'),
    ];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (ctx, i) {
          final (filter, label) = options[i];
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
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: active ? c.onSurface : c.surface2,
                borderRadius: BorderRadius.circular(AppRadius.chip),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: active ? c.bg : c.onSurface,
                  fontSize: AppType.sm,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 顶栏里的路径，紧挨设置图标。两种形态：
  ///  - 1 层：`首页 / 相册名`，两段都可点
  ///  - 2 层以上：`… / 当前层`，点 `…` 弹出中间各层的下拉菜单
  ///
  /// 之所以不平铺所有层：顶栏宽度有限，深目录平铺必然挤掉右侧操作按钮
  /// 或被截断。折叠成一个 `…` 是 Finder / VS Code 面包屑的通用做法。
  /// 左上角头像 → 全局设置。
  /// 取当前服务器名首字，底色跟连接状态走 —— 顺带当状态指示，
  /// 不用再单独占一个位置显示"未连接/需令牌"。
  Widget _buildAvatar(AppColors c, ServerState state) {
    final name = state.active?.name.trim() ?? '';
    return IconButton(
      onPressed: _openProfile,
      tooltip: name.isEmpty ? '设置' : '$name · 设置',
      icon: Icon(Icons.person_outline,
          size: AppIconSize.lg, color: c.onSurfaceVariant),
    );
  }

  Widget _buildToolbarPath(AppColors c) {
    final last = _folderPath.length - 1;
    final style = TextStyle(
      color: c.onSurfaceVariant,
      fontSize: AppType.sm,
      height: 1.2,
    );
    final sep = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text('/', style: style.copyWith(color: c.onMuted)),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (_folderPath.length == 1)
          _pathSegment('首页', style, () => _navigateToPathIndex(-1))
        else
          _buildPathMenu(c, style),
        sep,
        // 当前层：跟其它段用同一样式,不再加粗/加深
        Flexible(
          child: Text(
            _folderPath[last].name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }

  /// 折叠态的 `…`：点开列出 首页 + 所有中间层
  Widget _buildPathMenu(AppColors c, TextStyle style) {
    return PopupMenuButton<int>(
      tooltip: '上级目录',
      color: c.surface,
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      onSelected: _navigateToPathIndex,
      itemBuilder: (_) => [
        PopupMenuItem(value: -1, child: Row(children: [
          Icon(Icons.home_outlined, size: AppIconSize.md, color: c.onSurfaceVariant),
          const SizedBox(width: 10),
          Text('首页', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
        ])),
        // 不含最后一层 —— 那是当前所在层，已经显示在右边了
        for (var i = 0; i < _folderPath.length - 1; i++)
          PopupMenuItem(value: i, child: Padding(
            // 逐级缩进，一眼看出层级关系
            padding: EdgeInsets.only(left: 12.0 * (i + 1)),
            child: Row(children: [
              Icon(Icons.subdirectory_arrow_right, size: AppIconSize.sm, color: c.onMuted),
              const SizedBox(width: 8),
              Flexible(child: Text(_folderPath[i].name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.onSurface, fontSize: AppType.sm))),
            ]),
          )),
      ],
      child: Padding(
        // PopupMenuButton 默认有 48px 最小点击区，会把 `…` 撑得很宽。
        // 这里自己给一个够用的点击面积，不让它顶开右边的操作按钮。
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text('…', style: style.copyWith(
          color: c.onSurfaceVariant,
          fontSize: AppType.mdPlus,
          fontWeight: FontWeight.w600,
        )),
      ),
    );
  }

  Widget _pathSegment(String label, TextStyle style, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
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
                : AppButton(label: '上传照片', icon: Icons.add, onTap: _showUploadSourceSheet),
          ),
        ]),
      );
    }

    final groups = buildGroups(_items, prefs);
    // 滑选要全局下标（groups 是 _items 的有序分区）
    final indexOfId = <String, int>{
      for (var i = 0; i < _items.length; i++) _items[i].id: i,
    };

    return GestureDetector(
      // 到这里已经过了上面的未连接早退，必然是 connected
      onSecondaryTapDown: _isDesktop ? (d) => _showGridContextMenu(d.globalPosition, c) : null,
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
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      ),
      child: RefreshIndicator(
      onRefresh: _refresh, color: c.brand,
      notificationPredicate: (_) => true,
      child: DragSelectDetector(
        enabled: _selecting,
        onStart: _sweepStart,
        onEnter: _sweepTo,
        onEnd: _sweepEnd,
        scrollController: _scrollCtrl,
        child: LayoutBuilder(builder: (ctx, box) {
        // 格子高 = 列宽 + 标签高。用实测列宽算，不写死 childAspectRatio ——
        // 写死的比例在列宽或标签行数变化时会让标签放不下（RenderFlex overflowed）。
        const gridPad = 16.0, crossGap = 14.0;
        final usable = box.maxWidth - gridPad * 2;
        final mediaCol = (usable - crossGap * (prefs.gridColumns - 1)) / prefs.gridColumns;
        final mediaLabel = labelExtent(prefs);
        final mediaRatio = mediaCol / (mediaCol + mediaLabel);

        // 文件夹网格走 maxCrossAxisExtent，列数由框架算，这里复现同一套规则
        final folderCols = (usable / 150).ceil().clamp(1, 99);
        final folderCol = (usable - crossGap * (folderCols - 1)) / folderCols;
        final folderRatio = folderCol / (folderCol + folderLabelExtent);

        return _pinchWrap(CustomScrollView(
        controller: _scrollCtrl,
        physics: _pinching
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        slivers: [
          // 面包屑 + 搜索框：都躺在内容里，不占顶栏。
          // 用 SliverOpacity 而不是 `if (...)` 增删 sliver —— 增删会让后续
          // sliver 整体位移，滚动位置跟着乱跳。
          _buildInlineHeader(c),
          // folders section
          if (_folders.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                child: Text('文件夹',
                    style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus,
                        fontWeight: FontWeight.w700, letterSpacing: -0.3)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 150,
                  mainAxisSpacing: 16, crossAxisSpacing: crossGap,
                  childAspectRatio: folderRatio,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => FolderThumb(
                    key: ValueKey(_folders[i].id),
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
                    padding: const EdgeInsets.fromLTRB(16, 28, 16, 12),
                    child: Row(children: [
                      Text(group.label,
                          style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus,
                              fontWeight: FontWeight.w700, letterSpacing: -0.3)),
                      const Spacer(),
                      if (_selecting)
                        Icon(
                          group.items.every((m) => _selected.contains(m.id))
                              ? Icons.check_box : Icons.check_box_outline_blank,
                          size: AppIconSize.lg,
                          color: group.items.every((m) => _selected.contains(m.id))
                              ? c.brand : c.onMuted,
                        ),
                    ]),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: prefs.gridColumns,
                  mainAxisSpacing: 16, crossAxisSpacing: crossGap,
                  childAspectRatio: mediaRatio,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => DragSelectItem(
                    index: indexOfId[group.items[i].id] ?? -1,
                    child: MediaThumb(
                    key: ValueKey(group.items[i].id),
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
                    onSecondaryTap: _isDesktop && !_selecting
                        ? (pos) => _showItemContextMenu(pos, group.items[i], c)
                        : null,
                    ),
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
      ));
      }),
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
      scale = _settleFrom + (1.0 - _settleFrom) * Curves.easeOutCubic
          .transform(_settleCtrl.value);
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

// ── 分组：见 gallery_groups.dart ──

