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
    // 亮色 only：状态栏与背景同色（白），深色图标。
    // 不用透明——非 edge-to-edge 的 Android 上透明会露出黑色窗口底。
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: AppColors.light.bg,
      statusBarIconBrightness: Brightness.dark,   // Android
      statusBarBrightness: Brightness.light,      // iOS
      systemNavigationBarColor: AppColors.light.bg,
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
