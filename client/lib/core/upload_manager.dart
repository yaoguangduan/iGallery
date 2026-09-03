import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'media_service.dart';
import 'upload_history.dart';

/// 一个待上传项：文件 + 拍摄时间。
///
/// `takenAtIso` 必须由挑选来源填：移动端从相册拿到的 File 是**导出的缓存副本**，
/// 它的 mtime 是导出那一刻，不是拍摄时间；iOS 走 PHImageManager 导出时 EXIF
/// 还常被剥掉，所以服务端两条路（EXIF / mtime）会同时失效。
/// 桌面端选的是磁盘上的原文件，mtime 有意义，可以留 null 让服务端兜底。
class PendingUpload {
  final File file;
  final String? takenAtIso;
  const PendingUpload(this.file, {this.takenAtIso});
}

/// 全局上传管理器：并发上传 + 顶部进度条 + 上传历史记录
class UploadManager extends ChangeNotifier {
  static final UploadManager instance = UploadManager._();
  UploadManager._();

  static const int _concurrency = 4;

  /// 单个文件多久没有任何字节流动就判定为卡死。
  ///
  /// 上传不设 HTTP 总超时是对的（传大视频本来就要几十分钟），但完全不设兜底
  /// 就变成了"服务器中途挂掉 → 进度条永远卡住 → 只能杀 app"。
  /// 看门狗只盯"有没有在动"，慢但在动的传输不会被误杀。
  static const Duration _stallTimeout = Duration(seconds: 180);

  bool _uploading = false;
  bool _dismissed = true;   // 进度条是否已收起
  int _total = 0;
  int _completed = 0;
  int _dedupCount = 0;
  int _failCount = 0;
  int _cancelCount = 0;
  int _totalBytes = 0;
  /// 已完成文件累计的字节数（不含正在传的那个）
  int _baseBytes = 0;
  /// 正在传的各文件已发送字节：id → sent
  final Map<int, int> _inflightBytes = {};

  DateTime? _lastTickAt;
  int _lastTickBytes = 0;
  double _speedBps = 0;   // 最近一次采样速度
  DateTime? _lastNotifyAt;   // 进度回调节流，防止高速上传时 UI 被刷爆

  String _currentFilename = '';
  String? _lastError;
  UploadCancelToken? _cancelToken;

  bool get uploading => _uploading;
  String? get lastError => _lastError;
  bool get cancelling => _cancelToken?.isCancelled ?? false;
  /// 进度条是否可见（上传中，或刚结束展示完成态）
  bool get visible => !_dismissed && (_uploading || _completed > 0);
  int get total => _total;
  int get completed => _completed;
  int get dedupCount => _dedupCount;
  int get failCount => _failCount;
  int get cancelCount => _cancelCount;
  int get totalBytes => _totalBytes;
  int get sentBytes => _baseBytes + _inflightBytes.values.fold(0, (s, v) => s + v);
  double get progress => _totalBytes > 0
      ? (sentBytes / _totalBytes).clamp(0.0, 1.0)
      : (_total > 0 ? _completed / _total : 0);
  double get speedBps => _speedBps;
  String get currentFilename => _currentFilename;
  Duration? get eta {
    final sent = sentBytes;
    if (_speedBps <= 0 || sent >= _totalBytes) return null;
    return Duration(seconds: ((_totalBytes - sent) / _speedBps).round());
  }

  /// 用户点"取消"：停掉剩余文件，正在传的那个立刻断流。
  /// 服务端收不到完整 multipart，会删掉临时文件且不写库 —— 相当于没传过。
  void cancel() {
    _cancelToken?.cancel();
    notifyListeners();
  }

  /// 手动收起进度条（完成态时用户点 ×）
  void dismiss() {
    _dismissed = true;
    notifyListeners();
  }

