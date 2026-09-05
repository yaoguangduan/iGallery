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
  /// 采样质量。马赛克封面(LockedCover)靠 FilterQuality.none 的最近邻放大出块状效果,
  /// 其余场景保持 Image 默认的 medium。
  final FilterQuality filterQuality;
  /// 解码期降采样目标尺寸(透传 Image.file → ResizeImage)。马赛克必须靠它在
  /// **解码时**真降到 8×8,再配合 FilterQuality.none 放大出色块;只靠布局缩小
  /// 是 canvas 变换,光栅化时会合并成一次原图→屏幕的采样,出不来马赛克。
  final int? cacheWidth;
  final int? cacheHeight;
  const CachedThumb({
    super.key,
    required this.id,
    required this.url,
    this.headers = const {},
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorBuilder,
    this.filterQuality = FilterQuality.medium,
    this.cacheWidth,
    this.cacheHeight,
  });

  @override
  State<CachedThumb> createState() => _CachedThumbState();
}

class _CachedThumbState extends State<CachedThumb> {
  File? _file;
  bool _failed = false;

  /// 每次目标变化就自增。异步回来时对不上说明目标早换了，丢弃结果。
  ///
  /// 原来这里是一个 `bool _resolving` 守卫，有两个都会让缩略图变空白的 bug：
  ///  1. `if (_resolving) return;` —— 换 id 时如果旧 id 的请求还在飞，
  ///     直接早退，而 didUpdateWidget 已经把 _file 清空了，于是**永久空白**，
  ///     没有任何东西会再把它填回来。
  ///  2. 旧请求回来后照样 setState(_file = 旧图)，把**别人的**缩略图贴上去。
  /// 缩放会疯狂重建网格，正好把这两个 race 放大 —— "缩放后视频缩略图没了"。
  int _gen = 0;

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
    final gen = ++_gen;
    // 同步先查一次，命中直接秒出
    final cached = DiskCache.instance.cachedThumbSync(widget.id);
    if (cached != null) {
      if (mounted && gen == _gen) setState(() => _file = cached);
      return;
    }
    // 不做 in-flight 去重：DiskCache 内部已按路径合并并发请求了
    final f = await DiskCache.instance
        .getThumb(widget.id, widget.url, widget.headers);
    if (!mounted || gen != _gen) return;
    setState(() {
      if (f == null) { _failed = true; } else { _file = f; }
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
      filterQuality: widget.filterQuality,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      // 换图时不要先闪一帧空白
      gaplessPlayback: true,
      errorBuilder: (ctx, _, __) =>
          widget.errorBuilder?.call(ctx) ?? const SizedBox.shrink(),
    );
  }
}
