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
      return _saveDesktop(resp, name, takenAtHeader);
    }
    return _saveMobile(resp, name, takenAtHeader);
  }

  Future<String?> _saveDesktop(
    http.StreamedResponse resp,
    String name,
    String? takenAt,
  ) async {
    final dir = await pickSaveDir();
    if (dir == null) return null;
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    final sink = file.openWrite();
    await resp.stream.pipe(sink);
    await sink.close();
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
    await resp.stream.pipe(sink);
    await sink.close();
    _trySetMtime(tempFile, takenAt);

    try {
      final isVideo = _isVideoFile(name);
      final relPath = isVideo ? _videoRelPath : _imageRelPath;
      AssetEntity? asset;
      if (isVideo) {
        asset = await PhotoManager.editor.saveVideo(
          tempFile,
          title: name,
          relativePath: relPath,
        );
      } else {
        asset = await PhotoManager.editor.saveImageWithPath(
          tempFile.path,
          title: name,
          relativePath: relPath,
        );
      }
      await tempFile.delete().catchError((_) => tempFile);
      if (asset != null) {
        final saved = await asset.file;
        return saved?.path ?? name;
      }
      return name;
    } catch (_) {
      return tempFile.path;
    }
  }

  Future<void> saveToGallery(File file, String filename) async {
    if (isDesktop) return;
    try {
      final isVideo = _isVideoFile(filename);
      final relPath = isVideo ? _videoRelPath : _imageRelPath;
      if (isVideo) {
        await PhotoManager.editor.saveVideo(
          file,
          title: filename,
          relativePath: relPath,
        );
      } else {
        await PhotoManager.editor.saveImageWithPath(
          file.path,
          title: filename,
          relativePath: relPath,
        );
      }
    } catch (_) {}
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
