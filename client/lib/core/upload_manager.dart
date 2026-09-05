import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'hash_sync.dart';
import 'media_service.dart';
import 'platform.dart';
import 'upload_history.dart';
import 'upload_permissions.dart';

/// 一个待上传项：文件 + 拍摄时间。
///
/// `takenAtIso` 必须由挑选来源填：移动端从相册拿到的 File 是**导出的缓存副本**，
/// 它的 mtime 是导出那一刻，不是拍摄时间；iOS 走 PHImageManager 导出时 EXIF
/// 还常被剥掉，所以服务端两条路（EXIF / mtime）会同时失效。
/// 桌面端选的是磁盘上的原文件，mtime 有意义，可以留 null 让服务端兜底。
class PendingUpload {
  final File file;
  final String? takenAtIso;
  final String? assetId;
  final String? assetFingerprint;

  const PendingUpload(
    this.file, {
    this.takenAtIso,
    this.assetId,
    this.assetFingerprint,
  });
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

  /// 断网后自动重试的最长等待时间。
  static const Duration _retryWindow = Duration(minutes: 5);

  /// 重试探测间隔。
  static const Duration _retryInterval = Duration(seconds: 10);

  bool _uploading = false;
  bool _dismissed = true; // 进度条是否已收起
  bool _barVisible = false; // 顶部条只在用户点"后台"后才显示
  bool _keepAliveActive = false; // 前台服务是否真的起来了（决定要不要 updateService）
  bool _retrying = false; // 断网重试中
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
  double _speedBps = 0; // 最近一次采样速度
  DateTime? _lastNotifyAt; // 进度回调节流，防止高速上传时 UI 被刷爆

  String _currentFilename = '';
  String? _lastError;
  UploadCancelToken? _cancelToken;
  Completer<void>? _retryGate;

  bool get uploading => _uploading;
  bool get retrying => _retrying;
  String? get lastError => _lastError;
  bool get cancelling => _cancelToken?.isCancelled ?? false;

  /// 进度条是否可见：仅在用户从浮层点了"后台运行"后才显示
  bool get visible =>
      _barVisible && !_dismissed && (_uploading || _completed > 0);
  int get total => _total;
  int get completed => _completed;
  int get dedupCount => _dedupCount;
  int get failCount => _failCount;
  int get cancelCount => _cancelCount;
  int get totalBytes => _totalBytes;
  int get sentBytes =>
      _baseBytes + _inflightBytes.values.fold(0, (s, v) => s + v);
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

  /// 用户点"取消"：停掉剩余文件、中止重试等待、正在传的那个立刻断流。
  void cancel() {
    _cancelToken?.cancel();
    _retryGate?.complete();
    notifyListeners();
  }

  /// 用户从浮层点"后台运行"时，显示顶部进度条
  void showBar() {
    _barVisible = true;
    notifyListeners();
  }

  /// 手动收起进度条（完成态时用户点 ×）
  void dismiss() {
    _dismissed = true;
    notifyListeners();
  }

  /// 断网后循环探测服务器，直到恢复或超时/取消。
  /// 返回 true 表示恢复连接，false 表示超时或被取消。
  Future<bool>? _retryFuture;

  Future<bool> _waitForConnection(UploadCancelToken token) {
    _retryFuture ??= _doRetryProbe(token).whenComplete(() {
      _retryFuture = null;
    });
    return _retryFuture!;
  }

