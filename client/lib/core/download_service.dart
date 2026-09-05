import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'api.dart';
import 'media_service.dart';
import 'platform.dart';

/// 统一下载服务。
/// - 桌面端：弹文件夹选择器 → 流式写入 → 返回路径
/// - 移动端：流式写到临时目录 → 通过 MediaStore 存入系统相册的 iGallery 目录
///   （类似微信的 WeiXin 目录，系统图库能扫到）
class DownloadService {
  static final DownloadService instance = DownloadService._();
  DownloadService._();

  static const _imageRelPath = 'Pictures/iGallery';
  static const _videoRelPath = 'Movies/iGallery';

  static final _videoExts = {
    '.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v', '.3gp', '.flv',
  };

  static bool _isVideoFile(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0) return false;
    return _videoExts.contains(filename.substring(dot).toLowerCase());
  }

  Future<Directory?> pickSaveDir() async {
    if (isDesktop) {
      final p = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
      if (p == null) return null;
      return Directory(p);
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/igallery_dl');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String?> downloadSingle(
    MediaService service,
    String id,
    String fallbackName,
  ) async {
    // 桌面：先选保存位置再发请求（§3.3）。旧写法先开下载流再弹对话框——
    // 对话框停在那儿时流一直挂着，用户取消时流没被 drain，白泄漏一个连接。
    Directory? desktopDir;
    if (isDesktop) {
      desktopDir = await pickSaveDir();
      if (desktopDir == null) return null; // 用户取消，此时还没开流
    }
    final resp = await service.downloadStream(id);
    if (resp.statusCode != 200) {
      await resp.stream.drain();
      throw ApiException(
        ApiErrorKind.server,
        'download ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }
    final name = parseContentDispositionFilename(
      resp.headers['content-disposition'],
      fallbackName,
    );
    final takenAtHeader = resp.headers['x-taken-at'];

    if (isDesktop) {
      return _saveDesktop(resp, name, takenAtHeader, desktopDir!);
    }
    return _saveMobile(resp, name, takenAtHeader);
  }

  Future<String?> _saveDesktop(
    http.StreamedResponse resp,
    String name,
    String? takenAt,
    Directory dir,
  ) async {
    // uniqueFile：同名不同文件时自动改名，绝不静默覆盖毁掉用户已有的文件。
    final file = uniqueFile(dir.path, name);
    final sink = file.openWrite();
    try {
      await resp.stream.pipe(sink); // pipe 成功时会替你关掉 sink
    } catch (e) {
      // 中途断流：关掉 sink、删掉半截文件，不留打不开的残骸
      await sink.close().catchError((_) {});
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    }
    _trySetMtime(file, takenAt);
    return file.path;
  }

  Future<String?> _saveMobile(
    http.StreamedResponse resp,
    String name,
    String? takenAt,
  ) async {
    final tmp = await getTemporaryDirectory();
    final tempFile = File('${tmp.path}/igallery_dl/$name');
    final parent = tempFile.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final sink = tempFile.openWrite();
    try {
      await resp.stream.pipe(sink); // pipe 成功时会替你关掉 sink
    } catch (e) {
      // 中途断流：关 sink、删半截文件、上抛（调用方显示"下载失败"）
      await sink.close().catchError((_) {});
      try {
        await tempFile.delete();
      } catch (_) {}
      rethrow;
    }
    _trySetMtime(tempFile, takenAt);

    // 存进系统相册；temp 只是暂存，无论成败都在 finally 里清掉，不残留。
    // 存相册失败就如实上抛，绝不"文件落在看不见的 temp 却报成功"。
    try {
      final isVideo = _isVideoFile(name);
      final relPath = isVideo ? _videoRelPath : _imageRelPath;
      final asset = isVideo
          ? await PhotoManager.editor.saveVideo(
              tempFile, title: name, relativePath: relPath)
          : await PhotoManager.editor.saveImageWithPath(
              tempFile.path, title: name, relativePath: relPath);
      if (asset == null) throw Exception('存入系统相册失败');
      final saved = await asset.file;
      return saved?.path ?? name;
    } finally {
      await tempFile.delete().catchError((_) => tempFile);
    }
  }

  /// 把文件存进系统相册，返回是否成功（桌面端无相册概念，恒 true）。
  /// 调用方据此如实计数，不再"存失败也报已保存 N 个"。
  Future<bool> saveToGallery(File file, String filename) async {
    if (isDesktop) return true;
    try {
      final isVideo = _isVideoFile(filename);
      final relPath = isVideo ? _videoRelPath : _imageRelPath;
      final asset = isVideo
          ? await PhotoManager.editor.saveVideo(
              file, title: filename, relativePath: relPath)
          : await PhotoManager.editor.saveImageWithPath(
              file.path, title: filename, relativePath: relPath);
      return asset != null;
    } catch (_) {
      return false;
    }
  }

  /// zip 等非媒体成品的最终保存目录：桌面弹选择器；移动端用应用文档 iGallery/
  /// （§3.3 认可的位置，稳定可寻，绝不写进看不见的 temp）。
  Future<Directory?> pickDocumentDir() async {
    if (isDesktop) {
      final p = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
      if (p == null) return null;
      return Directory(p);
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}iGallery');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }


  void _trySetMtime(File file, String? takenAt) {
    if (takenAt == null) return;
    final dt = DateTime.tryParse(takenAt);
    if (dt != null) {
      try {
        file.setLastModifiedSync(dt);
      } catch (_) {}
    }
  }
}
