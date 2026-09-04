import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/media_service.dart';
import '../../core/server_state.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';

/// Shows the standard folder picker (same as "move"), then starts [files].
/// Returns true only after the user confirms a target and the batch is accepted.
Future<bool> showFolderPickerAndUpload(
  BuildContext context,
  List<PendingUpload> files,
) async {
  final state = context.read<ServerState>();
  if (state.status != ConnectionStatus.connected) {
    showToast(context, '未连接到服务器', kind: ToastKind.error);
    return false;
  }
  if (UploadManager.instance.uploading) {
    showToast(context, '正在上传中，请稍候', kind: ToastKind.info);
    return false;
  }
  final service = MediaService(state);
  final c = context.colors;
  final picker = _UploadFolderPicker(service: service, fileCount: files.length);

  final targetId = await showModalBottomSheet<String>(
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
  if (targetId == null || !context.mounted) return false;
  if (UploadManager.instance.uploading) {
    showToast(context, '已有上传任务开始，请稍候', kind: ToastKind.info);
    return false;
  }

  unawaited(
    UploadManager.instance.enqueue(
      service,
      files,
      folderId: targetId.isEmpty ? null : targetId,
      serverUrl: state.baseUrl,
    ),
  );
  return true;
}

/// Wraps the standard FolderPickerSheet with upload-specific button labels.
class _UploadFolderPicker extends StatefulWidget {
  final MediaService service;
  final int fileCount;
  const _UploadFolderPicker({required this.service, required this.fileCount});

  @override
  State<_UploadFolderPicker> createState() => _UploadFolderPickerState();
}

class _UploadFolderPickerState extends State<_UploadFolderPicker> {
  List<FolderItem> _folders = [];
  String? _browseFolderId;
  final List<({String id, String name})> _path = [];
  bool _loading = true;
  bool _loadError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    try {
      _folders = await widget.service.listFolders(parentId: _browseFolderId);
    } catch (_) {
      _loadError = true;
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
    return Column(
      children: [
        const SheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              if (_path.isNotEmpty) ...[
                GestureDetector(
                  onTap: _goUp,
                  child: Icon(Icons.arrow_back, size: 20, color: c.brand),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _path.isEmpty
                      ? '上传 ${widget.fileCount} 个文件到'
                      : _path.map((e) => e.name).join(' / '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _path.isEmpty ? c.onSurface : c.onMuted,
                    fontSize: _path.isEmpty ? AppType.mdPlus : AppType.xs,
                    fontWeight: _path.isEmpty
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: AppSpinner())
              : _loadError
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: c.error,
                        size: AppIconSize.hero,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '加载失败',
                        style: TextStyle(
                          color: c.onSurfaceVariant,
                          fontSize: AppType.sm,
                        ),
                      ),
                      const SizedBox(height: 12),
                      AppButton(label: '重试', primary: false, onTap: _load),
                    ],
                  ),
                )
              : ListView(
                  children: [
                    for (final f in _folders)
                      ListTile(
                        visualDensity: const VisualDensity(vertical: -2),
                        leading: Icon(
                          Icons.folder,
                          size: 20,
                          color: c.onSurfaceVariant,
                        ),
                        title: Text(
                          f.name,
                          style: TextStyle(
                            color: c.onSurface,
                            fontSize: AppType.sm,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: c.onMuted,
                        ),
                        onTap: () => _enter(f),
                      ),
                    if (_folders.isEmpty && !_loading)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            '无子文件夹',
                            style: TextStyle(
                              color: c.onMuted,
                              fontSize: AppType.xs,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, null),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.onSurfaceVariant,
                      side: BorderSide(color: c.outline),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, _browseFolderId ?? ''),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.brand,
                      foregroundColor: c.onScrim,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                    ),
                    child: Text(_browseFolderId == null ? '上传到根目录' : '上传到此处'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
