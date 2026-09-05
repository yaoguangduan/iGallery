import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../theme/app_theme.dart';

enum ToastKind { info, success, error }

void showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  _showOverlayToast(Overlay.of(context), message, kind, actionLabel, onAction);
}

void showToastGlobal(String message, {ToastKind kind = ToastKind.info}) {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return;
  final overlay = Overlay.of(ctx);
  _showOverlayToast(overlay, message, kind, null, null);
}

void _showOverlayToast(
  OverlayState overlay,
  String message,
  ToastKind kind,
  String? actionLabel,
  VoidCallback? onAction,
) {
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
      onDismiss: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  final String message;
  final ToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;

  const _Toast({
    required this.message,
    required this.kind,
    this.actionLabel,
    this.onAction,
    required this.onDismiss,
  });

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
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween(begin: const Offset(0, -0.4), end: Offset.zero)
        .animate(_fade);
    _ctrl.forward();
    final delay = widget.actionLabel != null
        ? 4000
        : widget.kind == ToastKind.error
            ? 3600
            : 2400;
    Timer(Duration(milliseconds: delay), _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    _ctrl.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  Color _dotColor(AppColors c) => switch (widget.kind) {
        ToastKind.success => c.ok,
        ToastKind.error => c.error,
        ToastKind.info => c.onSurfaceVariant,
      };

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
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
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: c.outline, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(
                            color: _dotColor(c),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            widget.message,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.onSurface,
                              fontSize: AppType.sm,
                            ),
                          ),
                        ),
                        if (widget.actionLabel != null) ...[
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: () {
                              widget.onAction?.call();
                              _dismiss();
                            },
                            child: Text(
                              widget.actionLabel!,
                              style: TextStyle(
                                color: c.brand,
                                fontSize: AppType.sm,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
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
