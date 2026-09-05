import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/display_prefs.dart';
import '../../core/media_service.dart';
import '../../core/server_state.dart';
import '../../theme/app_theme.dart';
import 'app_kit.dart';
import 'app_toast.dart';
import 'gallery_groups.dart';
import 'gallery_view.dart';
import 'gallery_widgets.dart';

class SearchTab extends StatefulWidget {
  final GalleryShellHost? shell;
  const SearchTab({super.key, this.shell});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();
  final List<MediaItem> _items = [];
  bool _loading = false;
  int _total = 0;
  String? _nextCursor;
  String _query = '';
  MediaService? _service;

  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.watch<ServerState>();
    if (state.status == ConnectionStatus.connected && _service == null) {
      _service = MediaService(state);
    } else if (state.status != ConnectionStatus.connected) {
      _service = null;
    }
  }

  void _onScroll() {
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200 &&
        !_loading &&
        _nextCursor != null) {
      _loadMore();
    }
  }

  Future<void> _search(String q) async {
    final trimmed = q.trim();
    if (trimmed == _query) return;
    _query = trimmed;
    if (_query.isEmpty || _service == null) {
      setState(() {
        _items.clear();
        _total = 0;
        _nextCursor = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final prefs = context.read<DisplayPrefs>();
      final result = await _service!.query(
        size: 40,
        filter: _buildFilter(prefs),
        sort: _buildSort(prefs),
        withTotal: true,
      );
      if (!mounted) return;
      setState(() {
        _items.clear();
        _items.addAll(result.items);
        _total = result.total ?? result.items.length;
        _nextCursor = result.nextCursor;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, '搜索失败', kind: ToastKind.error);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _nextCursor == null || _service == null) return;
    _loading = true;
    try {
      final prefs = context.read<DisplayPrefs>();
      final result = await _service!.query(
        size: 40,
        cursor: _nextCursor,
        filter: _buildFilter(prefs),
        sort: _buildSort(prefs),
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _nextCursor = result.nextCursor;
        _loading = false;
      });
    } catch (_) {
      _loading = false;
    }
  }

  Map<String, dynamic> _buildFilter(DisplayPrefs prefs) {
    final conditions = <Map<String, dynamic>>[
      {'field': 'deleted_at', 'op': 'is_null'},
      {'field': 'filename', 'op': 'like', 'value': '%$_query%'},
    ];
    if (prefs.mediaFilter == MediaFilter.photosOnly) {
      conditions.add({'field': 'media_type', 'op': '=', 'value': 'image'});
    } else if (prefs.mediaFilter == MediaFilter.videosOnly) {
      conditions.add({'field': 'media_type', 'op': '=', 'value': 'video'});
    }
    return {'and': conditions};
  }

  List<Map<String, String>> _buildSort(DisplayPrefs prefs) {
    final field = switch (prefs.sortField) {
      SortField.takenAt => 'taken_at',
      SortField.createdAt => 'created_at',
      SortField.size => 'size',
      SortField.filename => 'filename',
    };
    final dir = prefs.sortOrder == SortOrder.asc ? 'asc' : 'desc';
    return [
      {'field': field, 'dir': dir},
    ];
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(id);
      }
    });
    _syncSelection();
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    _syncSelection();
  }

  void _syncSelection() {
    widget.shell?.updateSelection(
      sourceTab: 1,
      selecting: _selecting,
      selectedIds: _selected,
      allSelected: _items.isNotEmpty && _selected.length == _items.length,
      allFavorite: false,
      onToggleSelectAll: () {
        setState(() {
          if (_selected.length == _items.length) {
            _selected.clear();
          } else {
            _selected.addAll(_items.map((e) => e.id));
          }
        });
        _syncSelection();
      },
      onExitSelection: _exitSelection,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final prefs = context.watch<DisplayPrefs>();

    return Column(
      children: [
        // 搜索栏
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.outline, width: 0.5)),
          ),
          child: Row(
            children: [
              if (_selecting) ...[
                IconButton(
                  onPressed: _exitSelection,
                  icon: Icon(
                    Icons.close_rounded,
                    size: AppIconSize.lg,
                    color: c.onSurface,
                  ),
                ),
                Text(
                  '已选 ${_selected.length}',
                  style: TextStyle(
                    color: c.onSurface,
                    fontSize: AppType.sm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ] else ...[
                Icon(Icons.search, size: AppIconSize.lg, color: c.onMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _focusNode,
                    style: TextStyle(color: c.onSurface, fontSize: AppType.sm),
                    decoration: InputDecoration(
                      hintText: '搜索文件名…',
                      hintStyle: TextStyle(
                        color: c.onMuted,
                        fontSize: AppType.sm,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onSubmitted: _search,
                    textInputAction: TextInputAction.search,
                  ),
                ),
                if (_query.isNotEmpty)
                  IconButton(
                    onPressed: () {
                      _searchCtrl.clear();
                      _search('');
                    },
                    icon: Icon(
                      Icons.close,
                      size: AppIconSize.lg,
                      color: c.onMuted,
                    ),
                  ),
              ],
            ],
          ),
        ),
        // 结果
        Expanded(child: _buildResults(c, prefs)),
      ],
    );
  }

  Widget _buildResults(AppColors c, DisplayPrefs prefs) {
    if (_service == null) {
      return AppEmptyState(icon: Icons.cloud_off_outlined, message: '未连接到服务器');
    }
    if (_query.isEmpty) {
      return AppEmptyState(icon: Icons.search, message: '输入关键词搜索文件');
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: AppSpinner());
    }
    if (_items.isEmpty) {
      return AppEmptyState(icon: Icons.search_off, message: '未找到匹配的文件');
    }

    final groups = buildGroups(_items, prefs);
    return LayoutBuilder(
      builder: (ctx, box) {
        const gridPad = 16.0, crossGap = 14.0;
        final usable = box.maxWidth - gridPad * 2;
        final mediaCol =
            (usable - crossGap * (prefs.gridColumns - 1)) / prefs.gridColumns;
        final mediaLabel = labelExtent(prefs);
        final mediaRatio = mediaCol / (mediaCol + mediaLabel);

        return CustomScrollView(
          controller: _scrollCtrl,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '共 $_total 个结果',
                  style: TextStyle(color: c.onMuted, fontSize: AppType.xs),
                ),
              ),
            ),
            for (final group in groups) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    group.label,
                    style: TextStyle(
                      color: c.onSurface,
                      fontSize: AppType.sm,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: gridPad),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: prefs.gridColumns,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: crossGap,
                    childAspectRatio: mediaRatio,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => MediaThumb(
                      key: ValueKey(group.items[i].id),
                      item: group.items[i],
                      service: _service!,
                      selected: _selected.contains(group.items[i].id),
                      selecting: _selecting,
                      prefs: prefs,
                      onTap: () {
                        if (_selecting) {
                          _toggleSelect(group.items[i].id);
                        } else {
                          widget.shell?.openViewer(
                            items: _items,
                            index: _items.indexOf(group.items[i]),
                            service: _service!,
                            onDeleted: (id) => setState(() {
                              _items.removeWhere((m) => m.id == id);
                            }),
                          );
                        }
                      },
                      onLongPress: () {
                        if (!_selecting) setState(() => _selecting = true);
                        _toggleSelect(group.items[i].id);
                      },
                    ),
                    childCount: group.items.length,
                  ),
                ),
              ),
            ],
            if (_loading && _items.isNotEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: AppSpinner()),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 88)),
          ],
        );
      },
    );
  }
}
