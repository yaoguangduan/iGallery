// gallery 里三块可独立的 widget：MediaThumb、FolderThumb、FolderPickerSheet
// 拆出以给 gallery_view.dart 瘦身 (M1)

import 'package:flutter/material.dart';

import '../../core/display_prefs.dart';
import '../../core/media_service.dart';
import '../../core/time_fmt.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'cached_thumb.dart';

/// 单个媒体缩略图（图片/视频）
/// 缩略图格子的标签区高度（图片下方那块）。
///
/// 网格用 `childAspectRatio` 定格子高度，而图片区是恒定正方形，
/// 所以 `格子高 = 列宽 + 标签高`。这个函数是那个"标签高"的唯一真相源 ——
/// 写死比例会在列宽变化或标签行数变化时溢出（RenderFlex overflowed）。
double labelExtent(DisplayPrefs prefs) {
  if (!prefs.hasLabel || prefs.labelPosition != LabelPosition.below) return 0;
  var lines = 0;
  if (prefs.showName) lines++;
  if (prefs.showTime) lines++;
  if (prefs.showSize) lines++;
  if (prefs.showDimensions) lines++;
  if (prefs.showCamera) lines++;
  if (lines == 0) return 0;
  // 首行是文件名(xs)，其余是次级信息(xxs)；1.5 是 Text 实际行高的保守上界
  // （Material 默认 1.4，中文字体 fallback 链可能更高；1.35 实测会溢出 2~3px）
  final first = AppType.xs * 1.5;
  final rest = (lines - 1) * AppType.xxs * 1.5;
  return first + rest + _kLabelVPad * 2;
}

/// 文件夹格子的标签高度：固定两行（名字 + 数量）
double get folderLabelExtent =>
    AppType.xs * 1.5 + 1 + AppType.xxs * 1.5 + _kLabelVPad * 2;

const double _kLabelVPad = 5;

class MediaThumb extends StatelessWidget {
  final MediaItem item;
  final MediaService service;
  final bool selected;
  final bool selecting;
  final DisplayPrefs prefs;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(Offset globalPosition)? onSecondaryTap;
  /// 选择态下点右上角圆圈切换选中（为空则圆圈不可点）。
  final VoidCallback? onToggleSelect;

  const MediaThumb({
    super.key,
    required this.item, required this.service,
    required this.selected, required this.selecting,
    required this.prefs, required this.onTap, required this.onLongPress,
    this.onSecondaryTap, this.onToggleSelect,
  });

