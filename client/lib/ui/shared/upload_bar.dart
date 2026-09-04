import 'package:flutter/material.dart';

import '../../core/upload_manager.dart';
import '../../theme/app_theme.dart';

/// 顶部 topbar 下方叠一条上传进度条 (批 5)
/// - 2px 横向进度条
/// - 一行文字：filename · N/M · X.X MB/s · ETA
/// - 点击 → 传入的 onTap（打开上传历史页）
class UploadBar extends StatefulWidget {
  final VoidCallback? onTap;
  const UploadBar({super.key, this.onTap});

  @override
  State<UploadBar> createState() => _UploadBarState();
}

class _UploadBarState extends State<UploadBar> {
  @override
  void initState() {
    super.initState();
    UploadManager.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    UploadManager.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() { if (mounted) setState(() {}); }

  String _fmtBytes(double bytes) {
    if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtEta(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final m = UploadManager.instance;
    if (!m.visible) return const SizedBox.shrink();
    final c = context.colors;
    final speed = m.speedBps;
    final eta = m.eta;
    final done = !m.uploading;
    final hasIssue = m.failCount > 0 || m.cancelCount > 0;

    // 左侧：文件名(截断) + 计数；右侧：速度 + ETA（始终可见）
    String left;
    if (done) {
      left = '已完成 ${m.completed}/${m.total}';
      if (m.dedupCount > 0) left += ' · ${m.dedupCount} 已存在';
      if (m.failCount > 0) left += ' · ${m.failCount} 失败';
      if (m.cancelCount > 0) left += ' · ${m.cancelCount} 已取消';
      if (m.lastError != null) left += ' · ${m.lastError}';
    } else if (m.cancelling) {
      left = '正在取消… ${m.completed}/${m.total}';
    } else {
      final name = m.currentFilename;
      final short = name.length > 12 ? '${name.substring(0, 12)}…' : name;
      left = '$short · ${m.completed}/${m.total}';
    }

    final rightParts = <String>[
      if (!done && !m.cancelling && speed > 0) '${_fmtBytes(speed)}/s',
      if (!done && !m.cancelling && eta != null) 'ETA ${_fmtEta(eta)}',
    ];
    final right = rightParts.join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: m.uploading ? m.progress.clamp(0, 1).toDouble() : 1.0,
                minHeight: 2,
                backgroundColor: c.outline,
                valueColor: AlwaysStoppedAnimation(
                  hasIssue && !m.uploading ? c.warn : c.brand),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 4),
              child: Row(children: [
                Expanded(child: Text(
                  left,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs),
                )),
                if (right.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(right,
                      style: TextStyle(color: c.onMuted, fontSize: AppType.xs)),
                  ),
                if (m.uploading)
                  TextButton(
                    onPressed: m.cancelling ? null : m.cancel,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text('取消',
                        style: TextStyle(
                            color: m.cancelling ? c.onMuted : c.brand,
                            fontSize: AppType.xs,
                            fontWeight: FontWeight.w600)),
                  )
                else
                  IconButton(
                    onPressed: m.dismiss,
                    icon: Icon(Icons.close, size: AppIconSize.sm, color: c.onMuted),
                    visualDensity: VisualDensity.compact,
                    tooltip: '收起',
                  ),
                Icon(Icons.chevron_right, size: 14, color: c.onMuted),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
