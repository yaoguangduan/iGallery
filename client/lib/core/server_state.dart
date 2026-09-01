import 'package:flutter/foundation.dart';

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
        fileCount: json['file_count'] as int? ?? 0,
        totalSize: json['total_size'] as int? ?? 0,
      );
}

enum ConnectionStatus { disconnected, connecting, connected }

class ServerState extends ChangeNotifier {
  ServerInfo? _active;
  ServerStats? _stats;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  final List<ServerInfo> _discovered = [];
  final List<ServerInfo> _servers = [];

  ServerInfo? get active => _active;
  ServerStats? get stats => _stats;
  ConnectionStatus get status => _status;
  List<ServerInfo> get discovered => List.unmodifiable(_discovered);
  List<ServerInfo> get servers => List.unmodifiable(_servers);
  String get baseUrl => _active?.baseUrl ?? '';

  void addDiscovered(ServerInfo info) {
    final idx = _discovered.indexWhere((s) => s == info);
    if (idx >= 0) { _discovered[idx] = info; } else { _discovered.add(info); }
    _ensureInServers(info);
    notifyListeners();
  }

  void removeDiscovered(String host, int port) {
    _discovered.removeWhere((s) => s.host == host && s.port == port);
    notifyListeners();
  }

  void addServer(ServerInfo info) {
    _ensureInServers(info);
    notifyListeners();
  }

  void _ensureInServers(ServerInfo info) {
    if (!_servers.contains(info)) _servers.add(info);
  }

  void connect(ServerInfo info) {
    _ensureInServers(info);
    _active = info;
    _status = ConnectionStatus.connected;
    _stats = null;
    notifyListeners();
  }

  void disconnect() {
    _active = null;
    _stats = null;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  void removeServer(ServerInfo info) {
    _servers.remove(info);
    _discovered.remove(info);
    if (_active == info) disconnect();
    notifyListeners();
  }

  void updateStats(ServerStats stats) {
    _stats = stats;
    notifyListeners();
  }

  void setConnecting() {
    _status = ConnectionStatus.connecting;
    notifyListeners();
  }

  void tryDefaultLocalhost() {
    final local = ServerInfo(name: 'localhost', host: '127.0.0.1', port: 9600);
    _ensureInServers(local);
    if (_active == null) {
      _active = local;
      _status = ConnectionStatus.connecting;
    }
    notifyListeners();
  }
}
