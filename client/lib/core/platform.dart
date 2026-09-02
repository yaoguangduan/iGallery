import 'package:flutter/foundation.dart';

/// 平台判断集中在此，禁止散落到 UI 层 (C4)
bool get isDesktop {
  final p = defaultTargetPlatform;
  return p == TargetPlatform.macOS ||
      p == TargetPlatform.windows ||
      p == TargetPlatform.linux;
}

bool get isMobile => !isDesktop;
