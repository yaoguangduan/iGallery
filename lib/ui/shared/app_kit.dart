import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../theme/app_theme.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;

  const AppCard({super.key, required this.child, this.onTap, this.padding});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(padding: padding ?? AppSpace.card, child: child),
    );
  }
}

class AppDivider extends StatelessWidget {
  const AppDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(height: 0.5, thickness: 0.5, color: context.colors.outline);
  }
}

/// 滚动时浮现的统一滚动条：中性灰、圆头、离屏幕边缘留白，可直接拖动。
class AppScrollbar extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  const AppScrollbar({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ScrollbarTheme(
      data: ScrollbarTheme.of(context).copyWith(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          final active =
              states.contains(WidgetState.dragged) ||
              states.contains(WidgetState.hovered);
          return c.onSurfaceVariant.withValues(alpha: active ? 0.72 : 0.46);
        }),
        thickness: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.hovered) ? 10.0 : 9.0;
        }),
        radius: const Radius.circular(AppRadius.pill),
        crossAxisMargin: AppSpace.xs,
        mainAxisMargin: AppSpace.sm,
        minThumbLength: 48,
      ),
      child: Scrollbar(
        controller: controller,
        interactive: true,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: child,
        ),
      ),
    );
  }
}

class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: context.colors.outline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final IconData? icon;

  const AppButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = true,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bg = primary ? c.brand : c.surface2;
    final fg = primary ? Colors.white : c.onSurface;
    return SizedBox(
      height: 40,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: AppIconSize.sm),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: const TextStyle(
                fontSize: AppType.sm,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final Widget? action;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppIconSize.hero, color: c.onMuted),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.sm),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

class AppSpinner extends StatelessWidget {
  const AppSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: context.colors.brand,
        ),
      ),
    );
  }
}

Future<bool> appConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool destructive = false,
}) async {
  final c = context.colors;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        title,
        style: TextStyle(
          color: c.onSurface,
          fontSize: AppType.mdPlus,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        message,
        style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.md),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('取消', style: TextStyle(color: c.onSurfaceVariant)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            confirmLabel,
            style: TextStyle(
              color: destructive ? c.error : c.brand,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}

class QuickLongPress extends StatelessWidget {
  static const Duration duration = Duration(milliseconds: 200);

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;
  final Widget child;

  const QuickLongPress({
    super.key,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (r) {
            r.onTap = onTap;
            r.onSecondaryTapDown = onSecondaryTapDown;
          },
        ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: duration),
          (r) => r.onLongPress = onLongPress,
        ),
      },
      child: child,
    );
  }
}
