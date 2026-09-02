// 相册按日期 / 首字母 / 大小分组的纯函数
// 独立成文件避免 gallery_view.dart 越滚越大 (M1)

import 'package:lpinyin/lpinyin.dart';

import '../../core/display_prefs.dart';
import '../../core/media_service.dart';
import '../../core/time_fmt.dart';

class GalleryGroup {
  final String label;
  final List<MediaItem> items;
  GalleryGroup(this.label, this.items);
}

List<GalleryGroup> buildGroups(List<MediaItem> items, DisplayPrefs prefs) {
  if (prefs.groupMode == GroupMode.none) return [GalleryGroup('', items)];
  switch (prefs.sortField) {
    case SortField.filename:
      return _groupByLetter(items);
    case SortField.size:
      return _groupBySize(items);
    case SortField.takenAt:
    case SortField.createdAt:
      return _groupByDate(items, prefs);
  }
}

List<GalleryGroup> _groupByDate(List<MediaItem> items, DisplayPrefs prefs) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final map = <String, List<MediaItem>>{};
  for (final item in items) {
    final date = toBeijing(parseServerTime(item.displayDate));
    String label;
    if (date == null) { label = '未知日期'; }
    else {
      final d = DateTime(date.year, date.month, date.day);
      switch (prefs.groupMode) {
        case GroupMode.day:
          if (d == today) { label = '今天'; }
          else if (d == yesterday) { label = '昨天'; }
          else if (d.year == now.year) { label = '${d.month}月${d.day}日'; }
          else { label = '${d.year}年${d.month}月${d.day}日'; }
        case GroupMode.month:
          label = d.year == now.year ? '${d.month}月' : '${d.year}年${d.month}月';
        case GroupMode.year:
          label = '${d.year}年';
        case GroupMode.none:
          label = '';
      }
    }
    map.putIfAbsent(label, () => []).add(item);
  }
  return map.entries.map((e) => GalleryGroup(e.key, e.value)).toList();
}

List<GalleryGroup> _groupByLetter(List<MediaItem> items) {
  final map = <String, List<MediaItem>>{};
  for (final item in items) {
    final label = _initialLetter(item.filename);
    map.putIfAbsent(label, () => []).add(item);
  }
  return map.entries.map((e) => GalleryGroup(e.key, e.value)).toList();
}

String _initialLetter(String name) {
  if (name.isEmpty) return '#';
  final c = name.codeUnitAt(0);
  if (c >= 65 && c <= 90) return name[0];
  if (c >= 97 && c <= 122) return name[0].toUpperCase();
  if (c >= 0x4E00 && c <= 0x9FFF) {
    final py = PinyinHelper.getFirstWordPinyin(name[0]);
    if (py.isNotEmpty) return py[0].toUpperCase();
  }
  return '#';
}

List<GalleryGroup> _groupBySize(List<MediaItem> items) {
  final map = <String, List<MediaItem>>{};
  for (final item in items) {
    final label = _sizeLabel(item.size);
    map.putIfAbsent(label, () => []).add(item);
  }
  return map.entries.map((e) => GalleryGroup(e.key, e.value)).toList();
}

String _sizeLabel(int bytes) {
  if (bytes < 100 * 1024) return '< 100 KB';
  if (bytes < 1024 * 1024) return '100 KB - 1 MB';
  if (bytes < 5 * 1024 * 1024) return '1 - 5 MB';
  if (bytes < 20 * 1024 * 1024) return '5 - 20 MB';
  if (bytes < 100 * 1024 * 1024) return '20 - 100 MB';
  return '> 100 MB';
}
