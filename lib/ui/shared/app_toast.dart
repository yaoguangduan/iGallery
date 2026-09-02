import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../theme/app_theme.dart';

enum ToastKind { info, success, error }

/// 显示 toast (C3)
/// 去掉丑双下划线：只有半透明 chip 底 + 一个左侧圆点表示 kind
void showToast(BuildContext context, String message, {ToastKind kind = ToastKind.info}) {
  _showOverlayToast(Overlay.of(context), message, kind);
}

void showToastGlobal(String message, {ToastKind kind = ToastKind.info}) {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return;
  final overlay = Overlay.of(ctx);
  _showOverlayToast(overlay, message, kind);
}

void _showOverlayToast(OverlayState overlay, String message, ToastKind kind) {
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(message: message, kind: kind, onDismiss: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  final String message;
  final ToastKind kind;
  final VoidCallback onDismiss;

  const _Toast({required this.message, required this.kind, required this.onDismiss});

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween(begin: const Offset(0, -0.4), end: Offset.zero).animate(_fade);
    _ctrl.forward();
    Timer(Duration(milliseconds: widget.kind == ToastKind.error ? 3600 : 2400), _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    _ctrl.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color _dotColor(AppColors c) => switch (widget.kind) {
    ToastKind.success => c.ok,
    ToastKind.error   => c.error,
    ToastKind.info    => c.onSurfaceVariant,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 16, right: 16,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: GestureDetector(
            onTap: _dismiss,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: c.outline, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6, height: 6, margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(color: _dotColor(c), shape: BoxShape.circle),
                        ),
                        Flexible(
                          child: Text(
                            widget.message,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
