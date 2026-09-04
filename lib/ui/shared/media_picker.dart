import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/hash_sync.dart';
import '../../core/time_fmt.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';
import 'drag_select.dart';

/// 微信风格选择器：相册分类 + 网格 + 长按滑动连续多选。
/// pop 返回 List<PendingUpload>（取消返回空列表）。
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

  bool _loading = true;
  bool _loadingMore = false;
  bool _resolving = false;
  int _total = 0;
  int _page = 0;
  String? _permissionError;

  // 已上传标记：asset id → 是否已在服务器
  final Map<String, bool> _uploadedCache = {};

  // 长按滑动连续选择
  int? _sweepAnchor;
  bool _sweepAdding = true;
  Set<String> _sweepBaseline = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (!ps.hasAccess) {
      setState(() { _loading = false; _permissionError = '没有相册访问权限'; });
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
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
    setState(() {
      _album = album;
      _loading = true;
      _assets.clear();
      _page = 0;
    });
    final total = await album.assetCountAsync;
    if (!mounted) return;
    _total = total;
    final list = await album.getAssetListPaged(page: 0, size: _pageSize);
    if (!mounted) return;
    setState(() {
      _assets.addAll(list);
      _loading = false;
    });
    _checkUploaded(list);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _album == null || _assets.length >= _total) return;
    _loadingMore = true;
    final next = _page + 1;
    final list = await _album!.getAssetListPaged(page: next, size: _pageSize);
    if (!mounted) { _loadingMore = false; return; }
    setState(() {
      _page = next;
      _assets.addAll(list);
    });
    _loadingMore = false;
    _checkUploaded(list);
  }

  Future<void> _checkUploaded(List<AssetEntity> assets) async {
    if (!HashSync.instance.synced) return;
    for (final a in assets) {
      if (!mounted) return;
      if (_uploadedCache.containsKey(a.id)) continue;
      try {
        final file = await a.file;
        if (file == null || !mounted) continue;
        final hash = await compute(_hashFile, file.path);
        if (!mounted) return;
        final exists = HashSync.instance.contains(hash);
        setState(() => _uploadedCache[a.id] = exists);
      } catch (_) {}
    }
  }

  static String _hashFile(String path) {
    final bytes = File(path).readAsBytesSync();
    return sha256.convert(bytes).toString();
  }

  // ── 选择 ──

  bool _isSelected(AssetEntity a) => _selected.any((e) => e.id == a.id);

  void _toggle(AssetEntity a) {
    setState(() {
      final i = _selected.indexWhere((e) => e.id == a.id);
      if (i >= 0) {
        _selected.removeAt(i);
      } else {
        if (_selected.length >= widget.maxSelect) {
          showToast(context, '最多选择 ${widget.maxSelect} 个', kind: ToastKind.info);
          return;
        }
        _selected.add(a);
      }
    });
  }

  void _setSelected(AssetEntity a, bool on) {
    final i = _selected.indexWhere((e) => e.id == a.id);
    if (on && i < 0) {
      if (_selected.length >= widget.maxSelect) return;
      _selected.add(a);
    } else if (!on && i >= 0) {
      _selected.removeAt(i);
    }
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
    final ok = await appConfirmDialog(context,
      title: '放弃选择',
      message: '已选 ${_selected.length} 个，确定放弃？',
      confirmLabel: '放弃',
      destructive: true,
    );
    if (ok && mounted) Navigator.pop(context, <PendingUpload>[]);
  }

  // ── 确定 ──

  Future<void> _confirm() async {
    if (_selected.isEmpty) { Navigator.pop(context, <PendingUpload>[]); return; }
    setState(() => _resolving = true);
    final files = <PendingUpload>[];
    var failed = 0;
    for (final a in _selected) {
      try {
        final f = await a.file;
        if (f != null) {
          files.add(PendingUpload(f, takenAtIso: toServerRfc3339(a.createDateTime)));
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
    ));
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
      return Center(child: Text('此相册为空',
          style: TextStyle(color: c.onMuted, fontSize: AppType.sm)));
    }
    return Stack(children: [
      DragSelectDetector(
        onStart: _sweepStart,
        onEnter: _sweepTo,
        onEnd: _sweepEnd,
        scrollController: _scrollCtrl,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) _loadMore();
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
            itemBuilder: (ctx, i) => DragSelectItem(
              index: i,
              child: _buildCell(c, _assets[i]),
            ),
          ),
        ),
      ),
      if (_resolving)
        Positioned.fill(child: ColoredBox(
          color: c.scrimSoft,
          child: const Center(child: AppSpinner()),
        )),
    ]);
  }

  Widget _buildCell(AppColors c, AssetEntity asset) {
    final selIdx = _selected.indexWhere((e) => e.id == asset.id);
    final selected = selIdx >= 0;
    final uploaded = _uploadedCache[asset.id] == true;
    return GestureDetector(
      onTap: () => _toggle(asset),
      child: Stack(fit: StackFit.expand, children: [
        _AssetThumb(key: ValueKey(asset.id), asset: asset),
        if (selected) ColoredBox(color: c.onScrim.withValues(alpha: 0.28)),
        if (uploaded && !selected)
          ColoredBox(color: c.onScrim.withValues(alpha: 0.15)),
        if (asset.type == AssetType.video)
          Positioned(left: 4, bottom: 4, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: c.scrimMedium,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(_fmtDuration(asset.duration),
                style: TextStyle(color: c.onScrim, fontSize: AppType.xxs)),
          )),
        if (uploaded)
          Positioned(left: 4, top: 4, child: Icon(
            Icons.cloud_done, size: 16,
            color: c.ok.withValues(alpha: 0.9),
          )),
        Positioned(right: 4, top: 4, child: Container(
          width: 22, height: 22,
          decoration: BoxDecoration(
            color: selected ? c.brand : c.scrimSoft,
            shape: BoxShape.circle,
            border: Border.all(color: c.onScrim, width: 1.5),
          ),
          child: selected
              ? Center(child: Text('${selIdx + 1}',
                  style: TextStyle(color: c.onScrim, fontSize: AppType.xxs,
                      fontWeight: FontWeight.w600)))
              : null,
        )),
      ]),
    );
  }

  Widget _buildAlbumTitle(AppColors c) {
    if (_albums.isEmpty) {
      return Text('相册', style: TextStyle(color: c.onSurface,
          fontSize: AppType.mdPlus, fontWeight: FontWeight.w600));
    }
    return GestureDetector(
      onTap: () => _showAlbumSheet(c),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(_album?.name ?? '相册',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.onSurface,
                  fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
        ),
        Icon(Icons.arrow_drop_down, color: c.onSurfaceVariant),
      ]),
    );
  }

  void _showAlbumSheet(AppColors c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, sc) => Column(children: [
          const SheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(children: [
              Text('选择相册', style: TextStyle(color: c.onSurface,
                  fontSize: AppType.mdPlus, fontWeight: FontWeight.w700)),
            ]),
          ),
          Expanded(child: ListView.builder(
            controller: sc,
            itemCount: _albums.length,
            itemBuilder: (ctx, i) {
              final album = _albums[i];
              final active = album.id == _album?.id;
              return ListTile(
                leading: SizedBox(
                  width: 44, height: 44,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                    child: _AlbumCover(key: ValueKey(album.id), album: album),
                  ),
                ),
                title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? c.brand : c.onSurface,
                      fontSize: AppType.sm,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    )),
                subtitle: FutureBuilder<int>(
                  future: album.assetCountAsync,
                  builder: (ctx, snap) => Text('${snap.data ?? 0} 项',
                      style: TextStyle(color: c.onMuted, fontSize: AppType.xxs)),
                ),
                trailing: active
                    ? Icon(Icons.check, color: c.brand, size: AppIconSize.lg)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  if (!active) _switchAlbum(album);
                },
              );
            },
          )),
        ]),
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
      final data = await widget.asset
          .thumbnailDataWithSize(const ThumbnailSize.square(240));
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
      final data = await list.first
          .thumbnailDataWithSize(const ThumbnailSize.square(120));
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
