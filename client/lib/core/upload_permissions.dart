import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'kv_store.dart';
import 'log_service.dart';
import 'platform.dart';

/// 上传保活需要的系统权限。
///
/// Android 13+ 把 POST_NOTIFICATIONS 变成了运行时权限：manifest 里声明了不等于
/// 拿到了。没授权时 startForegroundService 起不来通知，前台服务随即被系统判为
/// 无效，切后台上传就会被杀 —— 而且整个过程没有任何报错，用户只会看到
/// "传一半没了"。所以必须在真正开始上传之前把权限要到手。
class UploadPermissions {
  static const _kAskedNotification = 'perm.asked_notification';

  /// 进程内缓存：一次会话里只探测一次，避免每次上传都过一遍平台通道。
  static bool _granted = false;

  /// 静默检查 —— 只读状态，不弹窗。
  static Future<bool> hasNotificationPermission() async {
    if (!isMobile || Platform.isIOS) return true;
    if (_granted) return true;
    try {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      _granted = status == NotificationPermission.granted;
      return _granted;
    } catch (e) {
      LogService.instance.error('检查通知权限失败: $e');
      return false;
    }
  }

  /// 申请权限。[force] 为 false 时只在"从没问过"的情况下弹窗 ——
  /// 用户明确拒绝过就不再打扰，重复弹窗在 Android 上也会被系统直接驳回。
  static Future<bool> requestNotificationPermission({bool force = false}) async {
    if (!isMobile || Platform.isIOS) return true;
    if (await hasNotificationPermission()) return true;

    if (!force) {
      final asked = await KvStore.instance.get(_kAskedNotification);
      if (asked == '1') return false;
    }

    try {
      await KvStore.instance.set(_kAskedNotification, '1');
      final status = await FlutterForegroundTask.requestNotificationPermission();
      _granted = status == NotificationPermission.granted;
      return _granted;
    } catch (e) {
      LogService.instance.error('申请通知权限失败: $e');
      return false;
    }
  }
}
