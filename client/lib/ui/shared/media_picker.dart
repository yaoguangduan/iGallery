import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_view/photo_view.dart';

import '../../core/hash_sync.dart';
import '../../core/time_fmt.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'asset_hash_verifier.dart';
import 'app_toast.dart';
import 'drag_select.dart';
import 'preview_video.dart';

enum UploadSource { photos, files }

Future<UploadSource?> showUploadSourcePicker(BuildContext context) {
  final c = context.colors;
  return showModalBottomSheet<UploadSource>(
    context: context,
    backgroundColor: c.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              0,
              AppSpace.lg,
              AppSpace.sm,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '选择上传来源',
                style: TextStyle(
                  color: c.onSurface,
                  fontSize: AppType.mdPlus,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              Icons.photo_library_outlined,
              color: c.onSurfaceVariant,
            ),
            title: Text(
              '从相册选择',
              style: TextStyle(
                color: c.onSurface,
                fontSize: AppType.sm,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '图片和视频，可连续多选',
              style: TextStyle(color: c.onMuted, fontSize: AppType.xxs),
            ),
            onTap: () => Navigator.pop(sheetContext, UploadSource.photos),
          ),
          ListTile(
            leading: Icon(
              Icons.folder_open_outlined,
              color: c.onSurfaceVariant,
            ),
            title: Text(
              '从文件选择',
              style: TextStyle(
                color: c.onSurface,
                fontSize: AppType.sm,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '打开系统文件浏览器，可跨文件夹多选',
              style: TextStyle(color: c.onMuted, fontSize: AppType.xxs),
            ),
            onTap: () => Navigator.pop(sheetContext, UploadSource.files),
          ),
          const SizedBox(height: AppSpace.sm),
        ],
      ),
    ),
  );
}

/// 微信风格选择器：相册分类 + 网格 + 长按滑动连续多选。
/// pop 返回 `List<PendingUpload>`（取消返回空列表）。
///
/// 必须带上 AssetEntity.createDateTime —— 导出的 File 是缓存副本，
/// mtime 是导出时刻而非拍摄时间，光靠服务端兜底拿不到真实拍摄时间。
class MediaPickerPage extends StatefulWidget {
  final int maxSelect;
  const MediaPickerPage({super.key, this.maxSelect = 500});

  @override
  State<MediaPickerPage> createState() => _MediaPickerPageState();
}

class _MediaPickerPageState extends State<MediaPickerPage> {
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
  bool _resolving = false;
  int _total = 0;
  int _page = 0;
  int _albumRequest = 0;
  String? _permissionError;

  // 长按滑动连续选择
  int? _sweepAnchor;
  bool _sweepAdding = true;
  Set<String> _sweepBaseline = {};

  final Map<String, String> _assetChecksums = {};
  late final AssetHashVerifier _hashVerifier;

