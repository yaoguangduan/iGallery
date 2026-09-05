import 'package:flutter/foundation.dart';

/// 平台判断集中在此，禁止散落到 UI 层 (C4)
bool get isDesktop {
  final p = defaultTargetPlatform;
  return p == TargetPlatform.macOS ||
      p == TargetPlatform.windows ||
      p == TargetPlatform.linux;
}

bool get isMobile => !isDesktop;

/// Android 独有逻辑（如 MANAGE_MEDIA 授权引导，见 core/media_permission.dart）只准用这个门控
bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;
