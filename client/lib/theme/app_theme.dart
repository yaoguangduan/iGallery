import 'package:flutter/material.dart';

/// 亮色 only（YouTube 风：纯白画布 · 灰阶层次 · 零阴影 · 单品牌色）
class AppColors {
  final Color bg;               // 画布 纯白
  final Color surface;          // 卡片/浮层
  final Color surface2;         // 输入框/chip/占位
  final Color onSurface;        // 正文（近黑）
  final Color onSurfaceVariant; // 次级
  final Color onMuted;          // 占位
  final Color outline;          // hairline
  final Color brand;            // 品牌蓝
  final Color brandSoft;        // 激活背景
  final Color error;
  final Color warn;
  final Color ok;
  // 图片上的遮罩层（跟主题无关，图片底色不可控，一律半透明黑 + 白字）
  final Color scrimStrong;
  final Color scrimMedium;
  final Color scrimSoft;
  final Color onScrim;

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
    required this.scrimStrong,
    required this.scrimMedium,
    required this.scrimSoft,
    required this.onScrim,
  });

  /// 唯一色板。YouTube 亮色对齐。
  static const AppColors light = AppColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF2F2F2),
    onSurface: Color(0xFF0F0F0F),         // 20.1:1
    onSurfaceVariant: Color(0xFF606060),  // 6.4:1
    onMuted: Color(0xFF909090),           // 3.1:1
    outline: Color(0xFFE5E5E5),
    brand: Color(0xFF065FD4),             // YouTube 蓝
    brandSoft: Color(0x14065FD4),         // 8% alpha
    error: Color(0xFFCC0000),             // YouTube 红系
    warn: Color(0xFFB86E00),
    ok: Color(0xFF0F7B3D),
    scrimStrong: Color(0xD9000000),  // 85%
    scrimMedium: Color(0x8A000000),  // 54%
    scrimSoft: Color(0x61000000),    // 38%
    onScrim: Color(0xFFFFFFFF),
  );
}

abstract class AppRadius {
  static const double chip = 8;      // YouTube chip 更圆
  static const double card = 12;
  static const double dialog = 12;
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

// YouTube 移动端的"大气"来自留白和字号，不是把东西塞紧。
// 这一档整体比 Material 默认偏大，别为了多塞一行往回调。
abstract class AppType {
  static const double xxs = 11.5;
  static const double xs = 13;
  static const double sm = 15;
  static const double md = 16;
  static const double base = 16;
  static const double mdPlus = 19;   // 分组标题 / 页标题
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 28;
  static const double display = 34;

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
    return w?.colors ?? AppColors.light;
  }

  @override
  bool updateShouldNotify(AppTheme old) => colors != old.colors;
}

ThemeData buildThemeData(AppColors c) {
  final scheme = ColorScheme(
    brightness: Brightness.light,
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
          states.contains(WidgetState.selected) ? Colors.white : c.onMuted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? c.brand : c.surface2),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Colors.transparent : c.outline),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.brand,
      selectionColor: c.brand.withValues(alpha: 0.20),
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
