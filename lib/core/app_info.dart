/// Build-time identity of the app.
///
/// [version] is stamped by tool/ship.sh's bump_version on every release build so
/// it stays in step with pubspec.yaml. It used to be a literal in the settings
/// sheet, which meant the About row showed whatever version happened to be true
/// when that line was written. Do not hand-edit.
abstract class AppInfo {
  static const String appName = 'iGallery';
  static const String version = '0.1.3';
}
