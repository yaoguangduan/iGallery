import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'server_state.dart';

class DiscoveryService with WidgetsBindingObserver {
  static final DiscoveryService instance = DiscoveryService._();
  DiscoveryService._();

  BonsoirDiscovery? _discovery;
  ServerState? _state;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  bool _started = false;

  void attach(ServerState state) {
    _state = state;
  }

  Future<void> start() async {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen((_) {
      // 网络切换 → 重启发现 + 重新探活所有服务器
      _restart();
      _state?.recheckAll();
    });
    await _restart();
  }

  Future<void> _restart() async {
    await _stopInternal();
    try {
      final discovery = BonsoirDiscovery(type: '_igallery._tcp');
      _discovery = discovery;
      await discovery.initialize();
      discovery.eventStream?.listen(_onEvent);
      await discovery.start();
      _started = true;
    } catch (e) {
      if (kDebugMode) debugPrint('discovery start failed: $e');
    }
  }

  Future<void> _stopInternal() async {
    try {
      await _discovery?.stop();
    } catch (_) {}
    _discovery = null;
    _started = false;
  }

  Future<void> stop() async {
    _connSub?.cancel();
    _connSub = null;
    WidgetsBinding.instance.removeObserver(this);
    await _stopInternal();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_started) {
          // ignore: unawaited_futures
          _restart();
        }
        _state?.recheckAll();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // 后台时释放 mDNS，避免手机耗电
        // ignore: unawaited_futures
        _stopInternal();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        final resolver = _discovery?.serviceResolver;
        if (resolver != null) event.service.resolve(resolver);
      case BonsoirDiscoveryServiceResolvedEvent():
        _handleResolved(event.service);
      case BonsoirDiscoveryServiceUpdatedEvent():
        _handleResolved(event.service);
      case BonsoirDiscoveryServiceLostEvent():
        final host = event.service.hostAddress;
        if (host != null) _state?.removeDiscovered(host, event.service.port);
      default:
        break;
    }
  }

  void _handleResolved(BonsoirService service) {
    final host = service.hostAddress;
    if (host == null || host.isEmpty) return;
    final state = _state;
    if (state == null) return;
    final discovered = ServerInfo(
      name: service.attributes['name'] ?? service.name,
      host: host,
      port: service.port,
      version: service.attributes['version'],
    );

    // 按名称去重：mDNS 的 name 就是服务端 device_name，IP 变了也能认出同一台。
    // 已保存的服务器不再当成"新发现"塞进发现列表，避免列表里出现重复条目。
    final known = state.findKnown(discovered);
    if (known == null) {
      state.addDiscovered(discovered);
    }

    final st = state.status;
    if (st == ConnectionStatus.disconnected || st == ConnectionStatus.unreachable) {
      // 未连、或上次连的已经够不着了，就自动连这台发现的。
      // connect() 内部按名称合并：已保存的同一台会更新地址、复用 token，
      // 不会产生第二条记录。
      // ignore: unawaited_futures
      state.connect(discovered);
    } else if (known != null) {
      // 此刻不连接（可能正连着别的），但把已保存条目的地址刷成刚发现的
      state.noteSeen(discovered);
    }
  }
}
