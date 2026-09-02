import 'kv_store.dart';

/// Token 存储 (KvStore)：key = "token:host:port"
class AuthStore {
  static String _key(String host, int port) => 'token:$host:$port';

  static Future<String?> get(String host, int port) async {
    final v = await KvStore.instance.get(_key(host, port));
    if (v == null || v.isEmpty) return null;
    return v;
  }

  static Future<void> set(String host, int port, String token) async {
    await KvStore.instance.set(_key(host, port), token);
  }

  static Future<void> clear(String host, int port) async {
    await KvStore.instance.set(_key(host, port), '');
  }
}
