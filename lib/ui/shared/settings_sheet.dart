import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../core/auth_store.dart';
import '../../core/discovery_service.dart';
import '../../core/disk_cache.dart';
import '../../core/display_prefs.dart';
import '../../core/platform.dart';
import '../../core/server_state.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';
import 'common.dart';
import 'upload_history_page.dart';

// ── 全局配置（左上头像点进去）──────────────────────────────

class ProfileContent extends StatefulWidget {
  final bool asPage;
  const ProfileContent({super.key, this.asPage = false});

  @override
  State<ProfileContent> createState() => _ProfileContentState();
}

class _ProfileContentState extends State<ProfileContent> {
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
        // 服务器列表
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 22, 8, 8),
          child: Row(children: [
            Text('服务器', style: TextStyle(color: c.onSurface, fontSize: AppType.sm, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.refresh, size: AppIconSize.md, color: c.onMuted),
              onPressed: () { DiscoveryService.instance.start(); state.recheckAll(); },
              visualDensity: VisualDensity.compact,
              tooltip: '刷新',
            ),
            IconButton(
              icon: Icon(Icons.add, size: AppIconSize.md, color: c.brand),
              onPressed: () => _showAddServerDialog(context, state),
              visualDensity: VisualDensity.compact,
              tooltip: '添加服务器',
            ),
          ]),
        ),

        if (state.servers.isNotEmpty)
          SettingsGroup(children: [
            for (final s in state.servers)
              SettingsTile(
                icon: s == state.active ? Icons.check_circle : Icons.circle_outlined,
                iconColor: _serverColor(c, state, s),
                label: s.name,
                value: s.displayAddr,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                      color: _serverColor(c, state, s),
                      shape: BoxShape.circle),
                  ),
                  if (state.needsAuth(s)) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(Icons.vpn_key_outlined, size: AppIconSize.sm, color: c.warn),
                      onPressed: () => _promptToken(context, state, s),
                      visualDensity: VisualDensity.compact,
                      tooltip: '输入 Token',
                    ),
                  ],
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.close, size: AppIconSize.sm, color: c.onMuted),
                    onPressed: () => state.removeServer(s),
                    visualDensity: VisualDensity.compact,
                    tooltip: '移除',
                  ),
                ]),
                onTap: () {
                  if (state.needsAuth(s)) {
                    _promptToken(context, state, s);
                    return;
                  }
                  if (s == state.active) {
                    state.disconnect();
                  } else {
                    state.connect(s);
                  }
                },
              ),
          ]),

        if (state.servers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('暂无服务器，点击 + 添加或等待发现',
                style: TextStyle(color: c.onMuted, fontSize: AppType.sm)),
          ),

        // 当前节点信息（仅文件数）
        if (state.stats != null) ...[
          const SectionHeader(title: '当前节点'),
          SettingsGroup(children: [
            SettingsTile(icon: Icons.photo_library_outlined, label: '文件数', value: '${state.stats!.fileCount}'),
            SettingsTile(icon: Icons.dns_outlined, label: '名称', value: state.stats!.name),
          ]),
        ],

        // 局域网发现
        if (state.discovered.where((s) => !state.servers.contains(s)).isNotEmpty) ...[
          const SectionHeader(title: '局域网发现'),
          SettingsGroup(children: [
            for (final s in state.discovered)
              if (!state.servers.contains(s))
                SettingsTile(
                  icon: Icons.wifi_tethering,
                  label: s.name,
                  value: s.displayAddr,
                  onTap: () => state.connect(s),
                ),
          ]),
        ],

        const SectionHeader(title: '关于'),
        SettingsGroup(children: [
          SettingsTile(
            icon: Icons.history,
            label: '上传历史',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const UploadHistoryPage()),
            ),
          ),
          const _CacheTile(),
          const SettingsTile(
            icon: Icons.info_outline,
            label: AppInfo.appName,
            value: 'v${AppInfo.version}',
          ),
        ]),
      ],
    );
  }

  void _showAddServerDialog(BuildContext context, ServerState state) {
    final c = context.colors;
    showDialog(context: context, builder: (ctx) {
      final ctrl = TextEditingController();
      return AlertDialog(
        title: Text('添加服务器', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl, autofocus: true,
          style: TextStyle(color: c.onSurface, fontSize: AppType.md),
          decoration: InputDecoration(
            hintText: '192.168.1.100:9600',
            hintStyle: TextStyle(color: c.onMuted, fontSize: AppType.md),
            filled: true, fillColor: c.surface2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.chip), borderSide: BorderSide.none),
          ),
          onSubmitted: (text) { _addServer(text, state); Navigator.pop(ctx); },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: c.onSurfaceVariant))),
          TextButton(onPressed: () { _addServer(ctrl.text, state); Navigator.pop(ctx); },
              child: Text('添加', style: TextStyle(color: c.brand, fontWeight: FontWeight.w600))),
        ],
      );
    });
  }

  void _addServer(String text, ServerState state) {
    text = text.trim();
    if (text.isEmpty) return;
    String host = text;
    int port = 9600;
    if (text.contains(':')) {
      final parts = text.split(':');
      host = parts[0];
      port = int.tryParse(parts[1]) ?? 9600;
    }
    final info = ServerInfo(name: host, host: host, port: port);
    state.connect(info);
  }

  Color _serverColor(AppColors c, ServerState state, ServerInfo s) {
    if (state.needsAuth(s)) return c.warn;
    if (state.isReachable(s)) return c.ok;
    return c.error;
  }

  Future<void> _promptToken(BuildContext context, ServerState state, ServerInfo info) async {
    final c = context.colors;
    final existing = await AuthStore.get(info.host, info.port);
    if (!context.mounted) return;
    final ctrl = TextEditingController(text: existing ?? '');
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('输入访问令牌', style: TextStyle(color: c.onSurface, fontSize: AppType.mdPlus, fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${info.name} · ${info.displayAddr}',
              style: TextStyle(color: c.onMuted, fontSize: AppType.xs)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl, autofocus: true, obscureText: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.md),
            decoration: InputDecoration(
              hintText: '服务器启动时的 --token 值',
              hintStyle: TextStyle(color: c.onMuted),
              filled: true, fillColor: c.surface2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.chip), borderSide: BorderSide.none),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: c.onSurfaceVariant))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text('连接', style: TextStyle(color: c.brand, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (token == null || token.isEmpty || !context.mounted) return;
    final ok = await state.submitToken(info, token);
    if (!context.mounted) return;
    if (ok) {
      showToast(context, '已连接到 ${info.name}', kind: ToastKind.success);
    } else {
      showToast(context, '令牌错误或服务不可达', kind: ToastKind.error);
    }
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
              label: '排序顺序', value: _sortOrderLabel(prefs.sortField, prefs.sortOrder),
              onTap: () { prefs.toggleSortOrder(); onChanged?.call(); }),
        ]),
        const SectionHeader(title: '筛选'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.straighten, label: '文件大小', value: _sizeFilterLabel(prefs),
              onTap: () => _pickSizeFilter(context, prefs)),
          SettingsTile(icon: Icons.date_range, label: '时间范围', value: _dateFilterLabel(prefs),
              onTap: () => _pickDateRange(context, prefs)),
        ]),
        const SectionHeader(title: '缩略图信息'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.text_fields, label: '文件名',
              trailing: _miniSwitch(prefs.showName, (v) => prefs.setShowName(v))),
          SettingsTile(icon: Icons.access_time, label: '拍摄时间',
              trailing: _miniSwitch(prefs.showTime, (v) => prefs.setShowTime(v))),
          SettingsTile(icon: Icons.straighten, label: '文件大小',
              trailing: _miniSwitch(prefs.showSize, (v) => prefs.setShowSize(v))),
          SettingsTile(icon: Icons.aspect_ratio, label: '分辨率',
              trailing: _miniSwitch(prefs.showDimensions, (v) => prefs.setShowDimensions(v))),
          SettingsTile(icon: Icons.camera_alt_outlined, label: '相机型号',
              trailing: _miniSwitch(prefs.showCamera, (v) => prefs.setShowCamera(v))),
          SettingsTile(icon: Icons.label_outline, label: '标签位置', value: _posLabel(prefs.labelPosition),
              onTap: () => _pickPosition(context, prefs)),
        ]),
        const SectionHeader(title: '布局'),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.grid_view, label: '每行数量', value: '${prefs.gridColumns} 列',
              onTap: () => _pickColumns(context, prefs)),
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

  void _pickPosition(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (LabelPosition.overlay, '图片内部底部'), (LabelPosition.below, '图片下方'), (LabelPosition.none, '不显示'),
  ], p.labelPosition, (v) => p.setLabelPosition(v));

  void _pickColumns(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    for (var i = 1; i <= 6; i++) (i, '$i 列'),
  ], p.gridColumns, (v) => p.setGridColumns(v));

  void _pickTransition(BuildContext ctx, DisplayPrefs p) => _showOptions(ctx, [
    (ViewerTransition.fade, '淡入淡出'), (ViewerTransition.scale, '缩放'),
    (ViewerTransition.none, '无动画'),
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
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
            colorScheme: ColorScheme.dark(primary: c.brand, surface: c.surface, onSurface: c.onSurface)),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400, maxHeight: 580),
            child: child!,
          ),
        ),
      ),
    );
    if (range != null) { p.setDateFrom(range.start); p.setDateTo(range.end); }
    else { p.setDateFrom(null); p.setDateTo(null); }
    onChanged?.call();
  }

  void _showOptions<T>(BuildContext ctx, List<(T, String)> options, T current, void Function(T) onPick) {
    final c = ctx.colors;

    final content = Column(mainAxisSize: MainAxisSize.min, children: [
      for (final (val, label) in options)
        ListTile(
          title: Text(label, style: TextStyle(color: c.onSurface, fontSize: AppType.md)),
          trailing: val == current ? Icon(Icons.check, color: c.brand, size: AppIconSize.lg) : null,
          onTap: () { onPick(val); Navigator.pop(ctx); },
        ),
    ]);

    if (isDesktop) {
      showDialog(context: ctx, builder: (ctx) => Dialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.dialog)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: content),
        ),
      ));
    } else {
      showModalBottomSheet(context: ctx, backgroundColor: c.bg,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
        builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SheetHandle(),
          content,
          const SizedBox(height: 8),
        ])),
      );
    }
  }

  static Widget _miniSwitch(bool value, ValueChanged<bool> onChanged) {
    return Transform.scale(scale: 0.75, child: Switch(value: value, onChanged: onChanged));
  }

  String _sortOrderLabel(SortField f, SortOrder o) => switch (f) {
    SortField.takenAt || SortField.createdAt => o == SortOrder.desc ? '最新在前' : '最早在前',
    SortField.size => o == SortOrder.desc ? '最大在前' : '最小在前',
    SortField.filename => o == SortOrder.desc ? 'Z → A' : 'A → Z',
  };
  String _sortFieldLabel(SortField f) => switch (f) { SortField.takenAt => '拍摄时间', SortField.createdAt => '上传时间', SortField.size => '文件大小', SortField.filename => '文件名' };
  String _posLabel(LabelPosition p) => switch (p) { LabelPosition.below => '图片下方', LabelPosition.overlay => '图片内部', LabelPosition.none => '不显示' };
  String _densityLabel(GridDensity d) => switch (d) { GridDensity.small => '小', GridDensity.medium => '中', GridDensity.large => '大' };
  String _transLabel(ViewerTransition t) => switch (t) { ViewerTransition.fade => '淡入淡出', ViewerTransition.scale => '缩放', ViewerTransition.none => '无动画' };
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

/// 缓存清理入口（About 分组里）
class _CacheTile extends StatefulWidget {
  const _CacheTile();
  @override
  State<_CacheTile> createState() => _CacheTileState();
}

class _CacheTileState extends State<_CacheTile> {
  CacheStats? _stats;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await DiskCache.instance.stats();
    if (mounted) setState(() => _stats = s);
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    await DiskCache.instance.clearAll();
    await _refresh();
    if (mounted) {
      setState(() => _clearing = false);
      showToast(context, '缓存已清理', kind: ToastKind.success);
    }
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final total = s == null ? '...' : _fmt(s.total);
    return SettingsTile(
      icon: Icons.cleaning_services_outlined,
      label: '本地缓存',
      value: total,
      onTap: _clearing ? null : _clear,
    );
  }
}
