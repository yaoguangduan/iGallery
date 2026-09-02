import 'dart:async';
import 'dart:developer' as dev;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/discovery_service.dart';
import 'core/disk_cache.dart';
import 'core/display_prefs.dart';
import 'core/kv_store.dart';
import 'core/server_state.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      dev.log('Flutter error: ${details.exceptionAsString()}',
          error: details.exception, stackTrace: details.stack);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      dev.log('Uncaught error: $error', error: error, stackTrace: stack);
      return true;
    };

    ErrorWidget.builder = (details) => _ErrorFallback(details: details);

    await KvStore.instance.init();
    await DiskCache.instance.init();

    final displayPrefs = DisplayPrefs();
    await displayPrefs.load();

    final serverState = ServerState();
    DiscoveryService.instance.attach(serverState);
    unawaited(DiscoveryService.instance.start());
    unawaited(serverState.tryLocalhost());

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: serverState),
          ChangeNotifierProvider.value(value: displayPrefs),
        ],
        child: const IGalleryApp(),
      ),
    );
  }, (error, stack) {
    dev.log('Zone error: $error', error: error, stackTrace: stack);
  });
}

class _ErrorFallback extends StatelessWidget {
  final FlutterErrorDetails details;
  const _ErrorFallback({required this.details});

  @override
  Widget build(BuildContext context) {
    const c = AppColors.light;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: c.bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: c.error, size: AppIconSize.hero),
            const SizedBox(height: 12),
            Text(
              '出了点问题',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.onSurface, fontSize: AppType.base),
            ),
            const SizedBox(height: 8),
            Text(
              details.exceptionAsString(),
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xs),
            ),
          ],
        ),
      ),
    );
  }
}
