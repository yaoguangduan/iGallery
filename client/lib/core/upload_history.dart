import 'package:sqflite/sqflite.dart';

import 'kv_store.dart';

enum UploadStatus { pending, success, dedup, failed, cancelled }

String _statusStr(UploadStatus s) => switch (s) {
  UploadStatus.pending   => 'pending',
  UploadStatus.success   => 'success',
  UploadStatus.dedup     => 'dedup',
  UploadStatus.failed    => 'failed',
  UploadStatus.cancelled => 'cancelled',
};

UploadStatus _parseStatus(String s) => switch (s) {
  'success'   => UploadStatus.success,
  'dedup'     => UploadStatus.dedup,
  'failed'    => UploadStatus.failed,
  'cancelled' => UploadStatus.cancelled,
  _           => UploadStatus.pending,
};

class UploadHistoryItem {
  final String id;
  final String filename;
  final int size;
  final UploadStatus status;
  final String? serverId;
  final String? thumbId;
  final String? error;
  final String serverUrl;
  final int startedAtMs;
  final int? finishedAtMs;

  UploadHistoryItem({
    required this.id, required this.filename, required this.size,
    required this.status, this.serverId, this.thumbId, this.error,
    required this.serverUrl, required this.startedAtMs, this.finishedAtMs,
  });

  DateTime get startedAt => DateTime.fromMillisecondsSinceEpoch(startedAtMs);
  DateTime? get finishedAt => finishedAtMs == null ? null : DateTime.fromMillisecondsSinceEpoch(finishedAtMs!);
}

class UploadHistory {
  static Future<void> upsert(UploadHistoryItem it) async {
    await KvStore.instance.db.insert('upload_history', {
      'id': it.id,
      'filename': it.filename,
      'size': it.size,
      'status': _statusStr(it.status),
      'server_id': it.serverId,
      'thumb_id': it.thumbId,
      'error': it.error,
      'server_url': it.serverUrl,
      'started_at': it.startedAtMs,
      'finished_at': it.finishedAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> markFinished({
    required String id,
    required UploadStatus status,
    String? serverId,
    String? thumbId,
    String? error,
  }) async {
    await KvStore.instance.db.update('upload_history', {
      'status': _statusStr(status),
      'server_id': serverId,
      'thumb_id': thumbId,
      'error': error,
      'finished_at': DateTime.now().millisecondsSinceEpoch,
    }, where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<UploadHistoryItem>> list({int limit = 200, int offset = 0}) async {
    final rows = await KvStore.instance.db.query(
      'upload_history',
      orderBy: 'started_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  /// 把上次进程遗留的 pending 标成中断。
  ///
  /// app 被杀 / 崩溃时正在传的那批会永远停在"进行中"，
  /// 用户下次进来看到一堆假的进行中记录，不知道到底传没传成。
  /// 启动时调一次即可：真正在传的项目此刻还没写进表。
  static Future<void> markStalePending() async {
    await KvStore.instance.db.update(
      'upload_history',
      {
        'status': _statusStr(UploadStatus.failed),
        'error': '上传中断（应用退出）',
        'finished_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'status = ?',
      whereArgs: [_statusStr(UploadStatus.pending)],
    );
  }

  static Future<void> clear() async {
    await KvStore.instance.db.delete('upload_history');
  }

  static Future<void> delete(String id) async {
    await KvStore.instance.db.delete('upload_history', where: 'id = ?', whereArgs: [id]);
  }

  static UploadHistoryItem _fromRow(Map<String, Object?> r) => UploadHistoryItem(
    id: r['id'] as String,
    filename: r['filename'] as String,
    size: (r['size'] as int?) ?? 0,
    status: _parseStatus(r['status'] as String? ?? 'pending'),
    serverId: r['server_id'] as String?,
    thumbId: r['thumb_id'] as String?,
    error: r['error'] as String?,
    serverUrl: r['server_url'] as String? ?? '',
    startedAtMs: (r['started_at'] as int?) ?? 0,
    finishedAtMs: r['finished_at'] as int?,
  );
}
