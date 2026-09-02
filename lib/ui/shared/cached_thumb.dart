import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/disk_cache.dart';

/// 走磁盘缓存的缩略图（先本地 → 后网络 → 写盘）
/// 用户完全无感知。
class CachedThumb extends StatefulWidget {
  final String id;
  final String url;
  final Map<String, String> headers;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget Function(BuildContext)? errorBuilder;
  const CachedThumb({
    super.key,
    required this.id,
    required this.url,
    this.headers = const {},
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorBuilder,
  });

  @override
  State<CachedThumb> createState() => _CachedThumbState();
}

class _CachedThumbState extends State<CachedThumb> {
  File? _file;
  bool _failed = false;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CachedThumb old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.url != widget.url) {
      _file = null;
      _failed = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    // 同步先查一次，命中直接秒出
    final cached = DiskCache.instance.cachedThumbSync(widget.id);
    if (cached != null) {
      if (mounted) setState(() => _file = cached);
      return;
    }
    if (_resolving) return;
    _resolving = true;
    final f = await DiskCache.instance.getThumb(widget.id, widget.url, widget.headers);
    if (!mounted) return;
    setState(() {
      _resolving = false;
      if (f == null) { _failed = true; }
      else { _file = f; }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return widget.errorBuilder?.call(context) ?? const SizedBox.shrink();
    }
    if (_file == null) {
      return widget.placeholder ?? const SizedBox.shrink();
    }
    return Image.file(
      _file!, fit: widget.fit,
      errorBuilder: (ctx, _, __) =>
          widget.errorBuilder?.call(ctx) ?? const SizedBox.shrink(),
    );
  }
}
