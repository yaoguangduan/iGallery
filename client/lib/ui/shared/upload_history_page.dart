import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/upload_history.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';

class UploadHistoryPage extends StatefulWidget {
  const UploadHistoryPage({super.key});

  @override
  State<UploadHistoryPage> createState() => _UploadHistoryPageState();
}

class _UploadHistoryPageState extends State<UploadHistoryPage> {
  List<UploadHistoryItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await UploadHistory.list(limit: 500);
    if (!mounted) return;
    setState(() { _items = rows; _loading = false; });
  }

  Future<void> _clear() async {
    final ok = await appConfirmDialog(context,
      title: '清空上传历史', message: '仅清客户端记录，不影响已上传的文件。',
      confirmLabel: '清空', destructive: true);
    if (!ok || !mounted) return;
    await UploadHistory.clear();
    if (!mounted) return;
    showToast(context, '已清空', kind: ToastKind.success);
    _load();
  }

  /// 单条删除。不动服务器，只删本地这条记录。
  Future<void> _deleteOne(String id) async {
    await UploadHistory.delete(id);
    if (!mounted) return;
    setState(() => _items.removeWhere((e) => e.id == id));
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtTime(DateTime t) => DateFormat('HH:mm:ss').format(t);

  String _dateBucket(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.year, t.month, t.day);
    if (d == today) return '今天';
    if (d == today.subtract(const Duration(days: 1))) return '昨天';
    if (d.year == now.year) return '${d.month}月${d.day}日';
    return '${d.year}年${d.month}月${d.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // 分组
    final groups = <String, List<UploadHistoryItem>>{};
    for (final it in _items) {
      final k = _dateBucket(it.startedAt);
      groups.putIfAbsent(k, () => []).add(it);
    }

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        title: Text('上传历史',
            style: TextStyle(color: c.onSurface, fontSize: AppType.lg, fontWeight: FontWeight.w600)),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.arrow_back, size: AppIconSize.lg, color: c.onSurface),
        ),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              onPressed: _clear,
              icon: Icon(Icons.delete_sweep_outlined, size: AppIconSize.lg, color: c.onSurfaceVariant),
              tooltip: '清空',
            ),
        ],
      ),
      body: _loading
        ? const Center(child: AppSpinner())
        : _items.isEmpty
          ? Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('还没有上传记录',
                  style: TextStyle(color: c.onMuted, fontSize: AppType.sm)),
            ))
          : ListView(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
              children: [
                for (final entry in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
                    child: Text(entry.key,
                        style: TextStyle(color: c.onSurface, fontSize: AppType.sm, fontWeight: FontWeight.w700)),
                  ),
                  for (final it in entry.value) _HistoryRow(
                    item: it,
                    timeText: _fmtTime(it.startedAt),
                    sizeText: _fmtBytes(it.size),
                    onDelete: () => _deleteOne(it.id),
                  ),
                ],
              ],
            ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final UploadHistoryItem item;
  final String timeText;
  final String sizeText;
  final VoidCallback onDelete;
  const _HistoryRow({required this.item, required this.timeText, required this.sizeText, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, color, label) = switch (item.status) {
      UploadStatus.success   => (Icons.check_circle_outline, c.ok, '成功'),
      UploadStatus.dedup     => (Icons.content_copy, c.onSurfaceVariant, '已存在'),
      UploadStatus.failed    => (Icons.error_outline, c.error, '失败'),
      UploadStatus.cancelled => (Icons.cancel_outlined, c.onMuted, '已取消'),
      UploadStatus.pending   => (Icons.hourglass_empty, c.warn, '进行中'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(children: [
        Icon(icon, color: color, size: AppIconSize.md),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.filename, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
            const SizedBox(height: 2),
            Text('$timeText · $sizeText · $label${item.error != null ? " · ${item.error}" : ""}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.onMuted, fontSize: AppType.xxs)),
          ],
        )),
        // 单条删除：不用每删一条都弹确认框，删本地记录无后果，
        // 弹框反而打断。真删错有"清空"之外的入口可查。
        IconButton(
          onPressed: onDelete,
          icon: Icon(Icons.close, size: AppIconSize.sm, color: c.onMuted),
          visualDensity: VisualDensity.compact,
          tooltip: '删除这条记录',
        ),
      ]),
    );
  }
}
