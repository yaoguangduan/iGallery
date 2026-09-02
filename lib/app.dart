import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/platform.dart';
import 'theme/app_theme.dart';
import 'ui/desktop/desktop_shell.dart';
import 'ui/mobile/mobile_shell.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class IGalleryApp extends StatelessWidget {
  const IGalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 亮色 only：状态栏透明 + 深色图标
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,   // Android
      statusBarBrightness: Brightness.light,      // iOS
      systemNavigationBarColor: Color(0xFFFFFFFF),
      systemNavigationBarIconBrightness: Brightness.dark,
    ));

    return AppTheme(
      colors: AppColors.light,
      child: MaterialApp(
        title: 'iGallery',
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        themeMode: ThemeMode.light,
        theme: buildThemeData(AppColors.light),
        home: isDesktop ? const DesktopShell() : const MobileShell(),
      ),
    );
  }
}
