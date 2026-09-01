import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/display_prefs.dart';
import '../../core/media_service.dart';
import '../../core/server_state.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';
import 'media_viewer.dart';
import 'settings_sheet.dart';

bool get _isDesktop {
  final p = defaultTargetPlatform;
  return p == TargetPlatform.macOS ||
      p == TargetPlatform.windows ||
      p == TargetPlatform.linux;
}

class GalleryView extends StatefulWidget {
  const GalleryView({super.key});

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final List<MediaItem> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  int _page = 1;
  int _total = 0;

  bool _selecting = false;
  final Set<String> _selected = {};

  bool _uploading = false;
  int _uploadCompleted = 0;
  int _uploadTotal = 0;

  int? _viewerIndex;
  MediaService? _service;

  DisplayPrefs? _lastPrefs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.watch<ServerState>();
    final prefs = context.watch<DisplayPrefs>();

    if (state.active != null && _service == null) {
      _service = MediaService(state);
      _tryConnect(state, prefs);
    }
  }

  Future<void> _tryConnect(ServerState state, DisplayPrefs prefs) async {
    try {
      final service = MediaService(state);
      final stats = await service.fetchInfo();
      state.updateStats(stats);
      state.connect(state.active!);
      _service = service;
      _lastPrefs = prefs;
      _reload(prefs);
    } catch (_) {
      state.setConnecting();
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && state.status != ConnectionStatus.connected) {
          _tryConnect(state, prefs);
        }
      });
    }
  }

  void _onPrefsChanged(DisplayPrefs prefs) {
    _lastPrefs = prefs;
    _reload(prefs);
  }

  Future<void> _reload(DisplayPrefs prefs) async {
    setState(() { _items.clear(); _page = 1; _hasMore = true; _total = 0; });
    await _loadPage(prefs);
  }

  Map<String, dynamic> _buildFilter(DisplayPrefs prefs) {
    final conditions = <Map<String, dynamic>>[
      {'field': 'deleted_at', 'op': 'is_null'},
    ];

    if (prefs.mediaFilter == MediaFilter.photosOnly) {
      conditions.add({'field': 'media_type', 'op': '=', 'value': 'image'});
    } else if (prefs.mediaFilter == MediaFilter.videosOnly) {
      conditions.add({'field': 'media_type', 'op': '=', 'value': 'video'});
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
        'value': [prefs.dateFrom!.toIso8601String(),
                   prefs.dateTo!.add(const Duration(days: 1)).toIso8601String()],
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
    setState(() => _loading = true);
    try {
      final result = await _service!.query(
        page: _page,
        size: 50,
        filter: _buildFilter(prefs),
        sort: _buildSort(prefs),
      );
      setState(() {
        _items.addAll(result.items);
        _total = result.total;
        _hasMore = _items.length < result.total;
        _page++;
        _loading = false;
      });
    } catch (e) {
      debugPrint('query error: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    final prefs = context.read<DisplayPrefs>();
    await _reload(prefs);
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

  void _exitSelection() {
    setState(() { _selecting = false; _selected.clear(); });
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
    _refresh();
  }

  Future<void> _downloadSelected() async {
    if (_selected.isEmpty || _service == null) return;
    await _service!.downloadBatch(_selected.toList());
    if (mounted) { showToast(context, '下载完成'); _exitSelection(); }
  }

  // ── 上传 ──

  Future<void> _pickAndUpload() async {
    if (_service == null || _uploading) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif',
        'mp4', 'mov', 'avi', 'mkv',
      ],
    );
    final files = picked
        .where((f) => f.path != null)
        .map((f) => File(f.path!))
        .toList();
    if (files.isEmpty) return;

    setState(() { _uploading = true; _uploadCompleted = 0; _uploadTotal = files.length; });
    try {
      await _service!.upload(files, onProgress: (c, t) {
        if (mounted) setState(() { _uploadCompleted = c; _uploadTotal = t; });
      });
      if (mounted) { showToast(context, '已上传 ${files.length} 个文件'); _refresh(); }
    } catch (e) {
      if (mounted) showToast(context, '上传失败: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
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

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bg,
      drawer: _isDesktop ? _buildLeftDrawer(c) : null,
      endDrawer: _isDesktop ? _buildRightDrawer(c, prefs) : null,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              _buildToolbar(c, state, prefs),
              if (_uploading) _buildUploadBar(c),
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
    );
  }

  Widget _buildLeftDrawer(AppColors c) {
    return Drawer(
      width: 360,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('设置', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
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
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('显示设置', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
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
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          // 左：头像 → 全局设置
          IconButton(
            onPressed: _openProfile,
            icon: Container(
              width: 28, height: 28,
              decoration: BoxDecoration(color: c.surface2, shape: BoxShape.circle),
              child: Icon(Icons.person, size: 16, color: c.onSurfaceVariant),
            ),
            tooltip: '设置',
          ),
          if (!connected)
            Text('未连接', style: TextStyle(color: c.onMuted, fontSize: AppType.xs)),
          if (connected && _total > 0)
            Text('$_total', style: TextStyle(color: c.onMuted, fontSize: AppType.xs)),

          const Spacer(),

          if (_selecting) ...[
            Text('${_selected.length} 已选',
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm, fontWeight: FontWeight.w600)),
            IconButton(onPressed: _downloadSelected,
                icon: Icon(Icons.download, size: AppIconSize.lg, color: c.brand), tooltip: '下载'),
            IconButton(onPressed: _deleteSelected,
                icon: Icon(Icons.delete_outline, size: AppIconSize.lg, color: c.error), tooltip: '删除'),
            IconButton(onPressed: _exitSelection,
                icon: Icon(Icons.close, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '取消'),
          ] else ...[
            if (connected && _items.isNotEmpty)
              IconButton(onPressed: () => setState(() => _selecting = true),
                  icon: Icon(Icons.checklist, size: AppIconSize.lg, color: c.onSurfaceVariant), tooltip: '多选'),
            if (connected)
              IconButton(
                  onPressed: _uploading ? null : _pickAndUpload,
                  icon: Icon(Icons.add_photo_alternate, size: AppIconSize.lg,
                      color: _uploading ? c.onMuted : c.brand), tooltip: '上传'),
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

  Widget _buildUploadBar(AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(children: [
        SizedBox(width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.brand,
                value: _uploadTotal > 0 ? _uploadCompleted / _uploadTotal : null)),
        const SizedBox(width: 10),
        Text('上传中 $_uploadCompleted / $_uploadTotal',
            style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs)),
      ]),
    );
  }

  Widget _buildBody(AppColors c, ServerState state, DisplayPrefs prefs) {
    if (state.status != ConnectionStatus.connected) {
      return AppEmptyState(icon: Icons.wifi_off, message: '未连接到服务器',
          action: AppButton(label: '去连接', onTap: _openProfile));
    }

    if (_items.isEmpty && !_loading) {
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

    final groups = _buildGroups(_items, prefs);

    return RefreshIndicator(
      onRefresh: _refresh, color: c.brand,
      child: CustomScrollView(
        slivers: [
          for (final group in groups) ...[
            if (group.label.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(group.label,
                      style: TextStyle(color: c.onMuted, fontSize: AppType.xs, fontWeight: FontWeight.w600)),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: prefs.thumbMaxExtent,
                  mainAxisSpacing: 2, crossAxisSpacing: 2,
                  childAspectRatio: prefs.labelPosition == LabelPosition.below && prefs.hasLabel ? 0.78 : 1.0,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _Thumb(
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
          if (_loading)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(24), child: AppSpinner())),
          if (_hasMore && !_loading)
            SliverToBoxAdapter(child: _LoadMoreTrigger(onVisible: () => _loadPage(prefs))),
        ],
      ),
    );
  }
}

// ── 分组 ──

class _Group { final String label; final List<MediaItem> items; _Group(this.label, this.items); }

List<_Group> _buildGroups(List<MediaItem> items, DisplayPrefs prefs) {
  if (prefs.groupMode == GroupMode.none) return [_Group('', items)];
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final Map<String, List<MediaItem>> map = {};
  for (final item in items) {
    final date = DateTime.tryParse(item.displayDate);
    String label;
    if (date == null) { label = '未知日期'; }
    else {
      final d = DateTime(date.year, date.month, date.day);
      switch (prefs.groupMode) {
        case GroupMode.day:
          if (d == today) label = '今天';
          else if (d == yesterday) label = '昨天';
          else if (d.year == now.year) label = '${d.month}月${d.day}日';
          else label = '${d.year}年${d.month}月${d.day}日';
        case GroupMode.month:
          label = d.year == now.year ? '${d.month}月' : '${d.year}年${d.month}月';
        case GroupMode.year:
          label = '${d.year}年';
        case GroupMode.none:
          label = '';
      }
    }
    map.putIfAbsent(label, () => []).add(item);
  }
  return map.entries.map((e) => _Group(e.key, e.value)).toList();
}

// ── 缩略图 ──

class _Thumb extends StatelessWidget {
  final MediaItem item; final MediaService service;
  final bool selected; final bool selecting;
  final DisplayPrefs prefs;
  final VoidCallback onTap; final VoidCallback onLongPress;

  const _Thumb({required this.item, required this.service,
    required this.selected, required this.selecting,
    required this.prefs, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final showBelow = prefs.hasLabel && prefs.labelPosition == LabelPosition.below;
    return GestureDetector(
      onTap: onTap, onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: Stack(fit: StackFit.expand, children: [
            Container(color: c.surface2, child: Image.network(
              service.thumbUrl(item.id), fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(Icons.broken_image, color: c.onMuted, size: 32),
            )),
            if (item.isVideo)
              Positioned(right: 4, bottom: 4, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                child: const Icon(Icons.play_arrow, size: 14, color: Colors.white),
              )),
            if (prefs.hasLabel && prefs.labelPosition == LabelPosition.overlay)
              Positioned(left: 0, right: 0, bottom: 0, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                decoration: const BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [Colors.black54, Colors.transparent],
                )),
                child: _label(Colors.white70, Colors.white54),
              )),
            if (selecting) Positioned(right: 6, top: 6, child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: selected ? c.brand : Colors.black38, shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5)),
              child: selected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
            )),
          ])),
          if (showBelow) Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: _label(c.onSurface, c.onMuted),
          ),
        ],
      ),
    );
  }

  Widget _label(Color primary, Color secondary) {
    final parts = <Widget>[];
    final ts = TextStyle(color: secondary, fontSize: 9);
    if (prefs.showName) parts.add(Text(item.filename, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: primary, fontSize: 9, fontWeight: FontWeight.w500)));
    if (prefs.showTime) {
      final date = DateTime.tryParse(item.displayDate);
      final text = date != null ? DateFormat('MM/dd HH:mm').format(date) : '';
      if (text.isNotEmpty) parts.add(Text(text, maxLines: 1, style: ts));
    }
    if (prefs.showSize) {
      final s = item.size;
      final text = s < 1024 * 1024 ? '${(s / 1024).toStringAsFixed(0)} KB' : '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
      parts.add(Text(text, maxLines: 1, style: ts));
    }
    if (prefs.showDimensions && item.width != null && item.height != null) {
      parts.add(Text('${item.width}×${item.height}', maxLines: 1, style: ts));
    }
    if (prefs.showCamera && (item.exifMake != null || item.exifModel != null)) {
      parts.add(Text([item.exifMake, item.exifModel].whereType<String>().join(' '),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: ts));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: parts);
  }
}

class _LoadMoreTrigger extends StatefulWidget {
  final VoidCallback onVisible;
  const _LoadMoreTrigger({required this.onVisible});
  @override State<_LoadMoreTrigger> createState() => _LoadMoreTriggerState();
}

class _LoadMoreTriggerState extends State<_LoadMoreTrigger> {
  @override void initState() { super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onVisible()); }
  @override Widget build(BuildContext context) => const SizedBox(height: 1);
}
