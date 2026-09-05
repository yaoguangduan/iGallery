import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/hash_sync.dart';
import '../../core/time_fmt.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'asset_hash_verifier.dart';
import 'app_toast.dart';
import 'drag_select.dart';
import 'folder_picker.dart';
import 'gallery_view.dart';

class LocalPhotosTab extends StatefulWidget {
  final GalleryShellHost? shell;
  final bool active;
  const LocalPhotosTab({super.key, this.shell, this.active = true});

  @override
  State<LocalPhotosTab> createState() => _LocalPhotosTabState();
}

class _LocalPhotosTabState extends State<LocalPhotosTab> {
  static const int _cols = 4;
  static const double _gap = 2;
  static const double _pad = 2;
  static const int _pageSize = 80;

  final _scrollCtrl = ScrollController();

  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _album;
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = [];
  final Set<String> _selectedIds = {};

  bool _loading = true;
  bool _loadingMore = false;
  bool _pagingBlocked = false;
  int _total = 0;
  int _page = 0;
  int _albumRequest = 0;
  String? _permissionError;
  bool _inited = false;

  int? _sweepAnchor;
  bool _sweepAdding = true;
  Set<String> _sweepBaseline = {};

  final Map<String, String> _assetChecksums = {};
  late final AssetHashVerifier _hashVerifier;
  bool _wasUploading = false;

