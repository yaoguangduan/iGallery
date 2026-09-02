import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

class KvStore {
  static final KvStore instance = KvStore._();
  KvStore._();

  Database? _db;
  Database get db => _db!;

  Future<void> init() async {
    if (_db != null) return;

    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = p.join(await getDatabasesPath(), 'igallery_prefs.db');
    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, _) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await _createUploadHistory(db);
        }
      },
    );
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)');
    await _createUploadHistory(db);
  }

  static Future<void> _createUploadHistory(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS upload_history (
        id TEXT PRIMARY KEY,
        filename TEXT NOT NULL,
        size INTEGER NOT NULL,
        status TEXT NOT NULL,
        server_id TEXT,
        thumb_id TEXT,
        error TEXT,
        server_url TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_upload_started ON upload_history(started_at DESC)');
  }

  Future<String?> get(String key) async {
    final rows = await _db?.query('kv', where: 'key = ?', whereArgs: [key]);
    if (rows == null || rows.isEmpty) return null;
    final v = rows.first['value'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> set(String key, String value) async {
    await _db?.insert('kv', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> getAll() async {
    final rows = await _db?.query('kv') ?? [];
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }
}
