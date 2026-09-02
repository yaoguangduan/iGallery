import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'media_service.dart';
import 'upload_history.dart';

/// 全局上传管理器：并发上传 + 顶部进度条 + 上传历史记录
class UploadManager extends ChangeNotifier {
  static final UploadManager instance = UploadManager._();
  UploadManager._();

  static const int _concurrency = 4;

  bool _uploading = false;
  bool _dismissed = true;   // 进度条是否已收起
  int _total = 0;
  int _completed = 0;
  int _dedupCount = 0;
  int _failCount = 0;
  int _totalBytes = 0;
  int _sentBytes = 0;

  DateTime? _startedAt;
  DateTime? _lastTickAt;
  int _lastTickBytes = 0;
  double _speedBps = 0;   // 最近一次采样速度

  String _currentFilename = '';

  bool get uploading => _uploading;
  /// 进度条是否可见（上传中，或刚结束 2.5s 内展示完成态）
  bool get visible => !_dismissed && (_uploading || _completed > 0);
  int get total => _total;
  int get completed => _completed;
  int get dedupCount => _dedupCount;
  int get failCount => _failCount;
  int get totalBytes => _totalBytes;
  int get sentBytes => _sentBytes;
  double get progress => _totalBytes > 0 ? _sentBytes / _totalBytes : (_total > 0 ? _completed / _total : 0);
  double get speedBps => _speedBps;
  String get currentFilename => _currentFilename;
  Duration? get eta {
    if (_speedBps <= 0 || _sentBytes >= _totalBytes) return null;
    final remaining = _totalBytes - _sentBytes;
    return Duration(seconds: (remaining / _speedBps).round());
  }

  /// 上传一批文件。异步返回统计
  Future<UploadBatchResult> enqueue(
    MediaService service,
    List<File> files, {
    String? folderId,
    String? serverUrl,
  }) async {
    if (files.isEmpty) {
      return UploadBatchResult(uploaded: 0, dedup: 0, failed: 0);
    }
    _uploading = true;
    _dismissed = false;
    _total = files.length;
    _completed = 0;
    _dedupCount = 0;
    _failCount = 0;
    _totalBytes = 0;
    _sentBytes = 0;
    _startedAt = DateTime.now();
    _lastTickAt = _startedAt;
    _lastTickBytes = 0;
    _speedBps = 0;
    _currentFilename = '';

    // 预算 totalBytes
    final sizes = <int>[];
    for (final f in files) {
      try { sizes.add(await f.length()); } catch (_) { sizes.add(0); }
    }
    _totalBytes = sizes.fold(0, (s, v) => s + v);
    notifyListeners();

    // 写 pending 历史
    final ids = <String>[];
    for (var i = 0; i < files.length; i++) {
      final id = const Uuid().v4();
      ids.add(id);
      await UploadHistory.upsert(UploadHistoryItem(
        id: id,
        filename: files[i].path.split(Platform.pathSeparator).last,
        size: sizes[i],
        status: UploadStatus.pending,
        serverUrl: serverUrl ?? '',
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    }

    int index = 0;
    Future<void> worker() async {
      while (true) {
        final i = index;
        if (i >= files.length) return;
        index++;
        final hid = ids[i];
        final file = files[i];
        final filename = file.path.split(Platform.pathSeparator).last;
        _currentFilename = filename;
        notifyListeners();
        try {
          final result = await service.uploadFile(file, folderId: folderId);
          if (result?.dedup == true) {
            _dedupCount++;
            await UploadHistory.markFinished(
              id: hid, status: UploadStatus.dedup,
              serverId: result!.item.id, thumbId: result.item.id,
            );
          } else if (result != null) {
            await UploadHistory.markFinished(
              id: hid, status: UploadStatus.success,
              serverId: result.item.id, thumbId: result.item.id,
            );
          } else {
            _failCount++;
            await UploadHistory.markFinished(
              id: hid, status: UploadStatus.failed, error: 'empty response',
            );
          }
        } on Object catch (e) {
          _failCount++;
          await UploadHistory.markFinished(
            id: hid, status: UploadStatus.failed, error: e.toString(),
          );
        }
        _completed++;
        _sentBytes += sizes[i];
        _tickSpeed();
        notifyListeners();
      }
    }

    await Future.wait(List.generate(
      files.length < _concurrency ? files.length : _concurrency,
      (_) => worker(),
    ));

    final result = UploadBatchResult(
      uploaded: _total - _failCount - _dedupCount,
      dedup: _dedupCount,
      failed: _failCount,
    );

    // 收尾：上传完成，进度条保持完成态 2.5 秒后自动收起
    _uploading = false;
    notifyListeners();
    Timer(const Duration(milliseconds: 2500), () {
      _dismissed = true;
      notifyListeners();
    });
    return result;
  }

  void _tickSpeed() {
    final now = DateTime.now();
    final last = _lastTickAt;
    if (last == null) { _lastTickAt = now; _lastTickBytes = _sentBytes; return; }
    final dt = now.difference(last).inMilliseconds;
    if (dt < 500) return;   // 至少 0.5s 一次
    final db = _sentBytes - _lastTickBytes;
    _speedBps = db * 1000.0 / dt;
    _lastTickAt = now;
    _lastTickBytes = _sentBytes;
  }
}

class UploadBatchResult {
  final int uploaded;
  final int dedup;
  final int failed;
  UploadBatchResult({required this.uploaded, required this.dedup, required this.failed});

  bool get allOk => failed == 0;
  int get total => uploaded + dedup + failed;
}
