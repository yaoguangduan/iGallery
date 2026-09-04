import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'auth_store.dart';
import 'kv_store.dart';

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

/// connect() 的结果，UI 据此给出明确反馈。
/// superseded = 期间用户又点了别的服务器，这次结果作废，不要提示。
enum ConnectResult { connected, needAuth, unreachable, superseded }

class ServerState extends ChangeNotifier {
  ServerState() {
    // token 中途失效（服务端换了 --token）时，把状态拉回 needAuth，
    // 用户才有机会重新配对；否则只会不停收到"未授权"toast。
    Api.instance.onUnauthorized = _onUnauthorized;
  }

  ServerInfo? _active;
  ServerStats? _stats;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  final List<ServerInfo> _discovered = [];
  final List<ServerInfo> _servers = [];
  final Set<ServerInfo> _reachable = {};
  final Set<ServerInfo> _needAuth = {};

  /// connect 防竞态：mDNS 自动连和用户手动点可能并发，
  /// 晚发起的必须赢，否则 _active 和 apiConfig 会指向不同的服务器。
  int _connectSeq = 0;

  // 持久化：手动添加/连过的服务器要跨重启保留，否则更新 app 后全没了
  static const String _serversKey = 'servers';
  static const String _lastServerKey = 'last_server';

  ServerInfo? get active => _active;
  ServerStats? get stats => _stats;
  ConnectionStatus get status => _status;
  List<ServerInfo> get discovered => List.unmodifiable(_discovered);
  List<ServerInfo> get servers => List.unmodifiable(_servers);
  String get baseUrl => _active?.baseUrl ?? '';

  bool isReachable(ServerInfo s) => _reachable.contains(s);
  bool needsAuth(ServerInfo s) => _needAuth.contains(s);
  /// 正在连接中（UI 显示转圈而不是直接标红）
  bool isConnecting(ServerInfo s) =>
      _active == s && _status == ConnectionStatus.connecting;

  /// 归一化服务器名，用来做"是不是同一台"的判断。
  /// 服务端对内外都用同一个 device_name（mDNS 的 name 属性 == /v1/info 的 name），
  /// 所以名称是最稳的身份：IP 变了、主机名和 IP 两种写法并存，都不影响。
  static String normName(String name) => name.trim().toLowerCase();

  /// 这台服务器是不是已经知道了（已保存 / 已连接）。
  /// 先按 host:port 精确匹配，再按服务器名匹配（认出一个换了 IP 的老朋友）。
  /// 返回已存在的那台，没有就返回 null。
  ServerInfo? findKnown(ServerInfo info) {
    for (final s in _servers) {
      if (s.host == info.host && s.port == info.port) return s;
    }
    final n = normName(info.name);
    if (n.isNotEmpty) {
      for (final s in _servers) {
        if (normName(s.name) == n) return s;
      }
    }
    return null;
  }

