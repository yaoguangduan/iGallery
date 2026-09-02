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

    final parts = <String>[
      if (done)
        '已完成 ${m.completed}/${m.total}'
      else if (m.currentFilename.isNotEmpty)
        m.currentFilename,
      if (!done) '${m.completed}/${m.total}',
      if (!done && speed > 0) '${_fmtBytes(speed)}/s',
      if (!done && eta != null) 'ETA ${_fmtEta(eta)}',
      if (m.dedupCount > 0) '${m.dedupCount} 已存在',
      if (m.failCount > 0) '${m.failCount} 失败',
    ];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 2px 横向进度条
            SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: m.uploading ? m.progress.clamp(0, 1).toDouble() : 1.0,
                minHeight: 2,
                backgroundColor: c.outline,
                valueColor: AlwaysStoppedAnimation(
                  m.failCount > 0 && !m.uploading ? c.warn : c.brand),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(children: [
                Expanded(child: Text(
                  parts.join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs),
                )),
                Icon(Icons.chevron_right, size: 14, color: c.onMuted),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
