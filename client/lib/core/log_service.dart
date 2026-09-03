import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import 'api.dart';
import 'kv_store.dart';

/// Client-side error log: persist to local SQLite, background upload to server.
class LogService {
  static final LogService instance = LogService._();
  LogService._();

  static const int _maxLocal = 500;
  static const Duration _uploadInterval = Duration(minutes: 5);
  Timer? _uploadTimer;

  Future<void> init() async {
    await _ensureTable();
    _uploadTimer?.cancel();
    _uploadTimer = Timer.periodic(_uploadInterval, (_) => flush());
  }

  Future<void> _ensureTable() async {
    await KvStore.instance.db.execute('''
      CREATE TABLE IF NOT EXISTS client_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        detail TEXT,
        created_at INTEGER NOT NULL,
        uploaded INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await KvStore.instance.db.execute(
      'CREATE INDEX IF NOT EXISTS idx_logs_uploaded ON client_logs(uploaded, created_at)',
    );
  }

  Future<void> log(String level, String message, {String? detail}) async {
    try {
      await KvStore.instance.db.insert('client_logs', {
        'level': level,
        'message': message,
        'detail': detail,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'uploaded': 0,
      });
      await _trimOld();
    } catch (e) {
      dev.log('LogService.log failed: $e');
    }
  }

  Future<void> error(String message, {Object? error, StackTrace? stack}) async {
    final detail = [
      if (error != null) error.toString(),
      if (stack != null) stack.toString().split('\n').take(10).join('\n'),
    ].join('\n');
    await log('error', message, detail: detail.isEmpty ? null : detail);
  }

  Future<void> warn(String message, {String? detail}) =>
      log('warn', message, detail: detail);

  Future<void> info(String message, {String? detail}) =>
      log('info', message, detail: detail);

  /// Upload pending logs to server. Fails silently.
  Future<void> flush() async {
    if (apiConfig.baseUrl == null || apiConfig.baseUrl!.isEmpty) return;
    try {
      final rows = await KvStore.instance.db.query(
        'client_logs',
        where: 'uploaded = 0',
        orderBy: 'created_at ASC',
        limit: 50,
      );
      if (rows.isEmpty) return;

      final logs = rows.map((r) => {
        'level': r['level'],
        'message': r['message'],
        'detail': r['detail'],
        'created_at': r['created_at'],
      }).toList();

      final resp = await http.Client()
          .post(
            Uri.parse('${apiConfig.baseUrl}/v1/logs'),
            headers: {
              'Content-Type': 'application/json',
              if (apiConfig.token != null && apiConfig.token!.isNotEmpty)
                'Authorization': 'Bearer ${apiConfig.token}',
            },
            body: jsonEncode({'logs': logs}),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final ids = rows.map((r) => r['id'] as int).toList();
        for (final chunk in _chunks(ids, 100)) {
          final placeholders = List.filled(chunk.length, '?').join(',');
          await KvStore.instance.db.rawUpdate(
            'UPDATE client_logs SET uploaded = 1 WHERE id IN ($placeholders)',
            chunk,
          );
        }
      }
    } catch (e) {
      if (kDebugMode) dev.log('LogService.flush failed: $e');
    }
  }

  Future<void> _trimOld() async {
    try {
      final count = Sqflite.firstIntValue(
        await KvStore.instance.db.rawQuery('SELECT COUNT(*) FROM client_logs'),
      ) ?? 0;
      if (count > _maxLocal) {
        await KvStore.instance.db.rawDelete(
          'DELETE FROM client_logs WHERE id IN '
          '(SELECT id FROM client_logs ORDER BY created_at ASC LIMIT ?)',
          [count - _maxLocal],
        );
      }
    } catch (_) {}
  }

  /// Recent logs for debug display
  Future<List<Map<String, dynamic>>> recent({int limit = 50}) async {
    return KvStore.instance.db.query(
      'client_logs',
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<void> clearAll() async {
    await KvStore.instance.db.delete('client_logs');
  }

  List<List<T>> _chunks<T>(List<T> list, int size) {
    final result = <List<T>>[];
    for (var i = 0; i < list.length; i += size) {
      result.add(list.sublist(i, (i + size).clamp(0, list.length)));
    }
    return result;
  }
}
