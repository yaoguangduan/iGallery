import 'package:flutter/foundation.dart';

enum LabelPosition { none, overlay, below }
enum SortField { takenAt, createdAt, size, filename }
enum SortOrder { desc, asc }
enum MediaFilter { all, photosOnly, videosOnly }
enum GroupMode { day, month, year, none }
enum GridDensity { small, medium, large }
enum ViewerTransition { fade, slide, scale, none }
enum CropSaveMode { ask, overwrite, saveAsNew }
enum CropTimeMode { keepOriginal, useCurrentTime }

class DisplayPrefs extends ChangeNotifier {
  // 缩略图标签
  bool _showName = false;
  bool _showTime = true;
  bool _showSize = false;
  bool _showDimensions = false;
  bool _showCamera = false;
  LabelPosition _labelPosition = LabelPosition.overlay;

  // 排序
  SortField _sortField = SortField.takenAt;
  SortOrder _sortOrder = SortOrder.desc;

  // 筛选
  MediaFilter _mediaFilter = MediaFilter.all;
  int? _minSize;
  int? _maxSize;
  DateTime? _dateFrom;
  DateTime? _dateTo;

  // 分组
  GroupMode _groupMode = GroupMode.day;

  // 网格
  GridDensity _gridDensity = GridDensity.medium;

  // 查看器
  ViewerTransition _viewerTransition = ViewerTransition.fade;
  CropSaveMode _cropSaveMode = CropSaveMode.ask;
  CropTimeMode _cropTimeMode = CropTimeMode.keepOriginal;

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
  ViewerTransition get viewerTransition => _viewerTransition;
  CropSaveMode get cropSaveMode => _cropSaveMode;
  CropTimeMode get cropTimeMode => _cropTimeMode;

  double get thumbMaxExtent => switch (_gridDensity) {
        GridDensity.small => 90,
        GridDensity.medium => 130,
        GridDensity.large => 200,
      };

  // setters
  void setShowName(bool v) { _showName = v; notifyListeners(); }
  void setShowTime(bool v) { _showTime = v; notifyListeners(); }
  void setShowSize(bool v) { _showSize = v; notifyListeners(); }
  void setShowDimensions(bool v) { _showDimensions = v; notifyListeners(); }
  void setShowCamera(bool v) { _showCamera = v; notifyListeners(); }
  void setLabelPosition(LabelPosition v) { _labelPosition = v; notifyListeners(); }
  void setSortField(SortField v) { _sortField = v; notifyListeners(); }
  void setSortOrder(SortOrder v) { _sortOrder = v; notifyListeners(); }
  void setMediaFilter(MediaFilter v) { _mediaFilter = v; notifyListeners(); }
  void setMinSize(int? v) { _minSize = v; notifyListeners(); }
  void setMaxSize(int? v) { _maxSize = v; notifyListeners(); }
  void setDateFrom(DateTime? v) { _dateFrom = v; notifyListeners(); }
  void setDateTo(DateTime? v) { _dateTo = v; notifyListeners(); }
  void setGroupMode(GroupMode v) { _groupMode = v; notifyListeners(); }
  void setGridDensity(GridDensity v) { _gridDensity = v; notifyListeners(); }
  void setViewerTransition(ViewerTransition v) { _viewerTransition = v; notifyListeners(); }
  void setCropSaveMode(CropSaveMode v) { _cropSaveMode = v; notifyListeners(); }
  void setCropTimeMode(CropTimeMode v) { _cropTimeMode = v; notifyListeners(); }

  void toggleSortOrder() {
    _sortOrder = _sortOrder == SortOrder.desc ? SortOrder.asc : SortOrder.desc;
    notifyListeners();
  }

  void clearFilters() {
    _mediaFilter = MediaFilter.all;
    _minSize = null;
    _maxSize = null;
    _dateFrom = null;
    _dateTo = null;
    notifyListeners();
  }

  bool get hasActiveFilter =>
      _mediaFilter != MediaFilter.all ||
      _minSize != null || _maxSize != null ||
      _dateFrom != null || _dateTo != null;
}
