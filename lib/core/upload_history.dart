import 'package:sqflite/sqflite.dart';

import 'kv_store.dart';

enum UploadStatus { pending, success, dedup, failed }

String _statusStr(UploadStatus s) => switch (s) {
  UploadStatus.pending => 'pending',
  UploadStatus.success => 'success',
  UploadStatus.dedup   => 'dedup',
  UploadStatus.failed  => 'failed',
};

UploadStatus _parseStatus(String s) => switch (s) {
  'success' => UploadStatus.success,
  'dedup'   => UploadStatus.dedup,
  'failed'  => UploadStatus.failed,
  _         => UploadStatus.pending,
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
