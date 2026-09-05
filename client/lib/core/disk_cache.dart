import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api.dart';

/// 磁盘缓存 (P5 + 视频原文件缓存)
///
/// - 缩略图: 永久缓存 (id + jpg, immutable), 30 天未访问 → LRU 清理
/// - 视频原文件: 单文件 <= 50 MB 才缓存, 总量上限 500 MB LRU
/// - 图片原文件: 单文件 <= 20 MB 才缓存, 总量上限 300 MB LRU
///
/// 用户完全无感知。设置里可清理。

class CacheStats {
  final int thumbBytes;
  final int mediaBytes;
  final int thumbCount;
  final int mediaCount;
  CacheStats({
    required this.thumbBytes, required this.mediaBytes,
    required this.thumbCount, required this.mediaCount,
  });
  int get total => thumbBytes + mediaBytes;
}

class DiskCache {
  static final DiskCache instance = DiskCache._();
  DiskCache._();

  // 阈值
  static const int _thumbTtlDays = 30;
  static const int _mediaMaxBytesTotal = 800 * 1024 * 1024;   // 800 MB (video 500 + image 300)
  static const int _thumbMaxBytesTotal = 200 * 1024 * 1024;   // 200 MB
  static const int _videoMaxSingleBytes = 50 * 1024 * 1024;   // 50 MB
  static const int _imageMaxSingleBytes = 20 * 1024 * 1024;   // 20 MB

  Directory? _thumbDir;
  Directory? _mediaDir;
  final Map<String, Completer<File?>> _inflight = {};

  Future<void> init() async {
    if (_thumbDir != null) return;
    final base = await getApplicationSupportDirectory();
    _thumbDir = Directory(p.join(base.path, 'igallery_cache', 'thumbs'));
    _mediaDir = Directory(p.join(base.path, 'igallery_cache', 'media'));
    await _thumbDir!.create(recursive: true);
    await _mediaDir!.create(recursive: true);
    // 启动后异步清一次，不阻塞
    unawaited(_sweep());
  }

  // ── 缩略图 ──

  /// 返回本地文件；若不存在则从 url 下载
  Future<File?> getThumb(String id, String url, Map<String, String> headers) async {
    await init();
    final path = _thumbPath(id);
    final f = File(path);
    if (await f.exists()) {
      // 更新 mtime 表示访问过，方便 LRU
      unawaited(f.setLastModified(DateTime.now()).catchError((_) => f));
      return f;
    }
    return _download(url, headers, path, isThumb: true, id: id);
  }

  // ── 媒体原文件 ──

  Future<File?> getMedia(String id, String url, Map<String, String> headers, {
    required bool isVideo,
    int? knownSize,
  }) async {
    await init();
    final path = _mediaPath(id);
    final f = File(path);
    if (await f.exists()) {
      unawaited(f.setLastModified(DateTime.now()).catchError((_) => f));
      return f;
    }

    // 大小预筛：若已知超过阈值直接跳过缓存
    final limit = isVideo ? _videoMaxSingleBytes : _imageMaxSingleBytes;
    if (knownSize != null && knownSize > limit) return null;

    return _download(url, headers, path, isThumb: false, id: id, sizeLimit: limit);
  }

  /// 已缓存的路径（同步查询），不存在返回 null
  File? cachedMediaSync(String id) {
    if (_mediaDir == null) return null;
    final f = File(_mediaPath(id));
    return f.existsSync() ? f : null;
  }

  File? cachedThumbSync(String id) {
    if (_thumbDir == null) return null;
    final f = File(_thumbPath(id));
    return f.existsSync() ? f : null;
  }

  String _thumbPath(String id) => p.join(_thumbDir!.path, '$id.jpg');
  String _mediaPath(String id) => p.join(_mediaDir!.path, id);

  Future<File?> _download(
    String url, Map<String, String> headers, String savePath, {
    required bool isThumb, required String id, int? sizeLimit,
  }) async {
    // 同一 id 并发合并
    final key = savePath;
    if (_inflight.containsKey(key)) return _inflight[key]!.future;
    final completer = Completer<File?>();
    _inflight[key] = completer;

    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(headers);
      final resp = await Api.instance.client.send(req);
      if (resp.statusCode != 200) {
        // 非 200 也要 drain：否则这条连接的响应体没被消费，keep-alive socket 无法复用/释放
        // （例如缩略图对应的媒体已在服务端删除、网格里还是旧数据时命中 404）。
        await resp.stream.drain();
        completer.complete(null);
        return null;
      }
      final len = resp.contentLength;
      if (len != null && sizeLimit != null && len > sizeLimit) {
        completer.complete(null);
        await resp.stream.drain();
        return null;
      }

      final tmpPath = '$savePath.part';
      final tmp = File(tmpPath);
      final sink = tmp.openWrite();
      int written = 0;
      try {
        await for (final chunk in resp.stream) {
          written += chunk.length;
          if (sizeLimit != null && written > sizeLimit) {
            await sink.close();
            try { await tmp.delete(); } catch (_) {}
            completer.complete(null);
            return null;
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      await tmp.rename(savePath);
      final f = File(savePath);
      completer.complete(f);
      unawaited(_evictIfNeeded(isThumb: isThumb));
      return f;
    } catch (e) {
      if (kDebugMode) debugPrint('cache download error: $e');
      completer.complete(null);
      return null;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<CacheStats> stats() async {
    await init();
    final t = await _dirStats(_thumbDir!);
    final m = await _dirStats(_mediaDir!);
    return CacheStats(
      thumbBytes: t.$1, thumbCount: t.$2,
      mediaBytes: m.$1, mediaCount: m.$2,
    );
  }

  Future<(int, int)> _dirStats(Directory d) async {
    int bytes = 0, count = 0;
    try {
      await for (final e in d.list()) {
        if (e is File) {
          try {
            bytes += await e.length();
            count++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return (bytes, count);
  }

  Future<void> clearAll() async {
    await init();
    for (final d in [_thumbDir!, _mediaDir!]) {
      try {
        await for (final e in d.list()) {
          try { await e.delete(recursive: true); } catch (_) {}
        }
      } catch (_) {}
    }
  }

  Future<void> _sweep() async {
    await init();
    final cutoff = DateTime.now().subtract(const Duration(days: _thumbTtlDays));
    try {
      await for (final e in _thumbDir!.list()) {
        if (e is File) {
          try {
            final stat = await e.stat();
            if (stat.modified.isBefore(cutoff)) {
              await e.delete().catchError((_) => e);
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    await _evictIfNeeded(isThumb: true);
    await _evictIfNeeded(isThumb: false);
  }

  Future<void> _evictIfNeeded({required bool isThumb}) async {
    final dir = isThumb ? _thumbDir! : _mediaDir!;
    final limit = isThumb ? _thumbMaxBytesTotal : _mediaMaxBytesTotal;
    final entries = <(File, DateTime, int)>[];
    try {
      await for (final e in dir.list()) {
        if (e is File) {
          try {
            final st = await e.stat();
            entries.add((e, st.modified, st.size));
          } catch (_) {}
        }
      }
    } catch (_) { return; }
    int total = entries.fold(0, (s, e) => s + e.$3);
    if (total <= limit) return;
    // LRU: 最旧先删
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _, size) in entries) {
      if (total <= limit) break;
      try {
        await f.delete();
        total -= size;
      } catch (_) {}
    }
  }
}
