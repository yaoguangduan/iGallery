import 'package:intl/intl.dart';

/// 统一北京时间 (UTC+8) 显示 (C1)
/// 服务端已按 +08:00 存储，客户端按同一时区展示，避免设备时区差异导致的错位

const _beijing = Duration(hours: 8);

DateTime? parseServerTime(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

DateTime? toBeijing(DateTime? dt) {
  if (dt == null) return null;
  return dt.toUtc().add(_beijing);
}

String fmtDateTime(String? iso) {
  final dt = toBeijing(parseServerTime(iso));
  if (dt == null) return '';
  return DateFormat('yyyy-MM-dd HH:mm:ss').format(dt);
}

String fmtDateShort(String? iso) {
  final dt = toBeijing(parseServerTime(iso));
  if (dt == null) return '';
  return DateFormat('MM/dd HH:mm').format(dt);
}

/// 上传/客户端本地时间 → 服务端认识的北京时间 RFC3339
String toServerRfc3339(DateTime dt) {
  final beijing = dt.toUtc().add(_beijing);
  final base = beijing.toIso8601String();
  // 去掉 'Z' 或 offset，直接拼 +08:00
  final noZone = base.endsWith('Z') ? base.substring(0, base.length - 1) : base;
  return '$noZone+08:00';
}
