import 'kv_store.dart';

/// Token 存储 (KvStore)。
///
/// 存两份索引：
///  - `token:host:port`  按地址，手动填的服务器、首次连接时用；
///  - `token:name:<设备名>` 按名称，服务器换 IP（DHCP）后仍能认出来。
/// 设备名 = 服务端的 device_name，mDNS 广播的 name 和 /v1/info 的 name 都是它，
/// 是最稳的身份标识。
class AuthStore {
  static String _addrKey(String host, int port) => 'token:$host:$port';
  static String _nameKey(String name) => 'token:name:${_norm(name)}';

  static String _norm(String name) => name.trim().toLowerCase();

  static Future<String?> get(String host, int port) async {
    final v = await KvStore.instance.get(_addrKey(host, port));
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// 先按地址找，再按设备名找（IP 变了也能命中）。
  static Future<String?> getForServer({
    required String host,
    required int port,
    String? name,
  }) async {
    final byAddr = await get(host, port);
    if (byAddr != null) return byAddr;
    if (name != null && name.trim().isNotEmpty) {
      final v = await KvStore.instance.get(_nameKey(name));
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  static Future<void> set(String host, int port, String token) async {
    await KvStore.instance.set(_addrKey(host, port), token);
  }

  /// 同时落到地址和名称两个索引上。
  static Future<void> setForServer({
    required String host,
    required int port,
    required String token,
    String? name,
  }) async {
    await set(host, port, token);
    if (name != null && name.trim().isNotEmpty) {
      await KvStore.instance.set(_nameKey(name), token);
    }
  }

  static Future<void> clear(String host, int port) async {
    await KvStore.instance.set(_addrKey(host, port), '');
  }
}