  /// 上传一批文件。异步返回统计
  Future<UploadBatchResult> enqueue(
    MediaService service,
    List<PendingUpload> files, {
    String? folderId,
    String? serverUrl,
  }) async {
    if (files.isEmpty) {
      return UploadBatchResult(uploaded: 0, dedup: 0, failed: 0, cancelled: 0);
    }
    final token = UploadCancelToken();
    _cancelToken = token;
    _uploading = true;
    _dismissed = false;
    _total = files.length;
    _completed = 0;
    _dedupCount = 0;
    _failCount = 0;
    _cancelCount = 0;
    _totalBytes = 0;
    _baseBytes = 0;
    _inflightBytes.clear();
    _lastTickAt = DateTime.now();
    _lastTickBytes = 0;
    _speedBps = 0;
    _lastNotifyAt = null;
    _currentFilename = '';
    _lastError = null;

    // 预算 totalBytes
    final sizes = <int>[];
    for (final f in files) {
      try { sizes.add(await f.file.length()); } catch (_) { sizes.add(0); }
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
        filename: files[i].file.path.split(Platform.pathSeparator).last,
        size: sizes[i],
        status: UploadStatus.pending,
        serverUrl: serverUrl ?? '',
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    }

    int index = 0;
    Future<void> worker(int slot) async {
      while (true) {
        final i = index;
        if (i >= files.length) return;
        index++;
        final hid = ids[i];
        final pending = files[i];
        final file = pending.file;
        final filename = file.path.split(Platform.pathSeparator).last;

        // 已取消：剩下的直接记为取消，不再发起请求
        if (token.isCancelled) {
          _cancelCount++;
          _completed++;
          await UploadHistory.markFinished(
            id: hid, status: UploadStatus.cancelled, error: '已取消',
          );
          notifyListeners();
          continue;
        }

        _currentFilename = filename;
        _inflightBytes[slot] = 0;
        notifyListeners();

        // 看门狗：只要字节还在动就续命，静止超过 _stallTimeout 判定卡死
        var lastMoveAt = DateTime.now();
        final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
          if (DateTime.now().difference(lastMoveAt) > _stallTimeout) {
            token.cancel();
          }
        });

        try {
          final result = await service.uploadFile(
            file,
            folderId: folderId,
            takenAtIso: pending.takenAtIso,
            cancelToken: token,
            onSent: (sent) {
              lastMoveAt = DateTime.now();
              _inflightBytes[slot] = sent;
              _throttledTick();
            },
          );
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
            _lastError = '服务器未返回结果';
            await UploadHistory.markFinished(
              id: hid, status: UploadStatus.failed, error: '服务器未返回结果',
            );
          }
        } on UploadCancelledException {
          _cancelCount++;
          await UploadHistory.markFinished(
            id: hid, status: UploadStatus.cancelled, error: '已取消',
          );
        } on ApiException catch (e) {
          _failCount++;
          _lastError = e.displayMessage;
          await UploadHistory.markFinished(
            id: hid, status: UploadStatus.failed, error: e.displayMessage,
          );
        } on Object catch (e) {
          // 取消会让底层连接抛各种 ClientException，归到"已取消"而不是"失败"
          if (token.isCancelled) {
            _cancelCount++;
            await UploadHistory.markFinished(
              id: hid, status: UploadStatus.cancelled, error: '已取消',
            );
          } else {
            _failCount++;
            _lastError = '$e';
            await UploadHistory.markFinished(
              id: hid, status: UploadStatus.failed, error: '$e',
            );
          }
        } finally {
          watchdog.cancel();
        }

        // 这个文件结束：把它的字节数并进已完成基数
        _baseBytes += sizes[i];
        _inflightBytes.remove(slot);
        _completed++;
        _tickSpeed();
        notifyListeners();
      }
    }

    final workers = files.length < _concurrency ? files.length : _concurrency;
    await Future.wait(List.generate(workers, (slot) => worker(slot)));

    final result = UploadBatchResult(
      uploaded: _total - _failCount - _dedupCount - _cancelCount,
      dedup: _dedupCount,
      failed: _failCount,
      cancelled: _cancelCount,
    );

    _uploading = false;
    _cancelToken = null;
    _currentFilename = '';
    notifyListeners();

    // 全部成功才自动收起。有失败/取消时留在原地，
    // 让用户看得到并能点进历史 —— 自动消失等于把错误藏起来。
    if (result.failed == 0 && result.cancelled == 0) {
      Timer(const Duration(milliseconds: 2500), () {
        _dismissed = true;
        notifyListeners();
      });
    }
    return result;
  }

  /// 进度字节回调里用：节流到 ~4 次/秒，既保证进度条平滑，又不刷爆 UI。
  /// 高速上传时 onSent 每秒能来上千次，每次都 notify 会把渲染线程拖垮。
  void _throttledTick() {
    final now = DateTime.now();
    final last = _lastNotifyAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastNotifyAt = now;
    _tickSpeed();
    notifyListeners();
  }

  void _tickSpeed() {
    final now = DateTime.now();
    final last = _lastTickAt;
    final sent = sentBytes;
    if (last == null) { _lastTickAt = now; _lastTickBytes = sent; return; }
    final dt = now.difference(last).inMilliseconds;
    if (dt < 500) return;   // 至少 0.5s 一次
    _speedBps = (sent - _lastTickBytes) * 1000.0 / dt;
    _lastTickAt = now;
    _lastTickBytes = sent;
  }
}

class UploadBatchResult {
  final int uploaded;
  final int dedup;
  final int failed;
  final int cancelled;
  UploadBatchResult({
    required this.uploaded,
    required this.dedup,
    required this.failed,
    this.cancelled = 0,
  });

  bool get allOk => failed == 0 && cancelled == 0;
  int get total => uploaded + dedup + failed + cancelled;
}
