// gallery 里三块可独立的 widget：MediaThumb、FolderThumb、FolderPickerDialog
// 拆出以给 gallery_view.dart 瘦身 (M1)

import 'package:flutter/material.dart';

import '../../core/display_prefs.dart';
import '../../core/media_service.dart';
import '../../core/time_fmt.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'cached_thumb.dart';

/// 单个媒体缩略图（图片/视频）
class MediaThumb extends StatelessWidget {
  final MediaItem item;
  final MediaService service;
  final bool selected;
  final bool selecting;
  final DisplayPrefs prefs;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const MediaThumb({
    super.key,
    required this.item, required this.service,
    required this.selected, required this.selecting,
    required this.prefs, required this.onTap, required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final showBelow = prefs.hasLabel && prefs.labelPosition == LabelPosition.below;
    return GestureDetector(
      onTap: onTap, onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Stack(fit: StackFit.expand, children: [
            Container(color: c.surface2, child: CachedThumb(
              id: item.id,
              url: service.thumbUrl(item.id),
              headers: service.authHeaders,
              fit: BoxFit.cover,
              placeholder: Container(color: c.surface2),
              errorBuilder: (_) => Center(child: Icon(
                  item.isVideo ? Icons.videocam : Icons.broken_image,
                  color: c.onMuted, size: 28)),
            )),
            if (item.isVideo) ...[
              Center(child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: c.scrimSoft, shape: BoxShape.circle,
                ),
                child: Icon(Icons.play_arrow, size: 20, color: c.onScrim),
              )),
              if (item.duration != null)
                Positioned(right: 5, bottom: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.scrimMedium,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_fmtDuration(item.duration!),
                        style: TextStyle(color: c.onScrim, fontSize: AppType.xxs, fontWeight: FontWeight.w500)),
                  ),
                ),
            ],
            if (prefs.hasLabel && prefs.labelPosition == LabelPosition.overlay)
              Positioned(left: 0, right: 0, bottom: 0, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                decoration: BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [c.scrimMedium, Colors.transparent],
                )),
                child: _label(c.onScrim, c.onScrim.withValues(alpha: 0.75)),
              )),
            if (selecting) Positioned(right: 6, top: 6, child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: selected ? c.brand : c.scrimSoft, shape: BoxShape.circle,
                border: Border.all(color: c.onScrim, width: 1.5)),
              child: selected ? Icon(Icons.check, size: 14, color: c.onScrim) : null,
            )),
          ]),
          )),
          if (showBelow) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            child: _label(c.onSurface, c.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _fmtDuration(double secs) {
    final d = Duration(seconds: secs.round());
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  Widget _label(Color primary, Color secondary) {
    final parts = <Widget>[];
    final ts = TextStyle(color: secondary, fontSize: AppType.xxs);
    if (prefs.showName) parts.add(Text(item.filename, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: primary, fontSize: AppType.xs, fontWeight: FontWeight.w500)));
    if (prefs.showTime) {
      final text = fmtDateShort(item.displayDate);
      if (text.isNotEmpty) parts.add(Text(text, maxLines: 1, style: ts));
    }
    if (prefs.showSize) {
      final s = item.size;
      final text = s < 1024 * 1024
          ? '${(s / 1024).toStringAsFixed(0)} KB'
          : '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
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

/// 文件夹缩略图：亮色下用浅灰卡片 + 圆角，YouTube 风
class FolderThumb extends StatelessWidget {
  final FolderItem folder;
  final MediaService service;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const FolderThumb({
    super.key,
    required this.folder, required this.service,
    required this.onTap, required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Container(
              color: c.surface2,
              child: folder.coverId != null
                  ? Stack(fit: StackFit.expand, children: [
                      CachedThumb(
                        id: folder.coverId!,
                        url: service.thumbUrl(folder.coverId!),
                        headers: service.authHeaders,
                        placeholder: Container(color: c.surface2),
                        errorBuilder: (_) => Container(color: c.surface2),
                      ),
                      // 左上角文件夹角标，说明这是文件夹不是照片
                      Positioned(left: 6, top: 6, child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: c.scrimMedium,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: Icon(Icons.folder_rounded, size: 12, color: c.onScrim),
                      )),
                      if (folder.coverIsVideo)
                        Center(child: Container(
                          width: 20, height: 20,
                          decoration: BoxDecoration(color: c.scrimSoft, shape: BoxShape.circle),
                          child: Icon(Icons.play_arrow, size: 12, color: c.onScrim),
                        )),
                    ])
                  : Center(child: Icon(Icons.folder_rounded, size: 32, color: c.onMuted)),
            ),
          )),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.onSurface, fontSize: AppType.xs, fontWeight: FontWeight.w500)),
                const SizedBox(height: 1),
                Text('${folder.itemCount} 项',
                    style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xxs)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 移动到 ... 的文件夹选择器
class FolderPickerDialog extends StatefulWidget {
  final MediaService service;
  final String? currentFolderId;

  const FolderPickerDialog({super.key, required this.service, this.currentFolderId});

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  List<FolderItem> _folders = [];
  String? _browseFolderId;
  final List<({String id, String name})> _path = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _folders = await widget.service.listFolders(parentId: _browseFolderId);
    } catch (_) {
      _folders = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  void _enter(FolderItem folder) {
    _path.add((id: folder.id, name: folder.name));
    _browseFolderId = folder.id;
    _load();
  }

  void _goUp() {
    if (_path.isEmpty) return;
    _path.removeLast();
    _browseFolderId = _path.isEmpty ? null : _path.last.id;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surface,
      title: Text('移动到', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 300, height: 360,
        child: Column(children: [
          if (_path.isNotEmpty)
            Row(children: [
              GestureDetector(
                onTap: _goUp,
                child: Icon(Icons.arrow_back, size: 18, color: c.brand),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(
                _path.map((e) => e.name).join(' / '),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
              )),
            ]),
          if (_path.isNotEmpty) const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: AppSpinner())
                : ListView(children: [
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.home_outlined, color: c.onSurfaceVariant),
                      title: Text('公共空间 (根目录)', style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
                      onTap: () => Navigator.pop(context, ''),
                    ),
                    for (final f in _folders)
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.folder, color: c.onSurfaceVariant),
                        title: Text(f.name, style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
                        subtitle: Text('${f.itemCount} 项', style: TextStyle(color: c.onMuted, fontSize: 10)),
                        trailing: Icon(Icons.chevron_right, size: 18, color: c.onMuted),
                        onTap: () => Navigator.pop(context, f.id),
                        onLongPress: () => _enter(f),
                      ),
                    if (_folders.isEmpty && !_loading)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(child: Text('无子文件夹', style: TextStyle(color: c.onMuted, fontSize: AppType.xs))),
                      ),
                  ]),
          ),
        ]),
      ),
      actions: [
        if (_browseFolderId != null)
          TextButton(
            onPressed: () => Navigator.pop(context, _browseFolderId),
            child: Text('移到当前文件夹', style: TextStyle(color: c.brand, fontWeight: FontWeight.w600)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text('取消', style: TextStyle(color: c.onSurfaceVariant)),
        ),
      ],
    );
  }
}
