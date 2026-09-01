import 'package:bonsoir/bonsoir.dart';

import 'server_state.dart';

class DiscoveryService {
  static final DiscoveryService instance = DiscoveryService._();
  DiscoveryService._();

  BonsoirDiscovery? _discovery;
  ServerState? _state;

  void attach(ServerState state) {
    _state = state;
  }

  Future<void> start() async {
    await stop();
    final discovery = BonsoirDiscovery(type: '_igallery._tcp');
    _discovery = discovery;
    await discovery.initialize();
    discovery.eventStream?.listen(_onEvent);
    await discovery.start();
  }

  Future<void> stop() async {
    await _discovery?.stop();
    _discovery = null;
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      // 发现只给出未解析的服务，需显式解析才能拿到地址和 TXT 属性。
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
    final info = ServerInfo(
      name: service.attributes['name'] ?? service.name,
      host: host,
      port: service.port,
      version: service.attributes['version'],
    );
    _state?.addDiscovered(info);
    if (_state?.status == ConnectionStatus.disconnected) {
      _state?.connect(info);
    }
  }
}
