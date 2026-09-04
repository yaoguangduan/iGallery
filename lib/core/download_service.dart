import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'media_service.dart';
import 'platform.dart';

/// 统一下载：先弹"选择保存位置"对话框，再流式下载落盘（不把整个文件读进内存）。
/// - 桌面端：FilePicker.getDirectoryPath 选文件夹
/// - 移动端：退到应用文档目录下的 iGallery/
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

  /// 弹"选择文件夹"对话框；移动端退到文档目录。取消返回 null。
  Future<Directory?> pickSaveDir() async {
    if (isDesktop) {
      final p = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
      if (p == null) return null;
      return Directory(p);
    }
    return _mobileDir();
  }

  /// 单个媒体：选文件夹 → 流式下载 → 以原始文件名写入。
  /// 返回保存的完整路径；用户取消返回 null。
  Future<String?> downloadSingle(
    MediaService service,
    String id,
    String fallbackName,
  ) async {
    final dir = await pickSaveDir();
    if (dir == null) return null; // 用户取消

    final resp = await service.downloadStream(id);
    if (resp.statusCode != 200) {
      await resp.stream.drain();
      throw ApiException(ApiErrorKind.server, 'download ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    final name =
        parseContentDispositionFilename(resp.headers['content-disposition'], fallbackName);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    final sink = file.openWrite();
    await resp.stream.pipe(sink);
    await sink.close();

    final takenAt = resp.headers['x-taken-at'];
    if (takenAt != null) {
      final dt = DateTime.tryParse(takenAt);
      if (dt != null) {
        try { await file.setLastModified(dt); } catch (_) {}
      }
    }
    return file.path;
  }
}
