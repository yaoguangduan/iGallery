import 'package:flutter/foundation.dart';

import 'api.dart';
import 'auth_store.dart';

class ServerInfo {
  final String name;
  final String host;
  final int port;
  final String? version;

  ServerInfo({required this.name, required this.host, required this.port, this.version});

  String get baseUrl => 'http://$host:$port';
  String get displayAddr => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is ServerInfo && host == other.host && port == other.port;
  @override
  int get hashCode => Object.hash(host, port);
}

class ServerStats {
  final String name;
  final String version;
  final int fileCount;
  final int totalSize;

  ServerStats({required this.name, required this.version, required this.fileCount, required this.totalSize});

  factory ServerStats.fromJson(Map<String, dynamic> json) => ServerStats(
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '',
        fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
        totalSize: (json['total_size'] as num?)?.toInt() ?? 0,
      );
}

/// disconnected: 未连
/// connecting:   连接中
/// needAuth:     服务器要求 token 但客户端无/token 错，前端应弹配对框
/// connected:    正常
/// unreachable:  连不上（网络/服务器停机）
enum ConnectionStatus { disconnected, connecting, needAuth, connected, unreachable }

class ServerState extends ChangeNotifier {
  ServerInfo? _active;
  ServerStats? _stats;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  final List<ServerInfo> _discovered = [];
  final List<ServerInfo> _servers = [];
  final Set<ServerInfo> _reachable = {};
  final Set<ServerInfo> _needAuth = {};

  ServerInfo? get active => _active;
  ServerStats? get stats => _stats;
  ConnectionStatus get status => _status;
  List<ServerInfo> get discovered => List.unmodifiable(_discovered);
  List<ServerInfo> get servers => List.unmodifiable(_servers);
  String get baseUrl => _active?.baseUrl ?? '';

  bool isReachable(ServerInfo s) => _reachable.contains(s);
  bool needsAuth(ServerInfo s) => _needAuth.contains(s);

  void addDiscovered(ServerInfo info) {
    final idx = _discovered.indexWhere((s) => s == info);
    if (idx >= 0) { _discovered[idx] = info; } else { _discovered.add(info); }
    notifyListeners();
  }

  void removeDiscovered(String host, int port) {
    _discovered.removeWhere((s) => s.host == host && s.port == port);
    notifyListeners();
  }

  void addServer(ServerInfo info) {
    if (!_servers.contains(info)) _servers.add(info);
    notifyListeners();
  }

  /// 连接：走 /v1/auth 判断是否要 token；有存好的 token 就带
  Future<void> connect(ServerInfo info) async {
    if (!_servers.contains(info)) _servers.add(info);
    _active = info;
    _status = ConnectionStatus.connecting;
    _stats = null;
    apiConfig.baseUrl = info.baseUrl;
    apiConfig.token = null;
    notifyListeners();

    final token = await AuthStore.get(info.host, info.port);

    // /v1/auth 探测
    final auth = await Api.instance.authProbe(info.baseUrl, token: token);
    if (auth == null) {
      _setUnreachable(info);
      return;
    }
    final required = auth['required'] == true;
    final authorized = auth['authorized'] == true;

    if (required && !authorized) {
      apiConfig.token = null;
      _needAuth.add(info);
      _status = ConnectionStatus.needAuth;
      _stats = null;
      notifyListeners();
      return;
    }

    apiConfig.token = required ? token : null;

    final stats = await Api.instance.probe(info.baseUrl, token: apiConfig.token);
    if (stats == null) {
      _setUnreachable(info);
      return;
    }
    _reachable.add(info);
    _needAuth.remove(info);
    _status = ConnectionStatus.connected;
    _stats = ServerStats.fromJson(stats);
    notifyListeners();
  }

  /// 用户输入 token 后调用；返回是否配对成功
  Future<bool> submitToken(ServerInfo info, String token) async {
    final auth = await Api.instance.authProbe(info.baseUrl, token: token);
    if (auth == null) return false;
    final authorized = auth['authorized'] == true;
    if (!authorized) return false;

    await AuthStore.set(info.host, info.port, token);
    if (_active == info) {
      apiConfig.token = token;
      final stats = await Api.instance.probe(info.baseUrl, token: token);
      if (stats != null) {
        _reachable.add(info);
        _needAuth.remove(info);
        _status = ConnectionStatus.connected;
        _stats = ServerStats.fromJson(stats);
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  void disconnect() {
    _active = null;
    _stats = null;
    _status = ConnectionStatus.disconnected;
    apiConfig.baseUrl = null;
    apiConfig.token = null;
    notifyListeners();
  }

  void removeServer(ServerInfo info) {
    _servers.remove(info);
    _discovered.remove(info);
    _reachable.remove(info);
    _needAuth.remove(info);
    if (_active == info) disconnect();
    notifyListeners();
  }

  void updateStats(ServerStats stats) {
    _stats = stats;
    notifyListeners();
  }

  void _setUnreachable(ServerInfo info) {
    _reachable.remove(info);
    if (_active == info) {
      _status = ConnectionStatus.unreachable;
      _stats = null;
    }
    notifyListeners();
  }

  Future<void> recheckAll() async {
    for (final s in List<ServerInfo>.from(_servers)) {
      // 后台重新连（不阻塞）
      // ignore: unawaited_futures
      _quietCheck(s);
    }
  }

  Future<void> _quietCheck(ServerInfo info) async {
    final token = await AuthStore.get(info.host, info.port);
    final stats = await Api.instance.probe(info.baseUrl, token: token);
    if (stats != null) {
      _reachable.add(info);
      _needAuth.remove(info);
      if (_active == info) {
        _status = ConnectionStatus.connected;
        _stats = ServerStats.fromJson(stats);
      }
    } else {
      final auth = await Api.instance.authProbe(info.baseUrl);
      if (auth != null && auth['required'] == true) {
        _needAuth.add(info);
        if (_active == info) _status = ConnectionStatus.needAuth;
      } else {
        _setUnreachable(info);
      }
    }
    notifyListeners();
  }

  Future<void> tryLocalhost() async {
    final local = ServerInfo(name: 'localhost', host: '127.0.0.1', port: 9600);
    final stats = await Api.instance.probe(local.baseUrl);
    if (stats != null) {
      addServer(local);
      await connect(local);
      return;
    }
    // 也可能需要 auth
    final auth = await Api.instance.authProbe(local.baseUrl);
    if (auth != null && auth['required'] == true) {
      addServer(local);
      await connect(local);
    }
  }
}