  void _onUnauthorized() {
    final info = _active;
    if (info == null) return;
    if (_status == ConnectionStatus.needAuth) return; // 已经在等输入了
    apiConfig.token = null;
    _reachable.remove(info);
    _needAuth.add(info);
    _status = ConnectionStatus.needAuth;
    _stats = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (Api.instance.onUnauthorized == _onUnauthorized) {
      Api.instance.onUnauthorized = null;
    }
    super.dispose();
  }

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
    _upsertServer(info);
    notifyListeners();
  }

  /// 把 info 并入已保存列表，返回合并后的那条记录。
  /// 按"名称 / host:port"认出同一台：地址就更新成现在要连的，
  /// 名称尽量保留旧的（它可能是连上后才知道的真设备名）。
  ServerInfo _upsertServer(ServerInfo info) {
    final known = findKnown(info);
    if (known == null) {
      _servers.add(info);
      _persistServers();
      return info;
    }
    final merged = ServerInfo(
      name: known.name.isNotEmpty ? known.name : info.name,
      host: info.host,
      port: info.port,
      version: info.version ?? known.version,
    );
    _replaceEntry(known, merged);
    _persistServers();
    return merged;
  }

  /// 在列表和各状态集合里把 old 换成 neu，保持引用一致
  void _replaceEntry(ServerInfo old, ServerInfo neu) {
    final i = _servers.indexOf(old);
    if (i >= 0) {
      _servers[i] = neu;
    } else {
      _servers.add(neu);
    }
    if (_reachable.remove(old)) _reachable.add(neu);
    if (_needAuth.remove(old)) _needAuth.add(neu);
    if (_active == old) _active = neu;
  }

  /// mDNS 又看到一台已保存的服务器（可能换了地址）：只把地址刷成最新的，
  /// 不发起连接。这样用户下次点它时连的是新地址。
  void noteSeen(ServerInfo info) {
    final known = findKnown(info);
    if (known == null) return;
    if (known.host == info.host && known.port == info.port) return;
    final merged = ServerInfo(
      name: known.name.isNotEmpty ? known.name : info.name,
      host: info.host,
      port: info.port,
      version: info.version ?? known.version,
    );
    _replaceEntry(known, merged);
    _persistServers();
    notifyListeners();
  }

  /// 连上后用服务端返回的设备名作为这条记录的正式名字，
  /// 并把重名的其它记录合并掉（那就是同一台）。返回最终那条记录。
  ServerInfo _adoptDeviceName(ServerInfo server, String deviceName) {
    final dn = deviceName.trim();
    if (dn.isEmpty) return server;

    // 重名的其它条目 = 同一台服务器，删掉，只留刚连上的这条
    final dupes = _servers
        .where((s) => s != server && normName(s.name) == normName(dn))
        .toList();
    for (final d in dupes) {
      _servers.remove(d);
      _reachable.remove(d);
      _needAuth.remove(d);
    }

    var result = server;
    if (normName(server.name) != normName(dn)) {
      final renamed = ServerInfo(
          name: dn, host: server.host, port: server.port, version: server.version);
      _replaceEntry(server, renamed);
      result = renamed;
    }
    _persistServers();
    return result;
  }

  /// 连接：走 /v1/auth 判断是否要 token；有存好的 token 就带。
  /// 返回结果供 UI 给用户明确反馈（成功 / 要令牌 / 连不上）。
  Future<ConnectResult> connect(ServerInfo info) async {
    final seq = ++_connectSeq;
    final server = _upsertServer(info);
    _active = server;
    _status = ConnectionStatus.connecting;
    _stats = null;
    apiConfig.baseUrl = server.baseUrl;
    apiConfig.token = null;
    notifyListeners();

    // token：先按地址，再按设备名（服务器换了 IP 也能认出来）
    final token = await AuthStore.getForServer(
        host: server.host, port: server.port, name: server.name);
    if (seq != _connectSeq) return ConnectResult.superseded;

    // /v1/auth 探测
    final auth = await Api.instance.authProbe(server.baseUrl, token: token);
    if (seq != _connectSeq) return ConnectResult.superseded;
    if (auth == null) {
      _setUnreachable(server);
      return ConnectResult.unreachable;
    }
    final required = auth['required'] == true;
    final authorized = auth['authorized'] == true;

    if (required && !authorized) {
      apiConfig.token = null;
      _needAuth.add(server);
      _status = ConnectionStatus.needAuth;
      _stats = null;
      notifyListeners();
      return ConnectResult.needAuth;
    }

    apiConfig.token = required ? token : null;

    final stats = await Api.instance.probe(server.baseUrl, token: apiConfig.token);
    if (seq != _connectSeq) return ConnectResult.superseded;
    if (stats == null) {
      _setUnreachable(server);
      return ConnectResult.unreachable;
    }
    _reachable.add(server);
    _needAuth.remove(server);
    _status = ConnectionStatus.connected;
    _stats = ServerStats.fromJson(stats);

    // 采纳服务端设备名并合并重名记录；若用了 token，也按名字存一份
    final current = _adoptDeviceName(server, _stats!.name);
    if (required && token != null && token.isNotEmpty) {
      await AuthStore.setForServer(
          host: current.host, port: current.port, token: token, name: current.name);
    }
    if (seq != _connectSeq) return ConnectResult.superseded;
    _rememberActive(current);
    notifyListeners();
    return ConnectResult.connected;
  }

  /// 用户输入 token 后调用；返回是否配对成功
  Future<bool> submitToken(ServerInfo info, String token) async {
    final auth = await Api.instance.authProbe(info.baseUrl, token: token);
    if (auth == null) return false;
    final authorized = auth['authorized'] == true;
    if (!authorized) return false;

    // token 同时存到"地址 + 设备名"两个索引上，换 IP 也能认出
    final server = findKnown(info) ?? info;
    await AuthStore.setForServer(
        host: server.host, port: server.port, token: token, name: server.name);

    if (_active != info && _active != server) {
      // 配对的不是当前服务器：token 存好了就算成功，
      // 用户点它的时候会用上（旧实现在这里返回 false，看着像"令牌错误"）
      _needAuth.remove(info);
      _needAuth.remove(server);
      notifyListeners();
      return true;
    }
    apiConfig.token = token;
    final stats = await Api.instance.probe(server.baseUrl, token: token);
    if (stats == null) return false;
    _reachable.add(server);
    _needAuth.remove(server);
    _needAuth.remove(info);
    _status = ConnectionStatus.connected;
    _stats = ServerStats.fromJson(stats);
    final current = _adoptDeviceName(server, _stats!.name);
    await AuthStore.setForServer(
        host: current.host, port: current.port, token: token, name: current.name);
    _rememberActive(current);
    notifyListeners();
    return true;
  }

  void disconnect() {
    _connectSeq++;   // 作废进行中的 connect，别让它把状态改回 connected
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
    _persistServers();
    // 删的正好是上次连的那台，就别让启动时再去连一个已被移除的服务器
    KvStore.instance.get(_lastServerKey).then((last) {
      if (last == null || last.trim().isEmpty) return;
      final k = last.trim();
      if (normName(info.name) == normName(k) || '${info.host}:${info.port}' == k) {
        KvStore.instance.set(_lastServerKey, '');
      }
    });
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
    final token = await AuthStore.getForServer(
        host: info.host, port: info.port, name: info.name);
    final stats = await Api.instance.probe(info.baseUrl, token: token);
    if (stats != null) {
      _reachable.add(info);
      _needAuth.remove(info);
      if (_active == info) {
        // 后台探活不能把"正在连接"改写成 connected —— connect() 还没走完
        // 鉴权分支，抢跑会让 apiConfig.token 还没设好就放行请求
        if (_status != ConnectionStatus.connecting) {
          _status = ConnectionStatus.connected;
          _stats = ServerStats.fromJson(stats);
        }
      }
    } else {
      final auth = await Api.instance.authProbe(info.baseUrl);
      if (auth != null && auth['required'] == true) {
        _needAuth.add(info);
        if (_active == info && _status != ConnectionStatus.connecting) {
          _status = ConnectionStatus.needAuth;
        }
      } else {
        _setUnreachable(info);
      }
    }
    notifyListeners();
  }

  Future<void> tryLocalhost() async {
    final local = ServerInfo(name: 'localhost', host: '127.0.0.1', port: 9600);
    // 已经连上别的服务器了就别抢（mDNS 可能已经先连上了）
    if (_status == ConnectionStatus.connected) return;
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

  // ── 持久化 ──

  void _persistServers() {
    final list = _servers
        .map((s) => {'name': s.name, 'host': s.host, 'port': s.port})
        .toList();
    KvStore.instance.set(_serversKey, jsonEncode(list));
  }

  /// 记住最后连上的服务器，下次启动优先恢复它。
  /// 存设备名（最稳，IP 变了不影响），名字空才退回地址。
  void _rememberActive(ServerInfo info) {
    final key =
        info.name.trim().isNotEmpty ? info.name.trim() : '${info.host}:${info.port}';
    KvStore.instance.set(_lastServerKey, key);
  }

  Future<void> _loadPersistedServers() async {
    final raw = await KvStore.instance.get(_serversKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      for (final e in list) {
        if (e is! Map) continue;
        final host = e['host'] as String? ?? '';
        final port = (e['port'] as num?)?.toInt() ?? 9600;
        final name = e['name'] as String? ?? '';
        if (host.isEmpty) continue;
        final info =
            ServerInfo(name: name.isEmpty ? host : name, host: host, port: port);
        // 按名称去重，防止历史数据里同一台设备留了好几条
        final exists = _servers.any((s) =>
            (s.host == info.host && s.port == info.port) ||
            (info.name.isNotEmpty && normName(s.name) == normName(info.name)));
        if (!exists) _servers.add(info);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('load persisted servers failed: $e');
    }
  }

  /// 启动入口：先恢复持久化的服务器列表，再按
  /// 「上次连过的 → 列表第一台 → localhost → 已发现的」顺序试着连上。
  /// 都不成也不报错，留给 mDNS 发现兜底。
  Future<void> bootstrap() async {
    await _loadPersistedServers();

    final lastKey = await KvStore.instance.get(_lastServerKey);
    ServerInfo? target;
    if (lastKey != null && lastKey.trim().isNotEmpty) {
      final k = lastKey.trim();
      // 先按设备名认（IP 换了也能找到），再退回按地址
      for (final s in _servers) {
        if (normName(s.name) == normName(k)) {
          target = s;
          break;
        }
      }
      if (target == null) {
        for (final s in _servers) {
          if ('${s.host}:${s.port}' == k) {
            target = s;
            break;
          }
        }
      }
    }
    if (target == null && _servers.isNotEmpty) target = _servers.first;

    if (target != null) {
      final result = await connect(target);
      if (result == ConnectResult.connected || result == ConnectResult.needAuth) {
        return;
      }
    }

    await tryLocalhost();

    // localhost 也不行：如果 mDNS 这会儿已经发现了谁，就近连一台
    if (_status != ConnectionStatus.connected &&
        _status != ConnectionStatus.needAuth &&
        _discovered.isNotEmpty) {
      await connect(_discovered.first);
    }
  }
}
