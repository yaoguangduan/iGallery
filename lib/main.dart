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
import 'core/log_service.dart';
import 'core/server_state.dart';
import 'core/hash_sync.dart';
import 'core/upload_history.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      dev.log('Flutter error: ${details.exceptionAsString()}',
          error: details.exception, stackTrace: details.stack);
      LogService.instance.error('Flutter: ${details.exceptionAsString()}',
          error: details.exception, stack: details.stack);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      dev.log('Uncaught error: $error', error: error, stackTrace: stack);
      LogService.instance.error('Uncaught: $error', error: error, stack: stack);
      return true;
    };

    ErrorWidget.builder = (details) => _ErrorFallback(details: details);

    await KvStore.instance.init();
    await DiskCache.instance.init();
    await LogService.instance.init();
    // 上次进程被杀时遗留的 "进行中" 记录标成中断，
    // 否则用户会一直看到永远转圈的假记录
    await UploadHistory.markStalePending();
    await HashSync.instance.loadLocal();

    final displayPrefs = DisplayPrefs();
    await displayPrefs.load();

    final serverState = ServerState();
    DiscoveryService.instance.attach(serverState);
    unawaited(DiscoveryService.instance.start());
    // 恢复上次手动添加/连接过的服务器（落盘在 KvStore），再退回 localhost。
    // 不这样做的话，更新/重启 app 后手动加的服务器就全丢了。
    unawaited(serverState.bootstrap());

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
    LogService.instance.error('Zone: $error', error: error, stack: stack);
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
