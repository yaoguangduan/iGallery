import 'package:flutter/services.dart';

import 'platform.dart';

/// Android 12+「允许管理所有媒体文件」(MANAGE_MEDIA) 特殊权限。
///
/// 为什么需要：本地 tab 删除"非本 app 创建"的媒体时，photo_manager 走
/// MediaStore.createDeleteRequest，系统每次都弹「允许删除?」确认框。授予
/// MANAGE_MEDIA 后系统静默放行（只闪 ~300ms 进度条），与主流相册一致。
/// Android 11 及以下系统侧无免弹通道（一次批量一个框），不做引导。
///
/// 特意不用 permission_handler（不覆盖 MANAGE_MEDIA，且其 13.x 在 AGP 9 下
/// 无法编译），也不必升级 photo_manager（免弹是系统侧行为，与插件版本无关）——
/// MainActivity 里十几行 MethodChannel 就是全部成本。
class MediaPermission {
  MediaPermission._();

  static const MethodChannel _channel =
      MethodChannel('igallery/media_permission');

  /// 是否需要且能够引导授权：仅 Android 12+ 且尚未授予时为 true。
  /// 非 Android / 低版本 / 通道异常一律 false（不引导、不炸）。
  static Future<bool> needsManageMedia() async {
    if (!isAndroid) return false;
    try {
      final status = await _channel.invokeMethod<String>('manageMediaStatus');
      return status == 'notGranted';
    } catch (_) {
      return false;
    }
  }

  /// 打开系统「允许管理所有媒体文件」设置页。该页无结果回调，
  /// 用户授没授要回来后重新查 needsManageMedia()。
  /// 返回 false = 没能打开（Android 12 以下 / ROM 缺该页）。
  static Future<bool> openManageMediaSettings() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openManageMediaSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }
}
