import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/discovery_service.dart';
import '../../core/display_prefs.dart';
import '../../core/media_service.dart';
import '../../core/server_state.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'common.dart';

// ── 全局配置（左上头像点进去）──────────────────────────────

class ProfileContent extends StatefulWidget {
  final bool asPage;
  const ProfileContent({super.key, this.asPage = false});

  @override
  State<ProfileContent> createState() => _ProfileContentState();
}

class _ProfileContentState extends State<ProfileContent> {
  final _ipCtrl = TextEditingController();

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _connectManual() async {
    final text = _ipCtrl.text.trim();
    if (text.isEmpty) return;
    String host = text;
    int port = 9600;
    if (text.contains(':')) {
      final parts = text.split(':');
      host = parts[0];
      port = int.tryParse(parts[1]) ?? 9600;
    }
    final state = context.read<ServerState>();
    state.setConnecting();
    state.connect(ServerInfo(name: host, host: host, port: port));
    _fetchStats(state);
  }

  Future<void> _fetchStats(ServerState state) async {
    if (state.status != ConnectionStatus.connected) return;
    try {
      final service = MediaService(state);
      final stats = await service.fetchInfo();
      state.updateStats(stats);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<ServerState>();

    return ListView(
      padding: EdgeInsets.only(
        top: widget.asPage ? 0 : 8,
        bottom: MediaQuery.of(context).padding.bottom + 24,
      ),
      children: [
        // 服务器列表（所有已知节点，激活的高亮）
        const SectionHeader(title: '服务器'),
        if (state.servers.isNotEmpty)
          SettingsGroup(children: [
            for (final s in state.servers)
              SettingsTile(
                icon: s == state.active ? Icons.check_circle : Icons.circle_outlined,
                iconColor: s == state.active ? c.ok : null,
                label: s.name,
                value: s.displayAddr,
                trailing: IconButton(
                  icon: Icon(Icons.close, size: AppIconSize.sm, color: c.onMuted),
                  onPressed: () => state.removeServer(s),
                  visualDensity: VisualDensity.compact,
                  tooltip: '移除',
                ),
                onTap: s == state.active ? () => state.disconnect() : () {
                  state.connect(s);
                  _fetchStats(state);
                },
              ),
          ]),

        // 当前激活节点信息
        if (state.stats != null) ...[
          const SectionHeader(title: '当前节点'),
          SettingsGroup(children: [
            SettingsTile(icon: Icons.photo_library_outlined, label: '文件数', value: '${state.stats!.fileCount}'),
            SettingsTile(icon: Icons.storage_outlined, label: '存储用量', value: _fmtSize(state.stats!.totalSize)),
          ]),
        ],

        if (state.discovered.isNotEmpty) ...[
          const SectionHeader(title: '局域网发现'),
          SettingsGroup(children: [
            for (final s in state.discovered)
              if (!state.servers.contains(s))
                SettingsTile(
                  icon: Icons.wifi_tethering,
                  label: s.name,
                  value: s.displayAddr,
                  onTap: () { state.connect(s); _fetchStats(state); },
                ),
          ]),
        ],

        const SectionHeader(title: '手动连接'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipCtrl,
                  style: TextStyle(color: c.onSurface, fontSize: AppType.md),
                  decoration: InputDecoration(
                    hintText: '192.168.1.100',
                    hintStyle:
                        TextStyle(color: c.onMuted, fontSize: AppType.md),
                    filled: true,
                    fillColor: c.surface2,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _connectManual(),
                ),
              ),
              const SizedBox(width: 8),
              AppButton(label: '连接', onTap: _connectManual),
            ],
          ),
        ),

        const SectionHeader(title: '关于'),
        SettingsGroup(children: [
          const SettingsTile(
              icon: Icons.info_outline, label: 'iGallery', value: 'v0.1.0'),
          const SettingsTile(
              icon: Icons.folder_outlined, label: '存储', value: 'data/media/'),
        ]),
      ],
    );
  }

  Widget _dot(AppColors c, ConnectionStatus s) {
    final color = switch (s) {
      ConnectionStatus.connected => c.ok,
      ConnectionStatus.connecting => c.warn,
      ConnectionStatus.disconnected => c.error,
    };
    return Container(
      width: 8, height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  String _statusText(ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected => '已连接',
        ConnectionStatus.connecting => '连接中…',
        ConnectionStatus.disconnected => '未连接',
      };

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// 手机端全局配置整页
class MobileProfilePage extends StatelessWidget {
  const MobileProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        title: Text('设置',
            style: TextStyle(
                color: c.onSurface,
                fontSize: AppType.lg,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.arrow_back, size: AppIconSize.lg, color: c.onSurface),
        ),
      ),
      body: const SafeArea(child: ProfileContent(asPage: true)),
    );
  }
}

// ── 图片展示设置（共享内容，drawer 和 sheet 都用）──────────────