  @override
  void initState() {
    super.initState();
    _hashVerifier = AssetHashVerifier(
      onResolved: (assetId, checksum) {
        if (!mounted || !widget.active) return;
        setState(() => _assetChecksums[assetId] = checksum);
      },
    );
    _wasUploading = UploadManager.instance.uploading;
    HashSync.instance.addListener(_onHashSyncChanged);
    UploadManager.instance.addListener(_onUploadChanged);
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant LocalPhotosTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _hashVerifier.stop();
    } else if (!oldWidget.active && widget.active) {
      _scheduleVisibleVerification();
    }
  }

  @override
  void dispose() {
    HashSync.instance.removeListener(_onHashSyncChanged);
    UploadManager.instance.removeListener(_onUploadChanged);
    _hashVerifier.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onHashSyncChanged() {
    if (!mounted || !widget.active) return;
    setState(() {});
    _scheduleVisibleVerification();
  }

  void _onUploadChanged() {
    final uploading = UploadManager.instance.uploading;
    if (!_wasUploading && uploading) {
      _hashVerifier.stop();
    }
    if (_wasUploading && !uploading && mounted && widget.active) {
      setState(() {});
      _scheduleVisibleVerification();
    }
    _wasUploading = uploading;
  }

  Future<void> _bootstrap() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (!ps.hasAccess) {
      setState(() {
        _loading = false;
        _permissionError = '没有相册访问权限';
      });
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (!mounted) return;
    albums.sort((a, b) {
      if (a.isAll != b.isAll) return a.isAll ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    setState(() {
      _albums = albums;
      _inited = true;
    });
    if (albums.isEmpty) {
      setState(() => _loading = false);
    } else {
      await _switchAlbum(albums.first);
    }
  }

  Future<void> _switchAlbum(AssetPathEntity album) async {
    final request = ++_albumRequest;
    _hashVerifier.stop();
    setState(() {
      _album = album;
      _assetChecksums.clear();
      _loading = true;
      _loadingMore = false;
      _pagingBlocked = false;
      _assets.clear();
      _selected.clear();
      _selectedIds.clear();
      _page = 0;
      _total = 0;
    });
    _syncSelection();
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    try {
      final total = await album.assetCountAsync;
      final list = await album.getAssetListPaged(page: 0, size: _pageSize);
      if (!mounted || request != _albumRequest) return;
      _fillFromCache(list);
      setState(() {
        _total = total;
        _assets.addAll(list);
        _loading = false;
      });
      _scheduleLocalViewportFill();
      _scheduleAllVerification();
    } catch (_) {
      if (!mounted || request != _albumRequest) return;
      setState(() => _loading = false);
      showToast(context, '本地相册加载失败', kind: ToastKind.error);
    }
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (_loadingMore ||
        _pagingBlocked ||
        album == null ||
        _assets.length >= _total) {
      return;
    }
    final request = _albumRequest;
    final next = _page + 1;
    var loadedPage = false;
    setState(() => _loadingMore = true);
    try {
      final list = await album.getAssetListPaged(page: next, size: _pageSize);
      if (!mounted || request != _albumRequest || album.id != _album?.id) {
        return;
      }
      final loadedIds = _assets.map((asset) => asset.id).toSet();
      final fresh = list
          .where((asset) => loadedIds.add(asset.id))
          .toList(growable: false);
      _fillFromCache(fresh);
      setState(() {
        _page = next;
        _assets.addAll(fresh);
        _pagingBlocked = fresh.isEmpty && _assets.length < _total;
      });
      loadedPage = fresh.isNotEmpty;
      _syncSelection();
    } catch (_) {
      if (mounted && request == _albumRequest) {
        showToast(context, '加载更多失败，请稍后重试', kind: ToastKind.error);
      }
    } finally {
      if (mounted && request == _albumRequest) {
        setState(() => _loadingMore = false);
        if (loadedPage) {
          _scheduleLocalViewportFill();
          _scheduleAllVerification();
        }
      }
    }
  }

  void _scheduleLocalViewportFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollCtrl.hasClients ||
          _loadingMore ||
          _pagingBlocked) {
        return;
      }
      if (_assets.length < _total && _scrollCtrl.position.extentAfter <= 400) {
        _loadMore();
      }
    });
  }

  void _fillFromCache(List<AssetEntity> assets) {
    for (final asset in assets) {
      if (_assetChecksums.containsKey(asset.id)) continue;
      final fp = assetFingerprint(asset);
      final cached = HashSync.instance.assetChecksumSync(asset.id, fp);
      if (cached != null) _assetChecksums[asset.id] = cached;
    }
  }

  void _scheduleVisibleVerification() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active || UploadManager.instance.uploading) {
        return;
      }
      final visible = visibleGridAssets(
        assets: _assets,
        controller: _scrollCtrl,
        width: MediaQuery.sizeOf(context).width,
        columns: _cols,
        gap: _gap,
        padding: _pad,
      ).where((asset) => !_assetChecksums.containsKey(asset.id));
      _hashVerifier.verify(visible);
    });
  }

  void _scheduleAllVerification() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active || UploadManager.instance.uploading) {
        return;
      }
      final uncached = _assets
          .where((asset) => !_assetChecksums.containsKey(asset.id));
      if (uncached.isEmpty) return;
      _hashVerifier.verify(uncached);
    });
  }

  // ── 选择 ──

  bool get _selecting => _selected.isNotEmpty;
  bool get _allLoadedSelected =>
      _assets.isNotEmpty && _selectedIds.length == _assets.length;

  bool _isSelected(AssetEntity asset) => _selectedIds.contains(asset.id);

  void _toggle(AssetEntity asset) {
    setState(() => _setSelected(asset, !_selectedIds.contains(asset.id)));
    _syncSelection();
  }

  void _setSelected(AssetEntity asset, bool on) {
    if (on && _selectedIds.add(asset.id)) {
      _selected.add(asset);
    } else if (!on && _selectedIds.remove(asset.id)) {
      _selected.removeWhere((item) => item.id == asset.id);
    }
  }

  void _toggleSelectAllLoaded() {
    setState(() {
      if (_allLoadedSelected) {
        _selected.clear();
        _selectedIds.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_assets);
        _selectedIds
          ..clear()
          ..addAll(_assets.map((asset) => asset.id));
      }
    });
    _syncSelection();
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectedIds.clear();
    });
    _syncSelection();
  }

  void _syncSelection() {
    widget.shell?.updateSelection(
      sourceTab: 2,
      selecting: _selected.isNotEmpty,
      selectedIds: Set<String>.from(_selectedIds),
      allSelected: _allLoadedSelected,
      allFavorite: false,
      mode: SelectionActionMode.localUpload,
      onToggleSelectAll: _toggleSelectAllLoaded,
      onUpload: _uploadSelected,
      onDelete: _deleteSelected,
      onExitSelection: _clearSelection,
    );
  }

  // ── 滑选 ──

  bool _sweepStart(int index) {
    if (index < 0 || index >= _assets.length) return false;
    final asset = _assets[index];
    _sweepAnchor = index;
    _sweepAdding = !_isSelected(asset);
    _sweepBaseline = _selected.map((e) => e.id).toSet();
    setState(() => _setSelected(asset, _sweepAdding));
    return true;
  }

  void _sweepTo(int index) {
    final anchor = _sweepAnchor;
    if (anchor == null) return;
    if (index < 0 || index >= _assets.length) return;
    final lo = anchor < index ? anchor : index;
    final hi = anchor < index ? index : anchor;
    setState(() {
      for (var i = 0; i < _assets.length; i++) {
        final a = _assets[i];
        if (i < lo || i > hi) {
          _setSelected(a, _sweepBaseline.contains(a.id));
        } else {
          _setSelected(a, _sweepAdding);
        }
      }
    });
  }

  void _sweepEnd() {
    _sweepAnchor = null;
    _sweepBaseline = {};
    _syncSelection();
  }

  // ── 预览 ──

  Future<void> _previewAsset(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null || !mounted) return;
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _LocalPreviewPage(file: file, asset: asset),
      ),
    );
    if (deleted == true && mounted && _album != null) {
      _switchAlbum(_album!);
    }
  }

  Future<void> _previewAssetInSelection(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null || !mounted) return;
    final selected = _selectedIds.contains(asset.id);
    final result = await Navigator.of(context).push<_SelectionPreviewResult>(
      MaterialPageRoute(
        builder: (_) => _SelectionPreviewPage(
          file: file,
          asset: asset,
          selected: selected,
          selectedCount: _selected.length,
        ),
      ),
    );
    if (!mounted) return;
    if (result != null) {
      if (result.selected != selected) _toggle(asset);
    }
  }

  // ── 上传选中项 ──

  Future<void> _uploadSelected() async {
    if (_selected.isEmpty) return;
    final toUpload = List<AssetEntity>.from(_selected);
    final files = <PendingUpload>[];
    var failed = 0;
    for (final a in toUpload) {
      try {
        final f = await a.file;
        if (f != null) {
          files.add(
            PendingUpload(
              f,
              takenAtIso: toServerRfc3339(a.createDateTime),
              assetId: a.id,
              assetFingerprint: assetFingerprint(a),
            ),
          );
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    if (files.isEmpty) {
      showToast(context, '无法读取所选文件', kind: ToastKind.error);
      return;
    }
    if (failed > 0) {
      showToast(context, '$failed 个文件读取失败，已跳过', kind: ToastKind.info);
    }
    await showFolderPickerAndUpload(context, files);
  }

  // ── 删除选中的本地文件 ──

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await appConfirmDialog(
      context,
      title: '删除本地文件',
      message: '确定删除选中的 $count 个本地文件？\n\n已上传到服务器的不受影响。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      final ids = _selected.map((a) => a.id).toList();
      final deleted = await PhotoManager.editor.deleteWithIds(ids);
      if (!mounted) return;
      final ok = deleted.length;
      final fail = count - ok;
      if (fail == 0) {
        showToast(context, '已删除 $ok 个本地文件', kind: ToastKind.success);
      } else {
        showToast(context, '删除 $ok 个，$fail 个失败', kind: ToastKind.error);
      }
    } catch (e) {
      if (mounted) showToast(context, '删除失败: $e', kind: ToastKind.error);
    }
    _clearSelection();
    if (_album != null) _switchAlbum(_album!);
  }

  // ── 相册切换 ──

  void _showAlbumSheet(AppColors c) {
    showModalBottomSheet(
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
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, sc) => Column(
          children: [
            const SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text(
                    '选择相册',
                    style: TextStyle(
                      color: c.onSurface,
                      fontSize: AppType.mdPlus,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: sc,
                itemCount: _albums.length,
                itemBuilder: (ctx, i) {
                  final album = _albums[i];
                  final active = album.id == _album?.id;
                  return ListTile(
                    leading: SizedBox(
                      width: 44,
                      height: 44,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                        child: _AlbumCover(
                          key: ValueKey(album.id),
                          album: album,
                        ),
                      ),
                    ),
                    title: Text(
                      album.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: active ? c.brand : c.onSurface,
                        fontSize: AppType.sm,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    subtitle: FutureBuilder<int>(
                      future: album.assetCountAsync,
                      builder: (ctx, snap) => Text(
                        '${snap.data ?? 0} 项',
                        style: TextStyle(
                          color: c.onMuted,
                          fontSize: AppType.xxs,
                        ),
                      ),
                    ),
                    trailing: active
                        ? Icon(
                            Icons.check,
                            color: c.brand,
                            size: AppIconSize.lg,
                          )
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!active) _switchAlbum(album);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        _buildToolbar(c),
        Expanded(child: _buildBody(c)),
      ],
    );
  }

  Widget _buildToolbar(AppColors c) {
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
              onPressed: _clearSelection,
              icon: Icon(
                Icons.close_rounded,
                size: AppIconSize.lg,
                color: c.onSurface,
              ),
            )
          else
            _buildAlbumTitle(c),
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
            const Spacer(),
          ],
        ],
      ),
    );
  }

  Widget _buildAlbumTitle(AppColors c) {
    if (!_inited || _albums.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          '本地',
          style: TextStyle(
            color: c.onSurface,
            fontSize: AppType.mdPlus,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () => _showAlbumSheet(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                _album?.name ?? '本地',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.onSurface,
                  fontSize: AppType.mdPlus,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down, color: c.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    if (_permissionError != null) {
      return AppEmptyState(
        icon: Icons.no_photography_outlined,
        message: _permissionError!,
        action: AppButton(label: '去设置', onTap: PhotoManager.openSetting),
      );
    }
    if (_loading && _assets.isEmpty) return const Center(child: AppSpinner());
    if (_assets.isEmpty) {
      return Center(
        child: Text(
          '此相册为空',
          style: TextStyle(color: c.onMuted, fontSize: AppType.sm),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: DragSelectDetector(
            enabled: _selecting,
            onStart: _sweepStart,
            onEnter: _sweepTo,
            onEnd: _sweepEnd,
            scrollController: _scrollCtrl,
            child: AppScrollbar(
              controller: _scrollCtrl,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollEndNotification) {
                    _scheduleVisibleVerification();
                  }
                  if (notification.metrics.extentAfter <= 400) _loadMore();
                  return false;
                },
                child: GridView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(_pad),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _cols,
                    mainAxisSpacing: _gap,
                    crossAxisSpacing: _gap,
                  ),
                  itemCount: _assets.length,
                  itemBuilder: (ctx, i) => RepaintBoundary(
                    child: DragSelectItem(
                      index: i,
                      child: _buildCell(c, _assets[i]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_loadingMore)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpace.md,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: AppSpace.sm,
                ),
                decoration: BoxDecoration(
                  color: c.scrimStrong,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  '加载中 ${_assets.length} / $_total',
                  style: TextStyle(color: c.onScrim, fontSize: AppType.xxs),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCell(AppColors c, AssetEntity asset) {
    final selected = _selectedIds.contains(asset.id);
    final selIdx = selected
        ? _selected.indexWhere((e) => e.id == asset.id)
        : -1;
    final checksum = _assetChecksums[asset.id];
    final uploaded = checksum != null && HashSync.instance.contains(checksum);
    final isVideo = asset.type == AssetType.video;
    return QuickLongPress(
      onTap: () {
        if (_selecting) {
          _previewAssetInSelection(asset);
        } else {
          _previewAsset(asset);
        }
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        if (!_selecting) setState(() {});
        _toggle(asset);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AssetThumb(key: ValueKey(asset.id), asset: asset),
          if (selected) ColoredBox(color: c.onScrim.withValues(alpha: 0.28)),
          if (isVideo)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: c.scrimMedium,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _fmtDuration(asset.duration),
                  style: TextStyle(color: c.onScrim, fontSize: AppType.xxs),
                ),
              ),
            ),
          if (uploaded)
            const Positioned(left: 4, top: 4, child: UploadedBadge()),
          if (_selecting)
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: selected ? c.brand : c.scrimSoft,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.onScrim, width: 1.5),
                ),
                child: selected
                    ? Center(
                        child: Text(
                          '${selIdx + 1}',
                          style: TextStyle(
                            color: c.onScrim,
                            fontSize: AppType.xxs,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  static String _fmtDuration(int secs) {
    final d = Duration(seconds: secs);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
}

class _AssetThumb extends StatefulWidget {
  final AssetEntity asset;
  const _AssetThumb({super.key, required this.asset});

  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends State<_AssetThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _AssetThumb old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.asset.id;
    try {
      final data = await widget.asset.thumbnailDataWithSize(
        const ThumbnailSize.square(240),
      );
      if (!mounted || widget.asset.id != id) return;
      setState(() => _bytes = data);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return ColoredBox(color: context.colors.surface2);
    return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

class _AlbumCover extends StatefulWidget {
  final AssetPathEntity album;
  const _AlbumCover({super.key, required this.album});

  @override
  State<_AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<_AlbumCover> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.album.getAssetListRange(start: 0, end: 1);
      if (list.isEmpty) return;
      final data = await list.first.thumbnailDataWithSize(
        const ThumbnailSize.square(120),
      );
      if (!mounted) return;
      setState(() => _bytes = data);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return ColoredBox(color: context.colors.surface2);
    return Image.memory(b, fit: BoxFit.cover);
  }
}

class _LocalPreviewPage extends StatefulWidget {
  final File file;
  final AssetEntity asset;
  const _LocalPreviewPage({required this.file, required this.asset});

  @override
  State<_LocalPreviewPage> createState() => _LocalPreviewPageState();
}

class _LocalPreviewPageState extends State<_LocalPreviewPage> {
  Player? _player;
  VideoController? _controller;

  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      _player = Player();
      _controller = VideoController(_player!);
      _player!.open(Media(widget.file.path), play: true);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    final file = widget.file;
    final takenAt = toServerRfc3339(widget.asset.createDateTime);
    final fp = assetFingerprint(widget.asset);
    if (!mounted) return;
    await showFolderPickerAndUpload(context, [
      PendingUpload(
        file,
        takenAtIso: takenAt,
        assetId: widget.asset.id,
        assetFingerprint: fp,
      ),
    ]);
  }

  Future<void> _share() async {
    final file = widget.file;
    final mime = _isVideo ? 'video/*' : 'image/*';
    await Share.shareXFiles(
      [XFile(file.path, mimeType: mime)],
    );
  }

  Future<void> _delete() async {
    final ok = await appConfirmDialog(
      context,
      title: '删除本地文件',
      message: '确定删除？已上传到服务器的不受影响。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      final deleted = await PhotoManager.editor.deleteWithIds([widget.asset.id]);
      if (!mounted) return;
      if (deleted.isNotEmpty) {
        showToast(context, '已删除', kind: ToastKind.success);
        Navigator.pop(context, true);
      } else {
        showToast(context, '删除失败', kind: ToastKind.error);
      }
    } catch (e) {
      if (mounted) showToast(context, '删除失败: $e', kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          title: Text(
            widget.asset.title ?? widget.file.path.split('/').last,
            style: const TextStyle(fontSize: 14, color: Colors.white70),
          ),
          actions: [
            IconButton(
              onPressed: _upload,
              icon: const Icon(Icons.upload_rounded, size: 22),
              tooltip: '上传',
            ),
            IconButton(
              onPressed: _share,
              icon: const Icon(Icons.share, size: 20),
              tooltip: '分享',
            ),
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline, size: 22),
              tooltip: '删除',
            ),
          ],
        ),
        body: _isVideo
            ? Video(
                controller: _controller!,
                fill: Colors.black,
                controls: AdaptiveVideoControls,
              )
            : PhotoView(
                imageProvider: FileImage(widget.file),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 3,
                backgroundDecoration: const BoxDecoration(color: Colors.black),
              ),
      ),
    );
  }
}

// ── 选择态预览 ──

class _SelectionPreviewResult {
  final bool selected;
  _SelectionPreviewResult({required this.selected});
}

class _SelectionPreviewPage extends StatefulWidget {
  final File file;
  final AssetEntity asset;
  final bool selected;
  final int selectedCount;

  const _SelectionPreviewPage({
    required this.file,
    required this.asset,
    required this.selected,
    required this.selectedCount,
  });

  @override
  State<_SelectionPreviewPage> createState() => _SelectionPreviewPageState();
}

class _SelectionPreviewPageState extends State<_SelectionPreviewPage> {
  Player? _player;
  VideoController? _controller;
  late bool _selected;

  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected;
    if (_isVideo) {
      _player = Player();
      _controller = VideoController(_player!);
      _player!.open(Media(widget.file.path), play: true);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  void _toggleSelect() {
    setState(() => _selected = !_selected);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final count = widget.selectedCount + (_selected != widget.selected
        ? (_selected ? 1 : -1)
        : 0);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.pop(context, _SelectionPreviewResult(selected: _selected));
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            elevation: 0,
            title: Text(
              '已选 $count',
              style: const TextStyle(fontSize: 16, color: Colors.white),
            ),
            actions: [
              IconButton(
                onPressed: _toggleSelect,
                icon: Icon(
                  _selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: _selected ? c.brand : Colors.white70,
                  size: 26,
                ),
                tooltip: _selected ? '取消选择' : '选择',
              ),
            ],
          ),
          body: _isVideo
              ? Video(
                  controller: _controller!,
                  fill: Colors.black,
                  controls: AdaptiveVideoControls,
                )
              : PhotoView(
                  imageProvider: FileImage(widget.file),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 3,
                  backgroundDecoration:
                      const BoxDecoration(color: Colors.black),
                ),
        ),
      ),
    );
  }
}