  @override
  void initState() {
    super.initState();
    _hashVerifier = AssetHashVerifier(
      onResolved: (assetId, checksum) {
        if (!mounted) return;
        setState(() => _assetChecksums[assetId] = checksum);
      },
    );
    HashSync.instance.addListener(_onHashSyncChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    HashSync.instance.removeListener(_onHashSyncChanged);
    _hashVerifier.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onHashSyncChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleVisibleVerification();
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
    setState(() => _albums = albums);
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
      // 跨相册不允许选择：切相册即取消已选（否则旧相册的选中项会 invisibly 挂着，
      // 且从预览返回 reconcile 只按当前相册重建会把它们丢掉，造成"确定(N)"数字对不上）
      _selected.clear();
      _selectedIds.clear();
      _page = 0;
      _total = 0;
    });
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
      _scheduleViewportFill();
      _scheduleAllVerification();
    } catch (_) {
      if (!mounted || request != _albumRequest) return;
      setState(() => _loading = false);
      showToast(context, '相册加载失败', kind: ToastKind.error);
    }
  }

  Future<void> _loadMore() async {
    final album = _album;
    // 不再用 _assets.length >= _total 当停止条件：_total 是切相册那一刻的快照，
    // 之后新增的照片会让它偏小，导致"以为加载完了"而漏掉后面的。
    if (_loadingMore || _pagingBlocked || album == null) {
      return;
    }
    final request = _albumRequest;
    final next = _page + 1;
    var rawCount = 0;
    var freshCount = 0;
    setState(() => _loadingMore = true);
    try {
      final list = await album.getAssetListPaged(page: next, size: _pageSize);
      if (!mounted || request != _albumRequest || album.id != _album?.id) {
        return;
      }
      rawCount = list.length;
      final loadedIds = _assets.map((asset) => asset.id).toSet();
      final fresh = list
          .where((asset) => loadedIds.add(asset.id))
          .toList(growable: false);
      freshCount = fresh.length;
      _fillFromCache(fresh);
      setState(() {
        _page = next;
        _assets.addAll(fresh);
        if (_assets.length > _total) _total = _assets.length; // 显示用下限，别出现 N/总数 倒挂
        // 到头的可靠信号是"原生返回空页"。整页都是重复(边界因新增项错位)不算到头，
        // 旧写法在这里会 _pagingBlocked=true，把后面还没加载的照片永久藏住。
        _pagingBlocked = list.isEmpty;
      });
    } catch (_) {
      if (mounted && request == _albumRequest) {
        showToast(context, '加载更多失败，请稍后重试', kind: ToastKind.error);
      }
    } finally {
      if (mounted && request == _albumRequest) {
        setState(() => _loadingMore = false);
        if (freshCount > 0) _scheduleAllVerification();
        // 这页只要原生返回了数据(哪怕全重复)就可能还有下一页，继续尝试填满视口
        if (rawCount > 0) _scheduleViewportFill();
      }
    }
  }

  void _scheduleViewportFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollCtrl.hasClients ||
          _loadingMore ||
          _pagingBlocked) {
        return;
      }
      if (_scrollCtrl.position.extentAfter <= 400) {
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
      if (!mounted) return;
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
      if (!mounted) return;
      final uncached = _assets
          .where((asset) => !_assetChecksums.containsKey(asset.id));
      if (uncached.isEmpty) return;
      _hashVerifier.verify(uncached);
    });
  }

  // ── 选择 ──

  bool _isSelected(AssetEntity asset) => _selectedIds.contains(asset.id);

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selectedIds.contains(asset.id)) {
        _setSelected(asset, false);
      } else {
        if (_selected.length >= widget.maxSelect) {
          showToast(
            context,
            '最多选择 ${widget.maxSelect} 个',
            kind: ToastKind.info,
          );
          return;
        }
        _setSelected(asset, true);
      }
    });
  }

  void _setSelected(AssetEntity asset, bool on) {
    if (on && _selectedIds.add(asset.id)) {
      if (_selected.length >= widget.maxSelect) {
        _selectedIds.remove(asset.id);
        return;
      }
      _selected.add(asset);
    } else if (!on && _selectedIds.remove(asset.id)) {
      _selected.removeWhere((item) => item.id == asset.id);
    }
  }

  Future<void> _openPreview(AssetEntity asset) async {
    final idx = _assets.indexOf(asset);
    if (idx < 0) return;
    // 共享持有者：预览里的勾选直接写这里，pop（返回按钮或 iOS 侧滑）后读它同步回来。
    // 不依赖 pop 返回值 —— 侧滑返回带不回结果，用持有者才不会丢勾选（#44）。
    final sync = Set<String>.from(_selectedIds);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _PickerPreviewPage(
          assets: _assets,
          initialIndex: idx,
          sync: sync,
          maxSelect: widget.maxSelect,
          assetChecksums: _assetChecksums,
        ),
      ),
    );
    if (!mounted) return;
    // 切相册已清空跨相册选择，这里的选择必属当前相册，按 _assets 顺序重建有序列表
    setState(() {
      _selectedIds.clear();
      _selected.clear();
      for (final a in _assets) {
        if (sync.contains(a.id)) {
          _selectedIds.add(a.id);
          _selected.add(a);
        }
      }
    });
  }

  // ── 按住滑动连续选择（命中判定见 drag_select.dart）──

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
      // 区间外还原到按下前的状态，区间内整段应用 —— 回拖能正确取消
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
  }

  // ── 返回确认 ──

  Future<void> _confirmDiscard() async {
    if (_selected.isEmpty) {
      Navigator.pop(context, <PendingUpload>[]);
      return;
    }
    final ok = await appConfirmDialog(
      context,
      title: '放弃选择',
      message: '已选 ${_selected.length} 个，确定放弃？',
      confirmLabel: '放弃',
      destructive: true,
    );
    if (ok && mounted) Navigator.pop(context, <PendingUpload>[]);
  }

  // ── 确定 ──

  Future<void> _confirm() async {
    if (_selected.isEmpty) {
      Navigator.pop(context, <PendingUpload>[]);
      return;
    }
    setState(() => _resolving = true);
    final files = <PendingUpload>[];
    var failed = 0;
    for (final a in _selected) {
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
    if (failed > 0 && files.isEmpty) {
      setState(() => _resolving = false);
      showToast(context, '无法读取所选文件', kind: ToastKind.error);
      return;
    }
    if (failed > 0) {
      showToast(context, '$failed 个文件读取失败，已跳过', kind: ToastKind.info);
    }
    Navigator.pop(context, files);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopScope(
      canPop: _selected.isEmpty && !_resolving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: c.bg,
        appBar: AppBar(
          backgroundColor: c.bg,
          leading: IconButton(
            onPressed: _confirmDiscard,
            icon: Icon(Icons.close, size: AppIconSize.lg, color: c.onSurface),
          ),
          title: _buildAlbumTitle(c),
          actions: [
            TextButton(
              onPressed: _selected.isEmpty || _resolving ? null : _confirm,
              child: Text(
                _selected.isEmpty ? '确定' : '确定(${_selected.length})',
                style: TextStyle(
                  color: _selected.isEmpty ? c.onMuted : c.brand,
                  fontSize: AppType.sm,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        body: _buildBody(c),
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
        DragSelectDetector(
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
                if (notification.metrics.extentAfter <= 400) {
                  _loadMore();
                }
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
        if (_resolving)
          Positioned.fill(
            child: ColoredBox(
              color: c.scrimSoft,
              child: const Center(child: AppSpinner()),
            ),
          ),
      ],
    );
  }

  Widget _buildCell(AppColors c, AssetEntity asset) {
    final selected = _selectedIds.contains(asset.id);
    final selIdx = selected
        ? _selected.indexWhere((item) => item.id == asset.id)
        : -1;
    final checksum = _assetChecksums[asset.id];
    final uploaded = checksum != null && HashSync.instance.contains(checksum);
    final isVideo = asset.type == AssetType.video;
    return GestureDetector(
      onTap: () => _openPreview(asset),
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
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggle(asset),
              child: Padding(
                padding: const EdgeInsets.all(4),
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumTitle(AppColors c) {
    if (_albums.isEmpty) {
      return Text(
        '相册',
        style: TextStyle(
          color: c.onSurface,
          fontSize: AppType.mdPlus,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return GestureDetector(
      onTap: () => _showAlbumSheet(c),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              _album?.name ?? '相册',
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
    );
  }

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

  static String _fmtDuration(int secs) {
    final d = Duration(seconds: secs);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
}

/// 单个资源缩略图（走 photo_manager 原生缩略图，不下载原文件）
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
    } catch (_) {
      // 缩略图失败就留占位，不影响选择
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return ColoredBox(color: context.colors.surface2);
    return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

/// 相册封面
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

// ── 选择器内预览 ──

class _PickerPreviewPage extends StatefulWidget {
  final List<AssetEntity> assets;
  final int initialIndex;
  // 与上层共享的勾选集：预览直接改它，pop 后上层读取（不靠 pop 返回值，侧滑返回也不丢）
  final Set<String> sync;
  final int maxSelect;
  final Map<String, String> assetChecksums;

  const _PickerPreviewPage({
    required this.assets,
    required this.initialIndex,
    required this.sync,
    required this.maxSelect,
    required this.assetChecksums,
  });

  @override
  State<_PickerPreviewPage> createState() => _PickerPreviewPageState();
}

class _PickerPreviewPageState extends State<_PickerPreviewPage> {
  late final PageController _pageCtrl;
  Set<String> get _selected => widget.sync;
  late int _current;

  Player? _player;
  VideoController? _videoCtrl;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: _current);
    _prepareVideo(_current);
  }

  @override
  void dispose() {
    _player?.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  void _prepareVideo(int index) {
    final asset = widget.assets[index];
    if (asset.type == AssetType.video) {
      _player?.dispose();
      final player = Player();
      _player = player;
      _videoCtrl = VideoController(player);
      asset.file.then((f) {
        // 异步取文件期间可能已滑走：只有当这个 player 仍是当前、且页码没变时才 open，
        // 否则 _player! 可能已被置空(空判崩溃)或把上一条视频塞进新 player(放错视频)。
        if (f != null && mounted && _player == player && _current == index) {
          player.open(Media(f.path), play: true);
        }
      });
    } else {
      _player?.dispose();
      _player = null;
      _videoCtrl = null;
    }
  }

  void _onPageChanged(int index) {
    setState(() => _current = index);
    _prepareVideo(index);
  }

  void _toggleCurrent() {
    final id = widget.assets[_current].id;
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        if (_selected.length >= widget.maxSelect) {
          showToast(context, '最多选择 ${widget.maxSelect} 个', kind: ToastKind.info);
          return;
        }
        _selected.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final asset = widget.assets[_current];
    final isSelected = _selected.contains(asset.id);
    final checksum = widget.assetChecksums[asset.id];
    final uploaded = checksum != null && HashSync.instance.contains(checksum);

    // canPop:true —— 勾选写在共享的 widget.sync 上、上层 pop 后自取，
    // 放开 iOS 侧滑返回/系统返回（旧 canPop:false 会连侧滑手势一起禁掉，#44）。
    return PopScope(
      canPop: true,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
            elevation: 0,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (uploaded) const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: UploadedBadge(size: 22),
                ),
                Text(
                  '已选 ${_selected.length}',
                  style: const TextStyle(fontSize: 16, color: Colors.white),
                ),
              ],
            ),
            actions: [
              IconButton(
                onPressed: _toggleCurrent,
                icon: Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: isSelected ? c.brand : Colors.white70,
                  size: 26,
                ),
              ),
            ],
          ),
          body: PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.assets.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (ctx, i) {
              final a = widget.assets[i];
              if (a.type == AssetType.video &&
                  i == _current &&
                  _videoCtrl != null &&
                  _player != null) {
                return PreviewVideo(player: _player!, controller: _videoCtrl!);
              }
              // 非当前页的视频用缩略图当海报，绝不走图片解码导出整条视频（那会卡+闪碎图）
              if (a.type == AssetType.video) {
                return _AssetThumb(key: ValueKey(a.id), asset: a);
              }
              return _PickerPreviewImage(asset: a);
            },
          ),
        ),
      ),
    );
  }
}

class _PickerPreviewImage extends StatefulWidget {
  final AssetEntity asset;
  const _PickerPreviewImage({required this.asset});

  @override
  State<_PickerPreviewImage> createState() => _PickerPreviewImageState();
}

class _PickerPreviewImageState extends State<_PickerPreviewImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    widget.asset.file.then((f) {
      if (mounted && f != null) setState(() => _file = f);
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    if (f == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.white38));
    }
    return PhotoView(
      imageProvider: FileImage(f),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 3,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
    );
  }
}
