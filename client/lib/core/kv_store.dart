import 'package:flutter/foundation.dart';
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
      version: 5,
      onCreate: (db, _) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await _createUploadHistory(db);
        }
        if (oldV < 3) {
          await _createUploadedHashes(db);
        }
        if (oldV < 4) {
          await _createAssetHashes(db);
        }
        if (oldV < 5) {
          await db.execute('DROP TABLE IF EXISTS uploaded_hashes');
          await _createUploadedHashes(db);
        }
      },
    );
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)',
    );
    await _createUploadHistory(db);
    await _createUploadedHashes(db);
    await _createAssetHashes(db);
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
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_upload_started ON upload_history(started_at DESC)',
    );
  }

  static Future<void> _createUploadedHashes(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS uploaded_hashes (
        server_key TEXT NOT NULL,
        checksum TEXT NOT NULL,
        PRIMARY KEY(server_key, checksum)
      )
    ''');
  }

  static Future<void> _createAssetHashes(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS asset_hashes (
        asset_id TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL,
        checksum TEXT NOT NULL
      )
    ''');
  }

  Future<String?> get(String key) async {
    final rows = await _db?.query('kv', where: 'key = ?', whereArgs: [key]);
    if (rows == null || rows.isEmpty) return null;
    final v = rows.first['value'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> set(String key, String value) async {
    await _db?.insert('kv', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> getAll() async {
    final rows = await _db?.query('kv') ?? [];
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }
}
