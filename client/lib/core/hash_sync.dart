import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:hashlib/hashlib.dart';
import 'package:sqflite/sqflite.dart';

import 'api.dart';
import 'kv_store.dart';

class HashSync extends ChangeNotifier {
  static final HashSync instance = HashSync._();
  HashSync._();

  static final RegExp _xxh128Pattern = RegExp(r'^[0-9a-f]{32}$');

  Set<String> _cache = {};
  String? _cacheServerKey;
  bool _synced = false;
  Future<void> _operationTail = Future<void>.value();

  String? get _currentServerKey => apiConfig.baseUrl;
  bool get synced =>
      _synced &&
      _cacheServerKey != null &&
      _cacheServerKey == _currentServerKey;

  bool contains(String checksum) => synced && _cache.contains(checksum);

  static bool isCanonical(String checksum) => _xxh128Pattern.hasMatch(checksum);

  Future<void> syncFromServer() {
    return _enqueue(() async {
      final serverKey = _currentServerKey;
      if (serverKey == null || serverKey.isEmpty) return;
      try {
        final json =
            await Api.instance.getJson('/v1/media/checksums')
                as Map<String, dynamic>;
        if (_currentServerKey != serverKey) return;
        final list = (json['checksums'] as List)
            .cast<String>()
            .where(isCanonical)
            .toList(growable: false);
        final db = KvStore.instance.db;
        final batch = db.batch();
        batch.delete(
          'uploaded_hashes',
          where: 'server_key = ?',
          whereArgs: [serverKey],
        );
        for (final checksum in list) {
          batch.insert('uploaded_hashes', {
            'server_key': serverKey,
            'checksum': checksum,
          });
        }
        await batch.commit(noResult: true);
        if (_currentServerKey != serverKey) return;
        _cache = list.toSet();
        _cacheServerKey = serverKey;
        _synced = true;
        notifyListeners();
      } catch (_) {}
    });
  }

  Future<void> loadLocal() async {
    final serverKey = _currentServerKey;
    if (serverKey == null || serverKey.isEmpty) return;
    final rows = await KvStore.instance.db.query(
      'uploaded_hashes',
      columns: ['checksum'],
      where: 'server_key = ?',
      whereArgs: [serverKey],
    );
    if (_currentServerKey != serverKey) return;
    _cache = rows
        .map((row) => row['checksum'] as String)
        .where(isCanonical)
        .toSet();
    _cacheServerKey = serverKey;
    _synced = true;
    notifyListeners();
  }

  Future<void> add(String checksum) {
    if (!isCanonical(checksum)) return Future<void>.value();
    return _enqueue(() async {
      final serverKey = _currentServerKey;
      if (serverKey == null || serverKey.isEmpty) return;
      if (_cacheServerKey != serverKey) {
        _cache = {};
        _cacheServerKey = serverKey;
      }
      _cache.add(checksum);
      _synced = true;
      await KvStore.instance.db.insert('uploaded_hashes', {
        'server_key': serverKey,
        'checksum': checksum,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      notifyListeners();
    });
  }

  Future<String?> assetChecksum(String assetId, String fingerprint) async {
    final rows = await KvStore.instance.db.query(
      'asset_hashes',
      columns: ['checksum'],
      where: 'asset_id = ? AND fingerprint = ?',
      whereArgs: [assetId, fingerprint],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final checksum = rows.first['checksum'] as String;
    return isCanonical(checksum) ? checksum : null;
  }

  Future<void> cacheAssetChecksum(
    String assetId,
    String fingerprint,
    String checksum,
  ) async {
    if (!isCanonical(checksum)) return;
    await KvStore.instance.db.insert('asset_hashes', {
      'asset_id': assetId,
      'fingerprint': fingerprint,
      'checksum': checksum,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String> computeFileHash(File file) {
    final path = file.path;
    return Isolate.run(() async {
      final digest = await xxh128.file(File(path));
      return digest.hex();
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.catchError((_) {});
    return result;
  }
}
