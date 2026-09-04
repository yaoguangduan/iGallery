import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'api.dart';
import 'kv_store.dart';

class HashSync {
  static final HashSync instance = HashSync._();
  HashSync._();

  Set<String> _cache = {};
  bool _synced = false;

  bool get synced => _synced;

  bool contains(String checksum) => _cache.contains(checksum);

  Future<void> syncFromServer() async {
    try {
      final json = await Api.instance.getJson('/v1/media/checksums') as Map<String, dynamic>;
      final list = (json['checksums'] as List).cast<String>();
      final db = KvStore.instance.db;
      final batch = db.batch();
      batch.delete('uploaded_hashes');
      for (final c in list) {
        batch.insert('uploaded_hashes', {'checksum': c});
      }
      await batch.commit(noResult: true);
      _cache = list.toSet();
      _synced = true;
    } catch (_) {}
  }

  Future<void> loadLocal() async {
    final rows = await KvStore.instance.db.query('uploaded_hashes');
    _cache = rows.map((r) => r['checksum'] as String).toSet();
    if (_cache.isNotEmpty) _synced = true;
  }

  Future<void> add(String checksum) async {
    _cache.add(checksum);
    await KvStore.instance.db.insert(
      'uploaded_hashes', {'checksum': checksum},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String> computeFileHash(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }
}
