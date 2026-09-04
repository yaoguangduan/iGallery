import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/upload_permissions.dart';
import '../../theme/app_theme.dart';
import '../shared/gallery_shell.dart';
import '../shared/share_handler.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  /// 通知权限缺失时在顶部挂一条提示。
  ///
  /// 启动时只做静默探测，不直接弹系统弹窗：Android 上用户拒绝两次之后系统会
  /// 静默驳回后续请求，冷启动就弹等于把这两次机会浪费在用户还没开始上传的时候。
  /// 让他自己点，弹窗才落在"他确实想传东西"的语境里。
  bool _needsNotificationPerm = false;
  bool _bannerDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPermission());
  }

  Future<void> _checkPermission() async {
    final ok = await UploadPermissions.hasNotificationPermission();
    if (!mounted) return;
    setState(() => _needsNotificationPerm = !ok);
  }

  Future<void> _requestPermission() async {
    // force: 绕过"问过就不再问"的记账 —— 这次是用户主动点的。
    final ok = await UploadPermissions.requestNotificationPermission(force: true);
    if (!mounted) return;
    setState(() {
      _needsNotificationPerm = !ok;
      if (ok) _bannerDismissed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final showBanner = _needsNotificationPerm && !_bannerDismissed;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: c.bg,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: c.bg,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: ShareHandler(
        child: showBanner
            // banner 自己吃掉状态栏内边距，再把它从下游的 MediaQuery 里摘掉，
            // 否则 GalleryShell 内层的 SafeArea 会二次垫高，中间空出一条。
            ? Column(children: [
                SafeArea(
                  bottom: false,
                  child: _NotificationPermBanner(
                    onEnable: _requestPermission,
                    onDismiss: () => setState(() => _bannerDismissed = true),
                  ),
                ),
                Expanded(child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: const GalleryShell(),
                )),
              ])
            : const GalleryShell(),
      ),
    );
  }
}

class _NotificationPermBanner extends StatelessWidget {
  final VoidCallback onEnable;
  final VoidCallback onDismiss;
  const _NotificationPermBanner({required this.onEnable, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.warn.withValues(alpha: 0.10),
      child: InkWell(
        onTap: onEnable,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(children: [
            Icon(Icons.notifications_off_outlined, size: 18, color: c.warn),
            const SizedBox(width: 10),
            Expanded(child: Text(
              '开启通知权限，切到后台时上传才不会被系统中断',
              style: TextStyle(color: c.onSurface, fontSize: AppType.xs),
            )),
            TextButton(
              onPressed: onEnable,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                visualDensity: VisualDensity.compact,
              ),
              child: Text('开启', style: TextStyle(
                color: c.brand, fontSize: AppType.xs, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: Icon(Icons.close, size: AppIconSize.sm, color: c.onMuted),
              visualDensity: VisualDensity.compact,
              tooltip: '忽略',
            ),
          ]),
        ),
      ),
    );
  }
}