  /// 窄于这个宽度就不画标签：字号调大后，3~5 行元信息会把
  /// 密集网格（5~6 列）里的 Expanded 挤成 0 高，缩略图直接看不见。
  /// YouTube 在密集布局下也是只留图不留元信息。
  static const double _labelMinTileWidth = 96;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) => _build(ctx, box.maxWidth));
  }

  Widget _build(BuildContext context, double tileWidth) {
    final c = context.colors;
    final showBelow = prefs.hasLabel &&
        prefs.labelPosition == LabelPosition.below &&
        tileWidth >= _labelMinTileWidth;
    final showOverlay = prefs.hasLabel &&
        prefs.labelPosition == LabelPosition.overlay &&
        tileWidth >= _labelMinTileWidth;
    final compact = tileWidth < _labelMinTileWidth;
    return QuickLongPress(
      onTap: onTap, onLongPress: onLongPress,
      onSecondaryTapDown: onSecondaryTap == null
          ? null
          : (d) => onSecondaryTap!(d.globalPosition),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 缩略图恒为正方形（服务端 resize_to_fill 出的就是 300×300）。
          // 不能用 Expanded —— 那样图片高度 = 格子高度减去标签占用，
          // 开了标签就变成竖长方形，横图被裁成中间一条，跟手机图库不一样。
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Stack(fit: StackFit.expand, children: [
            Container(color: c.surface2, child: CachedThumb(
              id: item.id,
              url: service.thumbUrl(item.id),
              headers: service.authHeaders,
              fit: BoxFit.cover,
              placeholder: Container(color: c.surface2),
              errorBuilder: (_) => Center(child: Icon(
                  item.isVideo ? Icons.videocam : Icons.broken_image,
                  color: c.onMuted, size: 28)),
            )),
            if (item.isVideo) ...[
              Center(child: Container(
                width: compact ? 24 : 34, height: compact ? 24 : 34,
                decoration: BoxDecoration(
                  color: c.scrimSoft, shape: BoxShape.circle,
                ),
                child: Icon(Icons.play_arrow,
                    size: compact ? 15 : 21, color: c.onScrim),
              )),
              if (item.duration != null && !compact)
                Positioned(right: 5, bottom: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.scrimMedium,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_fmtDuration(item.duration!),
                        style: TextStyle(color: c.onScrim, fontSize: AppType.xxs, fontWeight: FontWeight.w500)),
                  ),
                ),
            ],
            if (showOverlay)
              Positioned(left: 0, right: 0, bottom: 0, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                decoration: BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [c.scrimMedium, Colors.transparent],
                )),
                child: _label(c.onScrim, c.onScrim.withValues(alpha: 0.75)),
              )),
            if (!selecting && item.isFavorite)
              Positioned(right: 7, top: 7,
                  child: Icon(Icons.favorite, size: compact ? 12 : 15, color: c.onScrim)),
            if (selecting) Positioned(right: 0, top: 0, child: GestureDetector(
              // 圆圈自带命中区：点它=切换选中，而不是打开查看器（旧版圆圈是纯装饰）
              behavior: HitTestBehavior.opaque,
              onTap: onToggleSelect,
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Container(
                  width: compact ? 20 : 24, height: compact ? 20 : 24,
                  decoration: BoxDecoration(
                    color: selected ? c.brand : c.scrimSoft, shape: BoxShape.circle,
                    border: Border.all(color: c.onScrim, width: 1.5)),
                  child: selected
                      ? Icon(Icons.check, size: compact ? 13 : 16, color: c.onScrim)
                      : null,
                ),
              ),
            )),
          ]),
          ),
          ),
          if (showBelow) Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: _kLabelVPad),
              child: _label(c.onSurface, c.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtDuration(double secs) {
    final d = Duration(seconds: secs.round());
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  Widget _label(Color primary, Color secondary) {
    final parts = <Widget>[];
    final ts = TextStyle(color: secondary, fontSize: AppType.xxs);
    if (prefs.showName) {
      parts.add(Text(item.filename, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: primary, fontSize: AppType.xs, fontWeight: FontWeight.w500)));
    }
    if (prefs.showTime) {
      final text = fmtDateShort(item.displayDate);
      if (text.isNotEmpty) parts.add(Text(text, maxLines: 1, style: ts));
    }
    if (prefs.showSize) {
      final s = item.size;
      final text = s < 1024 * 1024
          ? '${(s / 1024).toStringAsFixed(0)} KB'
          : '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
      parts.add(Text(text, maxLines: 1, style: ts));
    }
    if (prefs.showDimensions && item.width != null && item.height != null) {
      parts.add(Text('${item.width}×${item.height}', maxLines: 1, style: ts));
    }
    if (prefs.showCamera && (item.exifMake != null || item.exifModel != null)) {
      parts.add(Text([item.exifMake, item.exifModel].whereType<String>().join(' '),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: ts));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: parts);
  }
}

