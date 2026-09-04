import 'package:flutter/foundation.dart';
import 'kv_store.dart';

enum LabelPosition { none, overlay, below }

enum SortField { takenAt, createdAt, size, filename }

enum SortOrder { desc, asc }

enum MediaFilter { all, photosOnly, videosOnly, favoritesOnly }

enum GroupMode { day, month, year, none }

enum GridDensity { small, medium, large } // kept for settings migration

enum ViewerTransition { fade, scale, none }

class DisplayPrefs extends ChangeNotifier {
  bool _showName = true;
  bool _showTime = true;
  bool _showSize = true;
  bool _showDimensions = false;
  bool _showCamera = false;
  LabelPosition _labelPosition = LabelPosition.below;
  SortField _sortField = SortField.takenAt;
  SortOrder _sortOrder = SortOrder.desc;
  MediaFilter _mediaFilter = MediaFilter.all;
  int? _minSize;
  int? _maxSize;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  GroupMode _groupMode = GroupMode.day;
  GridDensity _gridDensity = GridDensity.medium;
  int _gridColumns = 4;
  ViewerTransition _viewerTransition = ViewerTransition.fade;

  // getters
  bool get showName => _showName;
  bool get showTime => _showTime;
  bool get showSize => _showSize;
  bool get showDimensions => _showDimensions;
  bool get showCamera => _showCamera;
  LabelPosition get labelPosition => _labelPosition;
  bool get hasLabel =>
      (_showName || _showTime || _showSize || _showDimensions || _showCamera) &&
      _labelPosition != LabelPosition.none;
  SortField get sortField => _sortField;
  SortOrder get sortOrder => _sortOrder;
  MediaFilter get mediaFilter => _mediaFilter;
  int? get minSize => _minSize;
  int? get maxSize => _maxSize;
  DateTime? get dateFrom => _dateFrom;
  DateTime? get dateTo => _dateTo;
  GroupMode get groupMode => _groupMode;
  GridDensity get gridDensity => _gridDensity;
  int get gridColumns => _gridColumns;
  ViewerTransition get viewerTransition => _viewerTransition;

  double get thumbMaxExtent => switch (_gridDensity) {
    GridDensity.small => 90,
    GridDensity.medium => 130,
    GridDensity.large => 200,
  };

  bool get hasActiveFilter =>
      _mediaFilter != MediaFilter.all ||
      _minSize != null ||
      _maxSize != null ||
      _dateFrom != null ||
      _dateTo != null;

  // ── 持久化 ──

  Future<void> load() async {
    final kv = await KvStore.instance.getAll();
    _showName = kv['showName'] != '0';
    _showTime = kv['showTime'] != '0';
    _showSize = kv['showSize'] != '0';
    _showDimensions = kv['showDimensions'] == '1';
    _showCamera = kv['showCamera'] == '1';
    _labelPosition =
        _enumFromStr(LabelPosition.values, kv['labelPosition']) ??
        LabelPosition.below;
    _sortField =
        _enumFromStr(SortField.values, kv['sortField']) ?? SortField.takenAt;
    _sortOrder =
        _enumFromStr(SortOrder.values, kv['sortOrder']) ?? SortOrder.desc;
    _mediaFilter =
        _enumFromStr(MediaFilter.values, kv['mediaFilter']) ?? MediaFilter.all;
    _minSize = kv['minSize'] != null ? int.tryParse(kv['minSize']!) : null;
    _maxSize = kv['maxSize'] != null ? int.tryParse(kv['maxSize']!) : null;
    _dateFrom = kv['dateFrom'] != null
        ? DateTime.tryParse(kv['dateFrom']!)
        : null;
    _dateTo = kv['dateTo'] != null ? DateTime.tryParse(kv['dateTo']!) : null;
    _groupMode =
        _enumFromStr(GroupMode.values, kv['groupMode']) ?? GroupMode.day;
    _gridDensity =
        _enumFromStr(GridDensity.values, kv['gridDensity']) ??
        GridDensity.medium;
    _gridColumns = int.tryParse(kv['gridColumns'] ?? '') ?? 4;
    _viewerTransition =
        _enumFromStr(ViewerTransition.values, kv['viewerTransition']) ??
        ViewerTransition.fade;
    notifyListeners();
  }

  T? _enumFromStr<T extends Enum>(List<T> values, String? s) {
    if (s == null) return null;
    for (final v in values) {
      if (v.name == s) return v;
    }
    return null;
  }

  void _save(String key, String value) => KvStore.instance.set(key, value);
  void _saveBool(String key, bool v) => _save(key, v ? '1' : '0');
  void _saveNullInt(String key, int? v) {
    if (v == null) {
      KvStore.instance.set(key, '');
    } else {
      _save(key, '$v');
    }
  }

  // setters (每个都持久化)
  void setShowName(bool v) {
    _showName = v;
    _saveBool('showName', v);
    notifyListeners();
  }

  void setShowTime(bool v) {
    _showTime = v;
    _saveBool('showTime', v);
    notifyListeners();
  }

  void setShowSize(bool v) {
    _showSize = v;
    _saveBool('showSize', v);
    notifyListeners();
  }

  void setShowDimensions(bool v) {
    _showDimensions = v;
    _saveBool('showDimensions', v);
    notifyListeners();
  }

  void setShowCamera(bool v) {
    _showCamera = v;
    _saveBool('showCamera', v);
    notifyListeners();
  }

  void setLabelPosition(LabelPosition v) {
    _labelPosition = v;
    _save('labelPosition', v.name);
    notifyListeners();
  }

  void setSort(SortField field, SortOrder order) {
    _sortField = field;
    _sortOrder = order;
    _save('sortField', field.name);
    _save('sortOrder', order.name);
    notifyListeners();
  }

  void setMediaFilter(MediaFilter v) {
    _mediaFilter = v;
    _save('mediaFilter', v.name);
    notifyListeners();
  }

  void setSizeRange(int? min, int? max) {
    _minSize = min;
    _maxSize = max;
    _saveNullInt('minSize', min);
    _saveNullInt('maxSize', max);
    notifyListeners();
  }

  void setDateRange(DateTime? from, DateTime? to) {
    _dateFrom = from;
    _dateTo = to;
    _save('dateFrom', from?.toIso8601String() ?? '');
    _save('dateTo', to?.toIso8601String() ?? '');
    notifyListeners();
  }

  void setGroupMode(GroupMode v) {
    _groupMode = v;
    _save('groupMode', v.name);
    notifyListeners();
  }

  void setGridDensity(GridDensity v) {
    _gridDensity = v;
    _save('gridDensity', v.name);
    notifyListeners();
  }

  void setGridColumns(int v) {
    _gridColumns = v.clamp(1, 6);
    _save('gridColumns', '$_gridColumns');
    notifyListeners();
  }

  void setViewerTransition(ViewerTransition v) {
    _viewerTransition = v;
    _save('viewerTransition', v.name);
    notifyListeners();
  }

  void clearFilters() {
    _mediaFilter = MediaFilter.all;
    _save('mediaFilter', 'all');
    _minSize = null;
    _saveNullInt('minSize', null);
    _maxSize = null;
    _saveNullInt('maxSize', null);
    _dateFrom = null;
    _save('dateFrom', '');
    _dateTo = null;
    _save('dateTo', '');
    notifyListeners();
  }
}