class DisplaySettingsContent extends StatelessWidget {
  final VoidCallback? onChanged;
  const DisplaySettingsContent({super.key, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<DisplayPrefs>();
    return ListView(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
      children: [
        const SectionHeader(title: '排序'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.sort, label: '排序方式', value: _sortFieldLabel(prefs.sortField),
              onTap: () => _pickSortField(context, prefs)),
          SettingsTile(
              icon: prefs.sortOrder == SortOrder.desc ? Icons.arrow_downward : Icons.arrow_upward,
              label: '排序顺序', value: prefs.sortOrder == SortOrder.desc ? '最新在前' : '最早在前',
              onTap: () { prefs.toggleSortOrder(); onChanged?.call(); }),
        ]),
        const SectionHeader(title: '筛选'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.filter_list, label: '媒体类型', value: _filterLabel(prefs.mediaFilter),
              onTap: () => _pickFilter(context, prefs)),
          SettingsTile(icon: Icons.straighten, label: '文件大小', value: _sizeFilterLabel(prefs),
              onTap: () => _pickSizeFilter(context, prefs)),
          SettingsTile(icon: Icons.date_range, label: '时间范围', value: _dateFilterLabel(prefs),
              onTap: () => _pickDateRange(context, prefs)),
        ]),
        const SectionHeader(title: '缩略图信息'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.text_fields, label: '文件名',
              trailing: Switch(value: prefs.showName, onChanged: (v) => prefs.setShowName(v))),
          SettingsTile(icon: Icons.access_time, label: '拍摄时间',
              trailing: Switch(value: prefs.showTime, onChanged: (v) => prefs.setShowTime(v))),
          SettingsTile(icon: Icons.straighten, label: '文件大小',
              trailing: Switch(value: prefs.showSize, onChanged: (v) => prefs.setShowSize(v))),
          SettingsTile(icon: Icons.aspect_ratio, label: '分辨率',
              trailing: Switch(value: prefs.showDimensions, onChanged: (v) => prefs.setShowDimensions(v))),
          SettingsTile(icon: Icons.camera_alt_outlined, label: '相机型号',
              trailing: Switch(value: prefs.showCamera, onChanged: (v) => prefs.setShowCamera(v))),
          SettingsTile(icon: Icons.label_outline, label: '标签位置', value: _posLabel(prefs.labelPosition),
              onTap: () => _pickPosition(context, prefs)),
        ]),
        const SectionHeader(title: '布局'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.grid_view, label: '网格大小', value: _densityLabel(prefs.gridDensity),
              onTap: () => _pickDensity(context, prefs)),
          SettingsTile(icon: Icons.calendar_view_day, label: '分组方式', value: _groupLabel(prefs.groupMode),
              onTap: () => _pickGroup(context, prefs)),
        ]),
        const SectionHeader(title: '查看器'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.animation, label: '过渡动画', value: _transLabel(prefs.viewerTransition),
              onTap: () => _pickTransition(context, prefs)),
        ]),
        const SectionHeader(title: '裁剪'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.save_alt, label: '保存方式', value: _cropSaveLabel(prefs.cropSaveMode),
              onTap: () => _pickCropSave(context, prefs)),
          SettingsTile(icon: Icons.access_time, label: '裁剪后时间', value: _cropTimeLabel(prefs.cropTimeMode),
              onTap: () => _pickCropTime(context, prefs)),
        ]),
      ],
    );
  }

  void _pickSortField(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (SortField.takenAt, '拍摄时间'), (SortField.createdAt, '上传时间'),
    (SortField.size, '文件大小'), (SortField.filename, '文件名'),
  ], p.sortField, (v) { p.setSortField(v); onChanged?.call(); });

  void _pickFilter(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (MediaFilter.all, '全部'), (MediaFilter.photosOnly, '仅图片'), (MediaFilter.videosOnly, '仅视频'),
  ], p.mediaFilter, (v) { p.setMediaFilter(v); onChanged?.call(); });

  void _pickPosition(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (LabelPosition.overlay, '图片内部底部'), (LabelPosition.below, '图片下方'), (LabelPosition.none, '不显示'),
  ], p.labelPosition, (v) => p.setLabelPosition(v));

  void _pickDensity(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (GridDensity.small, '小'), (GridDensity.medium, '中'), (GridDensity.large, '大'),
  ], p.gridDensity, (v) => p.setGridDensity(v));

  void _pickGroup(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (GroupMode.day, '按天'), (GroupMode.month, '按月'), (GroupMode.year, '按年'), (GroupMode.none, '不分组'),
  ], p.groupMode, (v) => p.setGroupMode(v));

  void _pickTransition(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (ViewerTransition.fade, '淡入淡出'), (ViewerTransition.scale, '缩放'),
    (ViewerTransition.slide, '上滑'), (ViewerTransition.none, '无动画'),
  ], p.viewerTransition, (v) => p.setViewerTransition(v));

  void _pickCropSave(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (CropSaveMode.ask, '每次询问'), (CropSaveMode.overwrite, '覆盖原图'), (CropSaveMode.saveAsNew, '另存为新图'),
  ], p.cropSaveMode, (v) => p.setCropSaveMode(v));

  void _pickCropTime(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (CropTimeMode.keepOriginal, '保持原始拍摄时间'), (CropTimeMode.useCurrentTime, '使用当前时间'),
  ], p.cropTimeMode, (v) => p.setCropTimeMode(v));

  void _pickSizeFilter(BuildContext ctx, DisplayPrefs p) => _showOptions<int?>(ctx, [
    (null, '不限'), (1024 * 100, '> 100 KB'), (1024 * 1024, '> 1 MB'),
    (1024 * 1024 * 5, '> 5 MB'), (1024 * 1024 * 10, '> 10 MB'),
  ], p.minSize, (v) { p.setMinSize(v); p.setMaxSize(null); onChanged?.call(); });

  Future<void> _pickDateRange(BuildContext ctx, DisplayPrefs p) async {
    final c = ctx.colors;
    final range = await showDateRangePicker(
      context: ctx, firstDate: DateTime(2000), lastDate: DateTime.now(),
      initialDateRange: p.dateFrom != null && p.dateTo != null ? DateTimeRange(start: p.dateFrom!, end: p.dateTo!) : null,
      builder: (ctx, child) => Theme(data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.dark(primary: c.brand, surface: c.surface, onSurface: c.onSurface)), child: child!),
    );
    if (range != null) { p.setDateFrom(range.start); p.setDateTo(range.end); }
    else { p.setDateFrom(null); p.setDateTo(null); }
    onChanged?.call();
  }

  void _showOptions<T>(BuildContext ctx, List<(T, String)> options, T current, void Function(T) onPick) {
    final c = ctx.colors;
    showModalBottomSheet(context: ctx, backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SheetHandle(),
        for (final (val, label) in options)
          ListTile(title: Text(label, style: TextStyle(color: c.onSurface, fontSize: AppType.md)),
            trailing: val == current ? Icon(Icons.check, color: c.brand, size: AppIconSize.lg) : null,
            onTap: () { onPick(val); Navigator.pop(ctx); }),
        const SizedBox(height: 8),
      ])));
  }

  String _sortFieldLabel(SortField f) => switch (f) { SortField.takenAt => '拍摄时间', SortField.createdAt => '上传时间', SortField.size => '文件大小', SortField.filename => '文件名' };
  String _filterLabel(MediaFilter f) => switch (f) { MediaFilter.all => '全部', MediaFilter.photosOnly => '仅图片', MediaFilter.videosOnly => '仅视频' };
  String _posLabel(LabelPosition p) => switch (p) { LabelPosition.below => '图片下方', LabelPosition.overlay => '图片内部', LabelPosition.none => '不显示' };
  String _densityLabel(GridDensity d) => switch (d) { GridDensity.small => '小', GridDensity.medium => '中', GridDensity.large => '大' };
  String _groupLabel(GroupMode g) => switch (g) { GroupMode.day => '按天', GroupMode.month => '按月', GroupMode.year => '按年', GroupMode.none => '不分组' };
  String _transLabel(ViewerTransition t) => switch (t) { ViewerTransition.fade => '淡入淡出', ViewerTransition.scale => '缩放', ViewerTransition.slide => '上滑', ViewerTransition.none => '无动画' };
  String _cropSaveLabel(CropSaveMode m) => switch (m) { CropSaveMode.ask => '每次询问', CropSaveMode.overwrite => '覆盖原图', CropSaveMode.saveAsNew => '另存为新图' };
  String _cropTimeLabel(CropTimeMode m) => switch (m) { CropTimeMode.keepOriginal => '保持原始时间', CropTimeMode.useCurrentTime => '使用当前时间' };
  String _sizeFilterLabel(DisplayPrefs p) { if (p.minSize == null) return '不限'; if (p.minSize! >= 1024 * 1024) return '> ${p.minSize! ~/ (1024 * 1024)} MB'; return '> ${p.minSize! ~/ 1024} KB'; }
  String _dateFilterLabel(DisplayPrefs p) { if (p.dateFrom == null || p.dateTo == null) return '不限'; final f = DateFormat('MM/dd'); return '${f.format(p.dateFrom!)} - ${f.format(p.dateTo!)}'; }
}

/// 手机端底部弹出 sheet 包装
class DisplaySettingsSheet extends StatelessWidget {
  final VoidCallback? onChanged;
  const DisplaySettingsSheet({super.key, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final prefs = context.watch<DisplayPrefs>();
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      decoration: BoxDecoration(color: c.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SheetHandle(),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          Text('显示设置', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (prefs.hasActiveFilter)
            TextButton(onPressed: () { prefs.clearFilters(); onChanged?.call(); },
                child: Text('重置', style: TextStyle(color: c.brand, fontSize: AppType.xs))),
        ])),
        Flexible(child: DisplaySettingsContent(onChanged: onChanged)),
      ]),
    );
  }
}
