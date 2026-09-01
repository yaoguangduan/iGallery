import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../theme/app_theme.dart';

void showToast(BuildContext context, String message) {
  _showOverlayToast(Overlay.of(context), message);
}

void showToastGlobal(String message) {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return;
  final overlay = Overlay.of(ctx);
  _showOverlayToast(overlay, message);
}

void _showOverlayToast(OverlayState overlay, String message) {
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(message: message, onDismiss: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  final String message;
  final VoidCallback onDismiss;

  const _Toast({required this.message, required this.onDismiss});

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
        vsync: this, duration: const Duration(milliseconds: 250));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween(begin: const Offset(0, -1), end: Offset.zero)
        .animate(_fade);
    _ctrl.forward();
    Timer(const Duration(seconds: 3), _dismiss);
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

  @override
  Widget build(BuildContext context) {
    const c = AppColors.dark;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: GestureDetector(
            onTap: _dismiss,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: c.outline, width: 0.5),
                  ),
                  child: Text(
                    widget.message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.onSurface, fontSize: AppType.sm),
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
