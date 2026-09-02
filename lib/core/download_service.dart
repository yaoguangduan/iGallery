import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'media_service.dart';
import 'platform.dart';

/// 统一下载：先弹"另存为/选择目录"对话框选路径，再下载。
/// 桌面端用系统保存对话框；移动端退到应用文档目录下的 iGallery 文件夹。
class DownloadService {
  static final DownloadService instance = DownloadService._();
  DownloadService._();

  /// 移动端兜底保存目录
  Future<Directory> _mobileDir() async {
    Directory base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } else {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory('${base.path}/iGallery');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 单文件：弹保存对话框，返回保存路径；取消返回 null
  Future<String?> pickSavePath(String suggestedName) async {
    if (isDesktop) {
      return FilePicker.platform.saveFile(
        dialogTitle: '保存文件',
        fileName: suggestedName,
        lockParentWindow: true,
      );
    }
    final dir = await _mobileDir();
    return '${dir.path}/$suggestedName';
  }

  /// 多选/打包：弹"选择文件夹"对话框；移动端退到文档目录
  Future<Directory?> pickSaveDir() async {
    if (isDesktop) {
      final p = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择保存位置',
        lockParentWindow: true,
      );
      if (p == null) return null;
      return Directory(p);
    }
    return _mobileDir();
  }

  /// 下载单个媒体到指定路径（调用方先 pickSavePath）
  Future<File> downloadTo(MediaService service, String id, String savePath) async {
    final resp = await service.downloadRaw(id);
    final file = File(savePath);
    await file.writeAsBytes(resp.bodyBytes);
    final takenAt = resp.headers['x-taken-at'];
    if (takenAt != null) {
      final dt = DateTime.tryParse(takenAt);
      if (dt != null) {
        try { await file.setLastModified(dt); } catch (_) {}
      }
    }
    return file;
  }

  /// 从 content-disposition 解析原始文件名
  static String parseFilename(String? disposition, String fallback) {
    if (disposition == null) return fallback;
    final utf8 =
        RegExp(r"filename\*=UTF-8''([^;]+)", caseSensitive: false).firstMatch(disposition);
    if (utf8 != null) return Uri.decodeComponent(utf8.group(1)!);
    final m = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    if (m != null) return m.group(1)!;
    return fallback;
  }
}
