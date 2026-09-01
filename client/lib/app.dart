import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme/app_theme.dart';
import 'ui/desktop/desktop_shell.dart';
import 'ui/mobile/mobile_shell.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class IGalleryApp extends StatelessWidget {
  const IGalleryApp({super.key});

  static bool get isDesktop {
    final p = defaultTargetPlatform;
    return p == TargetPlatform.macOS ||
        p == TargetPlatform.windows ||
        p == TargetPlatform.linux;
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme(
      colors: AppColors.dark,
      child: MaterialApp(
        title: 'iGallery',
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        themeMode: ThemeMode.dark,
        darkTheme: buildThemeData(AppColors.dark),
        home: isDesktop ? const DesktopShell() : const MobileShell(),
      ),
    );
  }
}
