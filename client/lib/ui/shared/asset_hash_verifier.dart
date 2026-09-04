import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/hash_sync.dart';
import '../../theme/app_theme.dart';

class AssetHashVerifier {
  final void Function(String assetId, String checksum) onResolved;

  final ListQueue<({AssetEntity asset, int generation})> _queue = ListQueue();
  int _generation = 0;
  bool _working = false;
  bool _disposed = false;

  AssetHashVerifier({required this.onResolved});

  void stop() {
    _generation++;
    _queue.clear();
  }

  void verify(Iterable<AssetEntity> assets) {
    if (_disposed) return;
    final generation = ++_generation;
    _queue.clear();
    final ids = <String>{};
    for (final asset in assets) {
      if (ids.add(asset.id)) {
        _queue.add((asset: asset, generation: generation));
      }
    }
    _drain();
  }

  void dispose() {
    _disposed = true;
    stop();
  }

  Future<void> _drain() async {
    if (_working || _disposed) return;
    _working = true;
    try {
      if (!HashSync.instance.synced) {
        await HashSync.instance.syncFromServer();
      }
      while (!_disposed && _queue.isNotEmpty) {
        final task = _queue.removeFirst();
        if (task.generation != _generation) continue;
        final asset = task.asset;
        final fingerprint = assetFingerprint(asset);

        try {
          var checksum = await HashSync.instance.assetChecksum(
            asset.id,
            fingerprint,
          );
          if (task.generation != _generation || _disposed) continue;

          if (checksum == null) {
            final file = await asset.file;
            if (file == null || task.generation != _generation || _disposed) {
              continue;
            }
            checksum = await HashSync.computeFileHash(file);
            await HashSync.instance.cacheAssetChecksum(
              asset.id,
              fingerprint,
              checksum,
            );
          }

          if (task.generation == _generation && !_disposed) {
            onResolved(asset.id, checksum);
          }
        } catch (_) {
          // 单个资源失败不阻断后续队列；下次滚动停止后可再次尝试。
        }
      }
    } finally {
      _working = false;
      if (!_disposed && _queue.isNotEmpty) _drain();
    }
  }
}

String assetFingerprint(AssetEntity asset) =>
    '${asset.modifiedDateSecond ?? 0}:${asset.width}:${asset.height}:'
    '${asset.duration}:${asset.typeInt}';

List<AssetEntity> visibleGridAssets({
  required List<AssetEntity> assets,
  required ScrollController controller,
  required double width,
  int columns = 4,
  double gap = 2,
  double padding = 2,
}) {
  if (assets.isEmpty || !controller.hasClients || width <= 0) {
    return const [];
  }
  final tileWidth = (width - padding * 2 - gap * (columns - 1)) / columns;
  final rowExtent = tileWidth + gap;
  final position = controller.position;
  final firstRow = (position.pixels / rowExtent).floor() - 1;
  final lastRow =
      ((position.pixels + position.viewportDimension) / rowExtent).ceil() + 1;
  final first = (firstRow.clamp(0, 1 << 30) * columns).clamp(0, assets.length);
  final end = ((lastRow + 1).clamp(0, 1 << 30) * columns).clamp(
    first,
    assets.length,
  );
  return assets.sublist(first, end);
}

class UploadedBadge extends StatelessWidget {
  const UploadedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: c.scrimStrong,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_done_rounded, size: 14, color: c.onScrim),
          const SizedBox(width: 2),
          Text(
            '已传',
            style: TextStyle(
              color: c.onScrim,
              fontSize: AppType.xxs,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
