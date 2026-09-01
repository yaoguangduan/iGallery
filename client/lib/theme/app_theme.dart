import 'package:flutter/material.dart';

class AppColors {
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color onMuted;
  final Color outline;
  final Color brand;
  final Color brandSoft;
  final Color error;
  final Color warn;
  final Color ok;

  const AppColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.onMuted,
    required this.outline,
    required this.brand,
    required this.brandSoft,
    required this.error,
    required this.warn,
    required this.ok,
  });

  static const AppColors dark = AppColors(
    bg: Color(0xFF0F1014),
    surface: Color(0xFF17181D),
    surface2: Color(0xFF202127),
    onSurface: Color(0xFFE4E5EA),
    onSurfaceVariant: Color(0xFF9EA0A9),
    onMuted: Color(0xFF5E6068),
    outline: Color(0xFF2A2B32),
    brand: Color(0xFF6B8AFF),
    brandSoft: Color(0x246B8AFF),
    error: Color(0xFFE57373),
    warn: Color(0xFFD9A25F),
    ok: Color(0xFF7FBA9A),
  );
}

abstract class AppRadius {
  static const double chip = 6;
  static const double card = 12;
  static const double dialog = 14;
  static const double sheet = 16;
  static const double pill = 999;
}

abstract class AppIconSize {
  static const double sm = 16;
  static const double md = 18;
  static const double lg = 20;
  static const double xl = 22;
  static const double hero = 32;
}

abstract class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const EdgeInsets card = EdgeInsets.all(lg);
}

abstract class AppType {
  static const double xxs = 10.5;
  static const double xs = 11.5;
  static const double sm = 13.5;
  static const double md = 14.5;
  static const double base = 15;
  static const double mdPlus = 16;
  static const double lg = 17;
  static const double xl = 20;
  static const double xxl = 24;
  static const double display = 32;

  static const List<String> familyFallback = [
    'PingFang SC',
    'MiSans',
    'HarmonyOS Sans SC',
    'Source Han Sans SC',
    'Noto Sans SC',
    'Microsoft YaHei',
  ];
}

extension AppThemeX on BuildContext {
  AppColors get colors => AppTheme.of(this);
}

class AppTheme extends InheritedWidget {
  final AppColors colors;

  const AppTheme({
    super.key,
    required this.colors,
    required super.child,
  });

  static AppColors of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    return w?.colors ?? AppColors.dark;
  }

  @override
  bool updateShouldNotify(AppTheme old) => colors != old.colors;
}

ThemeData buildThemeData(AppColors c) {
  final scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: c.brand,
    onPrimary: Colors.white,
    secondary: c.brand,
    onSecondary: Colors.white,
    error: c.error,
    onError: Colors.white,
    surface: c.bg,
    onSurface: c.onSurface,
    outline: c.outline,
    outlineVariant: c.outline,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamilyFallback: AppType.familyFallback,
    scaffoldBackgroundColor: c.bg,
    dividerColor: c.outline,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
    ),
    dividerTheme: DividerThemeData(color: c.outline, thickness: 0.5, space: 0),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Colors.white : c.surface2),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? c.brand : c.outline),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.brand,
      selectionColor: c.brand.withValues(alpha: 0.30),
      selectionHandleColor: c.brand,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
    ),
  );
}