/// 文件夹缩略图：亮色下用浅灰卡片 + 圆角，YouTube 风
class FolderThumb extends StatelessWidget {
  final FolderItem folder;
  final MediaService service;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const FolderThumb({
    super.key,
    required this.folder, required this.service,
    required this.onTap, required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 外层是文件夹形状(手绘,精确填满方框),内层嵌入 ~1/3 的封面缩略图。
          // 没有封面就只显示纯文件夹,风格统一。
          //
          // 不用 Icons.folder_rounded：那个字形在 24×24 网格里只占
          // x∈[2,22]、y∈[4,20],左右内缩 8%、上下内缩 17%,导致左边和
          // 下方文字对不齐、底部空一大截,靠平移/缩放都补不干净。
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (ctx, box) {
                final side = box.maxWidth;
                final coverSide = side * 0.4;
                return Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _FolderPainter(c.surface2)),
                    ),
                    if (folder.coverId != null)
                      // 嵌在文件夹主体中央(主体从 28% 高度起算)
                      Positioned(
                        left: (side - coverSide) / 2,
                        top: side * 0.28 + (side * 0.72 - coverSide) / 2,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.card * 0.5),
                          child: SizedBox(
                            width: coverSide, height: coverSide,
                            // 加密文件夹:同一张缩略图,客户端打强马赛克+锁,不走服务端模糊图
                            child: folder.hasPassword
                                ? LockedCover(
                                    coverId: folder.coverId!, service: service)
                                : Stack(fit: StackFit.expand, children: [
                                    CachedThumb(
                                      id: folder.coverId!,
                                      url: service.thumbUrl(folder.coverId!),
                                      headers: service.authHeaders,
                                      placeholder: Container(color: c.surface),
                                      errorBuilder: (_) => Container(color: c.surface),
                                    ),
                                    if (folder.coverIsVideo)
                                      Center(child: Icon(Icons.play_arrow,
                                          size: coverSide * 0.5, color: c.onScrim)),
                                  ]),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, _kLabelVPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.onSurface, fontSize: AppType.xs, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 1),
                  Text('${folder.itemCount} 项',
                      style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.xxs)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 文件夹形状：左上一个凸起的"标签",下面是主体,两者求并集。
/// 精确填满给定方框 —— 左边缘 x=0、底边缘 y=h,和下方文字左对齐、
/// 底部不留空。
class _FolderPainter extends CustomPainter {
  final Color color;
  const _FolderPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = Radius.circular(w * 0.07);
    const tabTop = 0.13;    // 标签顶(占高比)
    const bodyTop = 0.28;   // 主体顶
    const tabRight = 0.44;  // 标签右缘(占宽比)

    // 主体
    final body = Path()..addRRect(RRect.fromLTRBR(
        0, h * bodyTop, w, h, r));
    // 标签：底部多伸进主体一点,并集后接缝处不会有缺口
    final tab = Path()..addRRect(RRect.fromLTRBR(
        0, h * tabTop, w * tabRight, h * bodyTop + w * 0.14, r));

    canvas.drawPath(
      Path.combine(PathOperation.union, body, tab),
      Paint()..color = color..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_FolderPainter old) => old.color != color;
}

/// 加密文件夹封面：普通缩略图在客户端打「强力马赛克」+ 中央白锁。
/// 马赛克 = **解码期**真降采样到 8×8(cacheWidth/cacheHeight → ResizeImage)，
/// 再最近邻采样(FilterQuality.none)放大填满，得到真色块。
/// 注意不能用「塞进小 SizedBox + FittedBox 放大」的做法：那只是 canvas 变换，
/// 光栅化时会合并成一次 300×300 原图→屏幕尺寸的单次采样，内容依然清晰可辨。
/// 纯客户端效果，服务端不再生成/下发 _blur.jpg 模糊图。
/// 网格 FolderThumb 与列表 _FolderListTile 共用这一份，不写两遍。
class LockedCover extends StatelessWidget {
  final String coverId;
  final MediaService service;
  const LockedCover({super.key, required this.coverId, required this.service});

  /// 马赛克块数：8×8 在 60px 封面上每块 ~7.5px，够粗——看得出"是张图"但认不出内容
  static const int _mosaicPx = 8;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) {
        final short =
            box.maxWidth < box.maxHeight ? box.maxWidth : box.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            CachedThumb(
              id: coverId,
              url: service.thumbUrl(coverId),
              headers: service.authHeaders,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none,
              cacheWidth: _mosaicPx,
              cacheHeight: _mosaicPx,
            ),
            Center(
              child: Icon(
                Icons.lock_rounded,
                color: Colors.white,
                size: (short * 0.36).clamp(16.0, 26.0),
                shadows: const [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 移动到 ... 的文件夹选择器
class FolderPickerSheet extends StatefulWidget {
  final MediaService service;
  final String? currentFolderId;
  final String? excludeFolderId;

  const FolderPickerSheet({super.key, required this.service, this.currentFolderId, this.excludeFolderId});

  @override
  State<FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<FolderPickerSheet> {
  List<FolderItem> _folders = [];
  String? _browseFolderId;
  final List<({String id, String name})> _path = [];
  bool _loading = true;
  bool _loadError = false;
  int _loadSeq = 0; // 快速导航时丢弃过期响应，别让旧目录列表盖掉新目录

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() { _loading = true; _loadError = false; });
    List<FolderItem> list;
    var error = false;
    try {
      list = await widget.service.listFolders(parentId: _browseFolderId);
      final ex = widget.excludeFolderId;
      if (ex != null) list = list.where((f) => f.id != ex).toList();
    } catch (_) {
      error = true;
      list = [];
    }
    if (!mounted || seq != _loadSeq) return; // 过期结果丢弃
    setState(() {
      _folders = list;
      _loadError = error;
      _loading = false;
    });
  }

  void _enter(FolderItem folder) {
    _path.add((id: folder.id, name: folder.name));
    _browseFolderId = folder.id;
    _load();
  }

  void _goUp() {
    if (_path.isEmpty) return;
    _path.removeLast();
    _browseFolderId = _path.isEmpty ? null : _path.last.id;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(children: [
      const SheetHandle(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(children: [
          if (_path.isNotEmpty) ...[
            GestureDetector(
              onTap: _goUp,
              child: Icon(Icons.arrow_back, size: 20, color: c.brand),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(
            _path.isEmpty ? '移动到' : _path.map((e) => e.name).join(' / '),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _path.isEmpty ? c.onSurface : c.onMuted,
              fontSize: _path.isEmpty ? AppType.mdPlus : AppType.xs,
              fontWeight: _path.isEmpty ? FontWeight.w700 : FontWeight.w500,
            ),
          )),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: _loading
            ? const Center(child: AppSpinner())
            : _loadError
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.error_outline, color: c.error, size: AppIconSize.hero),
                  const SizedBox(height: 8),
                  Text('加载失败', style: TextStyle(color: c.onSurfaceVariant, fontSize: AppType.sm)),
                  const SizedBox(height: 12),
                  AppButton(label: '重试', primary: false, onTap: _load),
                ]),
              )
            : ListView(children: [
                for (final f in _folders)
                  ListTile(
                    visualDensity: const VisualDensity(vertical: -2),
                    leading: Icon(Icons.folder, size: 20, color: c.onSurfaceVariant),
                    title: Text(f.name, style: TextStyle(color: c.onSurface, fontSize: AppType.sm)),
                    trailing: Icon(Icons.chevron_right, size: 18, color: c.onMuted),
                    onTap: () => _enter(f),
                  ),
                if (_folders.isEmpty && !_loading)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(child: Text('无子文件夹', style: TextStyle(color: c.onMuted, fontSize: AppType.xs))),
                  ),
              ]),
      ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(context, null),
              style: OutlinedButton.styleFrom(
                foregroundColor: c.onSurfaceVariant,
                side: BorderSide(color: c.outline),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
              ),
              child: const Text('取消'),
            )),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(
              onPressed: () => Navigator.pop(context, _browseFolderId ?? ''),
              style: FilledButton.styleFrom(
                backgroundColor: c.brand,
                foregroundColor: c.onScrim,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
              ),
              child: Text(_browseFolderId == null ? '移到根目录' : '移到此处'),
            )),
          ]),
        ),
      ),
    ]);
  }
}
