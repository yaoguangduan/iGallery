import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../core/auth_store.dart';
import '../../core/discovery_service.dart';
import '../../core/disk_cache.dart';
import '../../core/display_prefs.dart';
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
          child: Row(
            children: [
              Text(
                '服务器',
                style: TextStyle(
                  color: c.onSurface,
                  fontSize: AppType.sm,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  Icons.refresh,
                  size: AppIconSize.md,
                  color: c.onMuted,
                ),
                onPressed: () {
                  DiscoveryService.instance.start();
                  state.recheckAll();
                },
                visualDensity: VisualDensity.compact,
                tooltip: '刷新',
              ),
              IconButton(
                icon: Icon(Icons.add, size: AppIconSize.md, color: c.brand),
                onPressed: () => _showAddServerDialog(context, state),
                visualDensity: VisualDensity.compact,
                tooltip: '添加服务器',
              ),
            ],
          ),
        ),

        if (state.servers.isNotEmpty)
          SettingsGroup(
            children: [
              for (final s in state.servers)
                SettingsTile(
                  icon: s == state.active
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  iconColor: _serverColor(c, state, s),
                  label: s.name,
                  value: s.displayAddr,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _serverColor(c, state, s),
                          shape: BoxShape.circle,
                        ),
                      ),
                      if (state.needsAuth(s)) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(
                            Icons.vpn_key_outlined,
                            size: AppIconSize.sm,
                            color: c.warn,
                          ),
                          onPressed: () => _promptToken(context, state, s),
                          visualDensity: VisualDensity.compact,
                          tooltip: '输入 Token',
                        ),
                      ],
                      const SizedBox(width: 4),
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          size: AppIconSize.sm,
                          color: c.onMuted,
                        ),
                        onPressed: () => state.removeServer(s),
                        visualDensity: VisualDensity.compact,
                        tooltip: '移除',
                      ),
                    ],
                  ),
                  onTap: () {
                    if (state.needsAuth(s)) {
                      _promptToken(context, state, s);
                      return;
                    }
                    if (s == state.active) {
                      state.disconnect();
                    } else {
                      _connectWithFeedback(context, state, s);
                    }
                  },
                ),
            ],
          ),

        if (state.servers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              '暂无服务器，点击 + 添加或等待发现',
              style: TextStyle(color: c.onMuted, fontSize: AppType.sm),
            ),
          ),

        // 当前节点信息（仅文件数）
        if (state.stats != null) ...[
          const SectionHeader(title: '当前节点'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.photo_library_outlined,
                label: '文件数',
                value: '${state.stats!.fileCount}',
              ),
              SettingsTile(
                icon: Icons.dns_outlined,
                label: '名称',
                value: state.stats!.name,
              ),
            ],
          ),
        ],

        // 局域网发现。去重按名称（findKnown）：已经保存/连过的同一台，
        // 就算 IP 变了也不在这儿重复出现。
        if (state.discovered
            .where((s) => state.findKnown(s) == null)
            .isNotEmpty) ...[
          const SectionHeader(title: '局域网发现'),
          SettingsGroup(
            children: [
              for (final s in state.discovered)
                if (state.findKnown(s) == null)
                  SettingsTile(
                    icon: Icons.wifi_tethering,
                    label: s.name,
                    value: s.displayAddr,
                    onTap: () => _connectWithFeedback(context, state, s),
                  ),
            ],
          ),
        ],

        const SectionHeader(title: '关于'),
        SettingsGroup(
          children: [
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
          ],
        ),
      ],
    );
  }

  void _showAddServerDialog(BuildContext context, ServerState state) {
    final c = context.colors;
    showDialog(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: Text(
            '添加服务器',
            style: TextStyle(
              color: c.onSurface,
              fontSize: AppType.mdPlus,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: c.onSurface, fontSize: AppType.md),
            decoration: InputDecoration(
              hintText: '192.168.1.100:9600',
              hintStyle: TextStyle(color: c.onMuted, fontSize: AppType.md),
              filled: true,
              fillColor: c.surface2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.chip),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (text) {
              Navigator.pop(ctx);
              _addServer(context, text, state);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: c.onSurfaceVariant)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _addServer(context, ctrl.text, state);
              },
              child: Text(
                '添加',
                style: TextStyle(color: c.brand, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
  }

  void _addServer(BuildContext context, String text, ServerState state) {
    text = text.trim();
    if (text.isEmpty) {
      showToast(context, '请输入地址，如 192.168.1.100:9600', kind: ToastKind.info);
      return;
    }
    String host = text;
    int port = 9600;
    if (text.contains(':')) {
      final parts = text.split(':');
      host = parts[0];
      final parsed = int.tryParse(parts[1]);
      if (parsed == null || parsed < 1 || parsed > 65535) {
        showToast(context, '端口无效（1-65535）', kind: ToastKind.error);
        return;
      }
      port = parsed;
    }
    if (host.isEmpty) {
      showToast(context, '请输入主机地址', kind: ToastKind.error);
      return;
    }
    final info = ServerInfo(name: host, host: host, port: port);
    _connectWithFeedback(context, state, info);
  }

  /// 连接并给用户明确反馈。旧实现 connect() 后什么都不提示，
  /// 连不上就只有个红点，用户不知道发生了什么。
  Future<void> _connectWithFeedback(
    BuildContext context,
    ServerState state,
    ServerInfo info,
  ) async {
    final result = await state.connect(info);
    if (!context.mounted) return;
    switch (result) {
      case ConnectResult.connected:
        showToast(context, '已连接 ${info.name}', kind: ToastKind.success);
      case ConnectResult.needAuth:
        showToast(context, '${info.name} 需要访问令牌', kind: ToastKind.info);
      case ConnectResult.unreachable:
        showToast(context, '无法连接 ${info.displayAddr}', kind: ToastKind.error);
      case ConnectResult.superseded:
        break; // 用户已经切到别的服务器，这次的结果作废
    }
  }

  Color _serverColor(AppColors c, ServerState state, ServerInfo s) {
    // 连接中先显示中性色：此时还没到判"失败"的时候，直接标红会让人误以为坏了
    if (state.isConnecting(s)) return c.onMuted;
    if (state.needsAuth(s)) return c.warn;
    if (state.isReachable(s)) return c.ok;
    return c.error;
  }

  Future<void> _promptToken(
    BuildContext context,
    ServerState state,
    ServerInfo info,
  ) async {
    final c = context.colors;
    // 换了 IP 也能认出现有 token，别每次都让用户重输
    final existing = await AuthStore.getForServer(
      host: info.host,
      port: info.port,
      name: info.name,
    );
    if (!context.mounted) return;
    final ctrl = TextEditingController(text: existing ?? '');
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
          '输入访问令牌',
          style: TextStyle(
            color: c.onSurface,
            fontSize: AppType.mdPlus,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${info.name} · ${info.displayAddr}',
              style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              style: TextStyle(color: c.onSurface, fontSize: AppType.md),
              decoration: InputDecoration(
                hintText: '服务器启动时的 --token 值',
                hintStyle: TextStyle(color: c.onMuted),
                filled: true,
                fillColor: c.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: c.onSurfaceVariant)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(
              '连接',
              style: TextStyle(color: c.brand, fontWeight: FontWeight.w600),
            ),
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
        title: Text(
          '设置',
          style: TextStyle(
            color: c.onSurface,
            fontSize: AppType.lg,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(
            Icons.arrow_back,
            size: AppIconSize.lg,
            color: c.onSurface,
          ),
        ),
      ),
      body: const SafeArea(child: ProfileContent(asPage: true)),
    );
  }
}

// ── 相册排序 / 筛选 / 展示设置 ────────────────────────────────

class SortSettingsSheet extends StatelessWidget {
  final VoidCallback onChanged;
  const SortSettingsSheet({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<DisplayPrefs>();
    const options = <(SortField, SortOrder, String)>[
      (SortField.takenAt, SortOrder.desc, '拍摄时间 · 新到旧'),
      (SortField.takenAt, SortOrder.asc, '拍摄时间 · 旧到新'),
      (SortField.createdAt, SortOrder.desc, '上传时间 · 新到旧'),
      (SortField.createdAt, SortOrder.asc, '上传时间 · 旧到新'),
      (SortField.filename, SortOrder.asc, '名称 · A 到 Z'),
      (SortField.filename, SortOrder.desc, '名称 · Z 到 A'),
      (SortField.size, SortOrder.desc, '大小 · 大到小'),
      (SortField.size, SortOrder.asc, '大小 · 小到大'),
    ];
    return _SettingsSheetFrame(
      title: '排序',
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpace.lg),
        children: [
          SettingsGroup(
            children: [
              for (final (field, order, label) in options)
                _SheetOptionTile(
                  label: label,
                  selected:
                      prefs.sortField == field && prefs.sortOrder == order,
                  onTap: () {
                    prefs.setSort(field, order);
                    onChanged();
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class FilterSettingsSheet extends StatelessWidget {
  final VoidCallback onChanged;
  const FilterSettingsSheet({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<DisplayPrefs>();
    const typeOptions = <(MediaFilter, String)>[
      (MediaFilter.all, '全部'),
      (MediaFilter.photosOnly, '图片'),
      (MediaFilter.videosOnly, '视频'),
      (MediaFilter.favoritesOnly, '收藏'),
    ];
    const sizeOptions = <(int?, int?, String)>[
      (null, null, '不限'),
      (null, 1024 * 1024, '1 MB 以下'),
      (1024 * 1024, 10 * 1024 * 1024, '1 MB - 10 MB'),
      (10 * 1024 * 1024, 100 * 1024 * 1024, '10 MB - 100 MB'),
      (100 * 1024 * 1024, null, '100 MB 以上'),
    ];
    return _SettingsSheetFrame(
      title: '筛选',
      action: prefs.hasActiveFilter
          ? TextButton(
              onPressed: () {
                prefs.clearFilters();
                onChanged();
              },
              child: Text('清除', style: TextStyle(color: context.colors.brand)),
            )
          : null,
      child: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + AppSpace.lg,
        ),
        children: [
          const SectionHeader(title: '类型与范围'),
          SettingsGroup(
            children: [
              for (final (filter, label) in typeOptions)
                _SheetOptionTile(
                  label: label,
                  selected: prefs.mediaFilter == filter,
                  onTap: () {
                    prefs.setMediaFilter(filter);
                    onChanged();
                  },
                ),
            ],
          ),
          const SectionHeader(title: '时间'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.date_range_outlined,
                label: '拍摄日期',
                value: _dateFilterLabel(prefs),
                onTap: () => _pickDateRange(context, prefs, onChanged),
              ),
              if (prefs.dateFrom != null || prefs.dateTo != null)
                _SheetOptionTile(
                  label: '不限时间',
                  onTap: () {
                    prefs.setDateRange(null, null);
                    onChanged();
                  },
                ),
            ],
          ),
          const SectionHeader(title: '大小'),
          SettingsGroup(
            children: [
              for (final (min, max, label) in sizeOptions)
                _SheetOptionTile(
                  label: label,
                  selected: prefs.minSize == min && prefs.maxSize == max,
                  onTap: () {
                    prefs.setSizeRange(min, max);
                    onChanged();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class DisplaySettingsSheet extends StatelessWidget {
  const DisplaySettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<DisplayPrefs>();
    return _SettingsSheetFrame(
      title: '展示设置',
      child: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + AppSpace.lg,
        ),
        children: [
          const SectionHeader(title: '缩略图信息'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.text_fields,
                label: '文件名',
                trailing: _miniSwitch(prefs.showName, prefs.setShowName),
              ),
              SettingsTile(
                icon: Icons.access_time,
                label: '拍摄时间',
                trailing: _miniSwitch(prefs.showTime, prefs.setShowTime),
              ),
              SettingsTile(
                icon: Icons.straighten,
                label: '文件大小',
                trailing: _miniSwitch(prefs.showSize, prefs.setShowSize),
              ),
              SettingsTile(
                icon: Icons.aspect_ratio,
                label: '分辨率',
                trailing: _miniSwitch(
                  prefs.showDimensions,
                  prefs.setShowDimensions,
                ),
              ),
              SettingsTile(
                icon: Icons.camera_alt_outlined,
                label: '相机型号',
                trailing: _miniSwitch(prefs.showCamera, prefs.setShowCamera),
              ),
              SettingsTile(
                icon: Icons.label_outline,
                label: '标签位置',
                value: _positionLabel(prefs.labelPosition),
                onTap: () => _showOptions<LabelPosition>(
                  context,
                  const [
                    (LabelPosition.overlay, '图片内部底部'),
                    (LabelPosition.below, '图片下方'),
                    (LabelPosition.none, '不显示'),
                  ],
                  prefs.labelPosition,
                  prefs.setLabelPosition,
                ),
              ),
            ],
          ),
          const SectionHeader(title: '布局'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.grid_view_outlined,
                label: '每行数量',
                value: '${prefs.gridColumns} 列',
                onTap: () => _showOptions<int>(
                  context,
                  [
                    (1, '1 列'),
                    (2, '2 列'),
                    (3, '3 列'),
                    (4, '4 列'),
                    (5, '5 列'),
                    (6, '6 列'),
                  ],
                  prefs.gridColumns,
                  prefs.setGridColumns,
                ),
              ),
              SettingsTile(
                icon: Icons.calendar_view_month_outlined,
                label: '分组方式',
                value: _groupModeLabel(prefs.groupMode),
                onTap: () => _showOptions<GroupMode>(
                  context,
                  const [
                    (GroupMode.day, '按天'),
                    (GroupMode.month, '按月'),
                    (GroupMode.year, '按年'),
                    (GroupMode.none, '不分组'),
                  ],
                  prefs.groupMode,
                  prefs.setGroupMode,
                ),
              ),
            ],
          ),
          const SectionHeader(title: '查看器'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.animation_outlined,
                label: '过渡动画',
                value: _transitionLabel(prefs.viewerTransition),
                onTap: () => _showOptions<ViewerTransition>(
                  context,
                  const [
                    (ViewerTransition.fade, '淡入淡出'),
                    (ViewerTransition.scale, '缩放'),
                    (ViewerTransition.none, '无动画'),
                  ],
                  prefs.viewerTransition,
                  prefs.setViewerTransition,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsSheetFrame extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? action;

  const _SettingsSheetFrame({
    required this.title,
    required this.child,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.sheet),
            ),
          ),
          child: Column(
            children: [
              const SheetHandle(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: c.onSurface,
                        fontSize: AppType.mdPlus,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (action != null) action!,
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetOptionTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SheetOptionTile({
    required this.label,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      title: Text(
        label,
        style: TextStyle(
          color: selected ? c.brand : c.onSurface,
          fontSize: AppType.md,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check, color: c.brand, size: AppIconSize.lg)
          : null,
      onTap: onTap,
    );
  }
}

Future<void> _pickDateRange(
  BuildContext context,
  DisplayPrefs prefs,
  VoidCallback onChanged,
) async {
  final c = context.colors;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final initial = prefs.dateFrom != null && prefs.dateTo != null
      ? DateTimeRange(start: prefs.dateFrom!, end: prefs.dateTo!)
      : DateTimeRange(
          start: today.subtract(const Duration(days: 29)),
          end: today,
        );
  final range = await showDateRangePicker(
    context: context,
    firstDate: DateTime(1970),
    lastDate: today,
    initialDateRange: initial,
    initialEntryMode: DatePickerEntryMode.calendarOnly,
    helpText: '选择拍摄日期范围',
    saveText: '应用',
    builder: (ctx, child) {
      final base = Theme.of(ctx);
      return Theme(
        data: base.copyWith(
          colorScheme: base.colorScheme.copyWith(
            primary: c.brand,
            surface: c.surface,
            onSurface: c.onSurface,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
            child: child!,
          ),
        ),
      );
    },
  );
  if (range == null) return;
  prefs.setDateRange(range.start, range.end);
  onChanged();
}

void _showOptions<T>(
  BuildContext context,
  List<(T, String)> options,
  T current,
  ValueChanged<T> onPick,
) {
  final c = context.colors;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(),
          for (final (value, label) in options)
            _SheetOptionTile(
              label: label,
              selected: value == current,
              onTap: () {
                onPick(value);
                Navigator.pop(sheetContext);
              },
            ),
          const SizedBox(height: AppSpace.sm),
        ],
      ),
    ),
  );
}

Widget _miniSwitch(bool value, ValueChanged<bool> onChanged) {
  return Transform.scale(
    scale: 0.75,
    child: Switch(value: value, onChanged: onChanged),
  );
}

String _positionLabel(LabelPosition value) => switch (value) {
  LabelPosition.below => '图片下方',
  LabelPosition.overlay => '图片内部',
  LabelPosition.none => '不显示',
};

String _groupModeLabel(GroupMode value) => switch (value) {
  GroupMode.day => '按天',
  GroupMode.month => '按月',
  GroupMode.year => '按年',
  GroupMode.none => '不分组',
};

String _transitionLabel(ViewerTransition value) => switch (value) {
  ViewerTransition.fade => '淡入淡出',
  ViewerTransition.scale => '缩放',
  ViewerTransition.none => '无动画',
};

String _dateFilterLabel(DisplayPrefs prefs) {
  if (prefs.dateFrom == null || prefs.dateTo == null) return '不限';
  final format = DateFormat('yyyy/MM/dd');
  return '${format.format(prefs.dateFrom!)} - ${format.format(prefs.dateTo!)}';
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
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
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
