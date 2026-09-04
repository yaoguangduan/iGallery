import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../core/media_service.dart';
import '../../core/server_state.dart';
import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';
import 'cached_thumb.dart';

class ShareHandler extends StatefulWidget {
  final Widget child;
  const ShareHandler({super.key, required this.child});

  @override
  State<ShareHandler> createState() => _ShareHandlerState();
}

class _ShareHandlerState extends State<ShareHandler> {
  StreamSubscription<List<SharedMediaFile>>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        if (files.isNotEmpty && mounted) _handleShared(files);
        ReceiveSharingIntent.instance.reset();
      });
    });
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      if (files.isNotEmpty && mounted) _handleShared(files);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _handleShared(List<SharedMediaFile> shared) {
    final files = shared
        .where((f) => f.path.isNotEmpty)
        .map((f) => PendingUpload(File(f.path)))
        .toList();
    if (files.isEmpty || !mounted) return;
    _showFolderPicker(files);
  }

  void _showFolderPicker(List<PendingUpload> files) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FolderPickerSheet(files: files),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _FolderPickerSheet extends StatefulWidget {
  final List<PendingUpload> files;
  const _FolderPickerSheet({required this.files});

  @override
  State<_FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<_FolderPickerSheet> {
  List<FolderItem>? _folders;
  bool _loading = true;
  bool _uploading = false;
  String? _selectedFolderId;
  String? _selectedFolderName;
  final List<({String id, String name})> _path = [];
  MediaService? _service;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<ServerState>();
    if (state.status == ConnectionStatus.connected && _service == null) {
      _service = MediaService(state);
      _loadFolders();
    }
  }

  Future<void> _loadFolders() async {
    if (_service == null) return;
    setState(() => _loading = true);
    try {
      final folders = await _service!.listFolders(parentId: _selectedFolderId);
      if (!mounted) return;
      setState(() { _folders = folders; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _folders = []; _loading = false; });
    }
  }

  void _enterFolder(FolderItem folder) {
    setState(() {
      _path.add((id: folder.id, name: folder.name));
      _selectedFolderId = folder.id;
      _selectedFolderName = folder.name;
    });
    _loadFolders();
  }

  void _goBack() {
    if (_path.isEmpty) return;
    setState(() {
      _path.removeLast();
      _selectedFolderId = _path.isEmpty ? null : _path.last.id;
      _selectedFolderName = _path.isEmpty ? null : _path.last.name;
    });
    _loadFolders();
  }

  void _goToRoot() {
    setState(() {
      _path.clear();
      _selectedFolderId = null;
      _selectedFolderName = null;
    });
    _loadFolders();
  }

  Future<void> _upload() async {
    if (_service == null || _uploading) return;
    if (UploadManager.instance.uploading) {
      if (mounted) {
        showToast(context, '正在上传中，请稍候', kind: ToastKind.info);
      }
      return;
    }
    setState(() => _uploading = true);
    final state = context.read<ServerState>();
    final result = await UploadManager.instance.enqueue(
      _service!, widget.files,
      folderId: _selectedFolderId,
      serverUrl: state.baseUrl,
    );
    if (!mounted) return;
    Navigator.pop(context);
    final parts = <String>['已上传 ${result.uploaded} 个'];
    if (result.dedup > 0) parts.add('${result.dedup} 个已存在跳过');
    if (result.failed > 0) parts.add('${result.failed} 个失败');
    showToast(context, parts.join(' · '),
        kind: result.allOk ? ToastKind.success : ToastKind.error);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<ServerState>();
    final connected = state.status == ConnectionStatus.connected;
    final locationLabel = _selectedFolderName ?? '根目录';

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SheetHandle(),
        // 标题
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(children: [
            Icon(Icons.upload_rounded, size: AppIconSize.lg, color: c.brand),
            const SizedBox(width: 8),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '上传 ${widget.files.length} 个文件',
                  style: TextStyle(
                    color: c.onSurface,
                    fontSize: AppType.mdPlus,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '选择目标相册',
                  style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
                ),
              ],
            )),
          ]),
        ),
        Divider(height: 0.5, color: c.outline),
        if (!connected) ...[
          const SizedBox(height: 48),
          AppEmptyState(
            icon: Icons.cloud_off_outlined,
            message: '未连接到服务器',
          ),
          const SizedBox(height: 48),
        ] else ...[
          // 面包屑导航
          if (_path.isNotEmpty) Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              GestureDetector(
                onTap: _goBack,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.arrow_back_ios_new, size: 16, color: c.brand),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: _goToRoot,
                child: Text('根目录', style: TextStyle(
                  color: c.brand, fontSize: AppType.xs,
                )),
              ),
              for (var i = 0; i < _path.length; i++) ...[
                Icon(Icons.chevron_right, size: 16, color: c.onMuted),
                GestureDetector(
                  onTap: i < _path.length - 1 ? () {
                    setState(() {
                      _path.removeRange(i + 1, _path.length);
                      _selectedFolderId = _path.last.id;
                      _selectedFolderName = _path.last.name;
                    });
                    _loadFolders();
                  } : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(
                      _path[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: i == _path.length - 1 ? c.onSurface : c.brand,
                        fontSize: AppType.xs,
                        fontWeight: i == _path.length - 1 ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          // 文件夹列表
          Flexible(child: _buildFolderList(c)),
        ],
        Divider(height: 0.5, color: c.outline),
        // 底部操作
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              Icon(Icons.folder_outlined, size: 18, color: c.onMuted),
              const SizedBox(width: 6),
              Expanded(child: Text(
                locationLabel,
                style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: connected && !_uploading ? _upload : null,
                style: FilledButton.styleFrom(
                  backgroundColor: c.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                child: _uploading
                    ? SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white,
                        ),
                      )
                    : const Text('上传', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildFolderList(AppColors c) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: AppSpinner()),
      );
    }
    final folders = _folders ?? [];
    if (folders.isEmpty && _path.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(
          '暂无相册，文件将上传到根目录',
          style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
        )),
      );
    }
    if (folders.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(
          '此相册下无子相册',
          style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
        )),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: folders.length,
      itemBuilder: (ctx, i) => _FolderRow(
        folder: folders[i],
        service: _service!,
        onTap: () => _enterFolder(folders[i]),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final FolderItem folder;
  final MediaService service;
  final VoidCallback onTap;
  const _FolderRow({required this.folder, required this.service, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.chip),
            child: SizedBox(
              width: 48, height: 48,
              child: folder.coverId != null
                  ? CachedThumb(
                      id: folder.coverId!,
                      url: service.thumbUrl(folder.coverId!),
                      headers: service.authHeaders,
                    )
                  : ColoredBox(
                      color: c.surface2,
                      child: Icon(Icons.folder, size: 24, color: c.onMuted),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.onSurface,
                  fontSize: AppType.sm,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text('${folder.itemCount} 项',
                style: TextStyle(color: c.onMuted, fontSize: AppType.xxs),
              ),
            ],
          )),
          Icon(Icons.chevron_right, size: 20, color: c.onMuted),
        ]),
      ),
    );
  }
}