  Future<bool> _doRetryProbe(UploadCancelToken token) async {
    _retrying = true;
    _retryGate ??= Completer<void>();
    _speedBps = 0;
    notifyListeners();
    _updateNotificationRetry();

    final deadline = DateTime.now().add(_retryWindow);
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (token.isCancelled) return false;
        final base = apiConfig.baseUrl;
        if (base != null && base.isNotEmpty) {
          final info = await Api.instance.probe(base, token: apiConfig.token);
          if (info != null) return true;
        }
        if (token.isCancelled) return false;
        final gate = _retryGate;
        if (gate != null && !gate.isCompleted) {
          await Future.any([
            Future.delayed(_retryInterval),
            gate.future,
          ]);
        } else {
          await Future.delayed(_retryInterval);
        }
      }
      return false;
    } finally {
      _retrying = false;
      _retryGate = null;
      notifyListeners();
    }
  }

  void _updateNotificationRetry() {
    if (!isMobile || Platform.isIOS || !_keepAliveActive) return;
    FlutterForegroundTask.updateService(
      notificationTitle: '上传暂停 — 等待网络恢复',
      notificationText: '已完成 $_completed/$_total',
    );
  }

  Future<void> _acquireKeepAlive(int count) async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    if (!isMobile || Platform.isIOS) return;
    // 没有通知权限就别起前台服务：startService 会失败，而且是静默失败，
    // 后面 updateService 也全是空转。宁可退化成"只有 wakelock 保活"。
    if (!await UploadPermissions.requestNotificationPermission()) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'upload',
        channelName: '上传服务',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
    await FlutterForegroundTask.startService(
      notificationTitle: '正在上传',
      notificationText: '共 $count 个文件',
    );
    _keepAliveActive = true;
  }

  Future<void> _releaseKeepAlive() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    if (!isMobile || Platform.isIOS) return;
    if (!_keepAliveActive) return;
    _keepAliveActive = false;
    await FlutterForegroundTask.stopService();
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
    _barVisible = false;
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
    _retrying = false;
    _retryGate = null;
    _retryFuture = null;

    await _acquireKeepAlive(files.length);

    // 预算 totalBytes
    final sizes = <int>[];
    for (final f in files) {
      try {
        sizes.add(await f.file.length());
      } catch (_) {
        sizes.add(0);
      }
    }
    _totalBytes = sizes.fold(0, (s, v) => s + v);
    notifyListeners();

    // 写 pending 历史
    final ids = <String>[];
    for (var i = 0; i < files.length; i++) {
      final id = const Uuid().v4();
      ids.add(id);
      await UploadHistory.upsert(
        UploadHistoryItem(
          id: id,
          filename: files[i].file.path.split(Platform.pathSeparator).last,
          size: sizes[i],
          status: UploadStatus.pending,
          serverUrl: serverUrl ?? '',
          startedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
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
            id: hid,
            status: UploadStatus.cancelled,
            error: '已取消',
          );
          notifyListeners();
          continue;
        }

        _currentFilename = filename;
        _inflightBytes[slot] = 0;
        notifyListeners();

        var succeeded = false;
        var retryable = true;
        while (retryable) {
          retryable = false;

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
            if (result != null) {
              succeeded = true;
              if (result.dedup) _dedupCount++;
              await UploadHistory.markFinished(
                id: hid,
                status:
                    result.dedup ? UploadStatus.dedup : UploadStatus.success,
                serverId: result.item.id,
                thumbId: result.item.id,
              );
              final checksum = result.item.checksum;
              if (checksum != null) {
                try {
                  await HashSync.instance.add(checksum);
                  if (pending.assetId != null &&
                      pending.assetFingerprint != null) {
                    await HashSync.instance.cacheAssetChecksum(
                      pending.assetId!,
                      pending.assetFingerprint!,
                      checksum,
                    );
                  }
                } catch (_) {}
              }
            } else {
              _failCount++;
              _lastError = '服务器未返回结果';
              await UploadHistory.markFinished(
                id: hid,
                status: UploadStatus.failed,
                error: '服务器未返回结果',
              );
            }
          } on UploadCancelledException {
            _cancelCount++;
            await UploadHistory.markFinished(
              id: hid,
              status: UploadStatus.cancelled,
              error: '已取消',
            );
          } on ApiException catch (e) {
            // 进入网络等待前先停看门狗：否则等待期间 lastMoveAt 不再更新，
            // 超过 _stallTimeout 它会误判"卡死"→ cancel 整个批次 token →
            // _doRetryProbe 见 token.isCancelled 提前放弃重试，剩余文件全被标成已取消。
            watchdog.cancel();
            if (!token.isCancelled && _isNetworkError(e)) {
              _inflightBytes[slot] = 0;
              final restored = await _waitForConnection(token);
              if (restored && !token.isCancelled) {
                retryable = true;
                continue;
              }
            }
            if (token.isCancelled) {
              _cancelCount++;
              await UploadHistory.markFinished(
                id: hid,
                status: UploadStatus.cancelled,
                error: '已取消',
              );
            } else {
              _failCount++;
              _lastError = e.displayMessage;
              await UploadHistory.markFinished(
                id: hid,
                status: UploadStatus.failed,
                error: e.displayMessage,
              );
            }
          } on Object catch (e) {
            watchdog.cancel(); // 同上：进入网络等待前先停看门狗
            if (token.isCancelled) {
              _cancelCount++;
              await UploadHistory.markFinished(
                id: hid,
                status: UploadStatus.cancelled,
                error: '已取消',
              );
            } else if (_looksLikeNetworkError(e)) {
              _inflightBytes[slot] = 0;
              final restored = await _waitForConnection(token);
              if (restored && !token.isCancelled) {
                retryable = true;
                continue;
              }
              if (token.isCancelled) {
                _cancelCount++;
                await UploadHistory.markFinished(
                  id: hid,
                  status: UploadStatus.cancelled,
                  error: '已取消',
                );
              } else {
                _failCount++;
                _lastError = '网络超时';
                await UploadHistory.markFinished(
                  id: hid,
                  status: UploadStatus.failed,
                  error: '网络超时',
                );
              }
            } else {
              _failCount++;
              _lastError = '$e';
              await UploadHistory.markFinished(
                id: hid,
                status: UploadStatus.failed,
                error: '$e',
              );
            }
          } finally {
            watchdog.cancel();
          }
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
    await _releaseKeepAlive();
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

  static bool _isNetworkError(ApiException e) =>
      e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout;

  static bool _looksLikeNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is http.ClientException;

  /// 进度字节回调里用：节流到 ~4 次/秒，既保证进度条平滑，又不刷爆 UI。
  /// 高速上传时 onSent 每秒能来上千次，每次都 notify 会把渲染线程拖垮。
  void _throttledTick() {
    final now = DateTime.now();
    final last = _lastNotifyAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 250)) {
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
    if (last == null) {
      _lastTickAt = now;
      _lastTickBytes = sent;
      return;
    }
    final dt = now.difference(last).inMilliseconds;
    if (dt < 500) return;
    _speedBps = (sent - _lastTickBytes) * 1000.0 / dt;
    _lastTickAt = now;
    _lastTickBytes = sent;
    _updateNotification();
  }

  void _updateNotification() {
    if (!isMobile || Platform.isIOS) return;
    // 没起前台服务时 updateService 是纯空转，而这个方法在字节回调里高频触发。
    if (!_keepAliveActive) return;
    FlutterForegroundTask.updateService(
      notificationTitle: '正在上传 $_completed/$_total',
      notificationText: _currentFilename,
    );
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
