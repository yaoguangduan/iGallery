import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'download_service.dart';
import 'hash_sync.dart';
import 'mime.dart';
import 'server_state.dart';
import 'time_fmt.dart';

class MediaItem {
  final String id;
  final String filename;
  final String ext;
  final String mime;
  final String mediaType;
  final int size;
  final int? width;
  final int? height;
  final double? duration;
  final int? orientation;
  final String? takenAt;
  final String createdAt;
  final String updatedAt;
  final String? deletedAt;
  final String? checksum;
  final String? exifMake;
  final String? exifModel;
  final double? exifGpsLat;
  final double? exifGpsLng;
  final int favorite;
  final String tags;
  final String notes;
  final String? folderId;
  final int hasThumb;

  MediaItem({
    required this.id,
    required this.filename,
    required this.ext,
    required this.mime,
    required this.mediaType,
    required this.size,
    this.width,
    this.height,
    this.duration,
    this.orientation,
    this.takenAt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.checksum,
    this.exifMake,
    this.exifModel,
    this.exifGpsLat,
    this.exifGpsLng,
    this.favorite = 0,
    this.tags = '[]',
    this.notes = '',
    this.folderId,
    this.hasThumb = 1,
  });

  bool get isVideo => mediaType == 'video';
  bool get isImage => mediaType == 'image';
  bool get isFavorite => favorite == 1;
  String get displayDate => takenAt ?? createdAt;

  MediaItem copyWith({
    String? filename,
    int? favorite,
    String? tags,
    String? notes,
    String? folderId,
    bool clearFolderId = false,
  }) => MediaItem(
    id: id,
    filename: filename ?? this.filename,
    ext: ext,
    mime: mime,
    mediaType: mediaType,
    size: size,
    width: width,
    height: height,
    duration: duration,
    orientation: orientation,
    takenAt: takenAt,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    checksum: checksum,
    exifMake: exifMake,
    exifModel: exifModel,
    exifGpsLat: exifGpsLat,
    exifGpsLng: exifGpsLng,
    favorite: favorite ?? this.favorite,
    tags: tags ?? this.tags,
    notes: notes ?? this.notes,
    folderId: clearFolderId ? null : (folderId ?? this.folderId),
    hasThumb: hasThumb,
  );

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
    id: j['id'] as String,
    filename: j['filename'] as String,
    ext: j['ext'] as String? ?? '',
    mime: j['mime'] as String,
    mediaType: j['media_type'] as String? ?? 'image',
    size: (j['size'] as num).toInt(),
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
    duration: (j['duration'] as num?)?.toDouble(),
    orientation: (j['orientation'] as num?)?.toInt(),
    takenAt: j['taken_at'] as String?,
    createdAt: j['created_at'] as String,
    updatedAt: j['updated_at'] as String? ?? '',
    deletedAt: j['deleted_at'] as String?,
    checksum: j['checksum'] as String?,
    exifMake: j['exif_make'] as String?,
    exifModel: j['exif_model'] as String?,
    exifGpsLat: (j['exif_gps_lat'] as num?)?.toDouble(),
    exifGpsLng: (j['exif_gps_lng'] as num?)?.toDouble(),
    favorite: (j['favorite'] as num?)?.toInt() ?? 0,
    tags: j['tags'] as String? ?? '[]',
    notes: j['notes'] as String? ?? '',
    folderId: j['folder_id'] as String?,
    hasThumb: (j['has_thumb'] as num?)?.toInt() ?? 1,
  );
}

class QueryResult {
  final List<MediaItem> items;
  final String? nextCursor;
  final int? total;
  QueryResult({required this.items, this.nextCursor, this.total});
}

class UploadResult {
  final MediaItem item;
  final bool dedup;
  UploadResult({required this.item, required this.dedup});
}

/// 用户主动取消上传时抛出。UploadManager 据此把该项记为"已取消"而不是"失败"。
class UploadCancelledException implements Exception {
  const UploadCancelledException();
  @override
  String toString() => '已取消';
}

/// 上传取消令牌。一批共用一个：点"取消"后剩余文件全部停下。
class UploadCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) throw const UploadCancelledException();
  }
}

/// 逐个下载的结果统计，UI 据此如实汇报而不是一律"已下载 N 个"
class DownloadReport {
  final int ok;
  final int failed;
  const DownloadReport({required this.ok, required this.failed});
  int get total => ok + failed;
}

class FolderItem {
  final String id;
  final String name;
  final String? parentId;
  final String? coverId;
  final String? coverMediaType;
  final int itemCount;
  final bool hasPassword;
  final String createdAt;
  final String updatedAt;

  FolderItem({
    required this.id,
    required this.name,
    this.parentId,
    this.coverId,
    this.coverMediaType,
    required this.itemCount,
    this.hasPassword = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get coverIsVideo => coverMediaType == 'video';

  FolderItem copyWith({String? name, bool? hasPassword}) => FolderItem(
    id: id,
    name: name ?? this.name,
    parentId: parentId,
    coverId: coverId,
    coverMediaType: coverMediaType,
    itemCount: itemCount,
    hasPassword: hasPassword ?? this.hasPassword,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory FolderItem.fromJson(Map<String, dynamic> j) => FolderItem(
    id: j['id'] as String,
    name: j['name'] as String,
    parentId: j['parent_id'] as String?,
    coverId: j['cover_id'] as String?,
    coverMediaType: j['cover_media_type'] as String?,
    itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
    hasPassword: j['has_password'] == true,
    createdAt: j['created_at'] as String,
    updatedAt: j['updated_at'] as String? ?? '',
  );
}

class MediaService {
  final ServerState _state;
  MediaService(this._state);

  String get _base => _state.baseUrl;
  String thumbUrl(String id, {bool blur = false}) =>
      '$_base/v1/media/$id/thumb${blur ? '?blur=true' : ''}';
  String fullUrl(String id) => '$_base/v1/media/$id';
  Map<String, String> get authHeaders {
    final t = apiConfig.token;
    return (t != null && t.isNotEmpty) ? {'Authorization': 'Bearer $t'} : {};
  }

  /// cursor 分页优先；不传 cursor 视为首页
  Future<QueryResult> query({
    int size = 50,
    Map<String, dynamic>? filter,
    List<Map<String, String>>? sort,
    String? cursor,
    bool withTotal = false,
  }) async {
    final body = <String, dynamic>{'size': size, 'with_total': withTotal};
    if (filter != null) body['filter'] = filter;
    if (sort != null) body['sort'] = sort;
    if (cursor != null) body['cursor'] = cursor;

    final json =
        await Api.instance.postJson('/v1/media/query', body: body)
            as Map<String, dynamic>;
    final items = (json['items'] as List)
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return QueryResult(
      items: items,
      nextCursor: json['next_cursor'] as String?,
      total: (json['total'] as num?)?.toInt(),
    );
  }

  /// 秒传探测：命中则返回已存在的 MediaItem
  Future<MediaItem?> probe(String checksum) async {
    final json =
        await Api.instance.postJson(
              '/v1/media/probe',
              body: {'checksum': checksum},
            )
            as Map<String, dynamic>;
    if (json['exists'] == true) {
      return MediaItem.fromJson(json['item'] as Map<String, dynamic>);
    }
    return null;
  }

  /// 流式计算 XXH3-128，CPU 工作在后台 isolate。
  static Future<String> xxh128File(File file) => HashSync.computeFileHash(file);

  /// 单文件上传：返回 UploadResult（含 dedup）
  ///
  /// [onSent] 按字节回调已发送量，用于大文件进度条 —— 没有它的话，
  /// 传一个 2 GB 的视频时进度会在 0% 停十几分钟，和卡死没有区别。
  /// [cancelToken] 供用户中途取消；取消后底层连接直接断开，
  /// 服务端 stream_upload 检测到流中断会删掉半截文件、不写库。
  Future<UploadResult?> uploadFile(
    File file, {
    String? folderId,
    String? takenAtIso,
    void Function(int sent)? onSent,
    UploadCancelToken? cancelToken,
  }) async {
    final filename = file.path.split(Platform.pathSeparator).last;
    final size = await file.length();

    // 秒传探测（<= 4GB 才算 XXH3-128，与服务端 body limit 一致）。
    if (size < 4 * 1024 * 1024 * 1024) {
      try {
        final sum = await xxh128File(file);
        cancelToken?.throwIfCancelled();
        final existing = await probe(sum);
        if (existing != null) {
          return UploadResult(item: existing, dedup: true);
        }
      } on UploadCancelledException {
        rethrow;
      } catch (_) {
        // probe 失败不阻塞上传
      }
    }
    cancelToken?.throwIfCancelled();

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_base/v1/media/upload'),
    );
    request.headers.addAll(authHeaders);
    // taken_at = 权威拍摄时间（移动端从系统相册库读到），压过 EXIF。
    // file_mtime = 最弱兜底，只在 taken_at 和 EXIF 都拿不到时才被服务端采用。
    // 两者分开发，否则桌面端的 mtime 会盖掉本该胜出的 EXIF。
    //
    // fields 必须在 files 之前加：服务端按到达顺序读，晚于 file 的字段不生效。
    if (takenAtIso != null) {
      request.fields['taken_at'] = takenAtIso;
    }
    try {
      final stat = await file.stat();
      request.fields['file_mtime'] = toServerRfc3339(stat.modified);
    } catch (_) {}
    if (folderId != null) request.fields['folder_id'] = folderId;

    request.files.add(
      http.MultipartFile(
        'file',
        _countingStream(file.openRead(), onSent, cancelToken),
        size,
        filename: filename,
        contentType: guessMime(filename),
      ),
    );

    final response = await Api.instance.client.send(request);
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(
        response.statusCode == 401
            ? ApiErrorKind.unauthorized
            : ApiErrorKind.server,
        'upload ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final json = jsonDecode(body);
    // new response format: {items: [...], errors: [...]}
    if (json is Map<String, dynamic> && json.containsKey('items')) {
      final items = json['items'] as List;
      final errors = (json['errors'] as List?) ?? [];
      if (items.isEmpty && errors.isNotEmpty) {
        final e = errors.first as Map<String, dynamic>;
        final name = (e['filename'] as String?) ?? '';
        final msg = '${e['error']}';
        throw ApiException(
          ApiErrorKind.server,
          name.isEmpty ? msg : '$name: $msg',
        );
      }
      if (items.isEmpty) return null;
      final j = items.first as Map<String, dynamic>;
      return UploadResult(
        item: MediaItem.fromJson(j),
        dedup: j['dedup'] == true,
      );
    }
    // legacy: plain array response
    final list = json as List;
    if (list.isEmpty) return null;
    final j = list.first as Map<String, dynamic>;
    return UploadResult(item: MediaItem.fromJson(j), dedup: j['dedup'] == true);
  }

  /// 包一层文件流：边发边报字节数，并在取消时抛出中断上传。
  Stream<List<int>> _countingStream(
    Stream<List<int>> source,
    void Function(int sent)? onSent,
    UploadCancelToken? token,
  ) async* {
    var sent = 0;
    await for (final chunk in source) {
      token?.throwIfCancelled();
      sent += chunk.length;
      onSent?.call(sent);
      yield chunk;
    }
  }

  Future<UploadResult?> uploadBytes({
    required Uint8List bytes,
    required String filename,
    String? takenAt,
    String? folderId,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_base/v1/media/upload'),
    );
    request.headers.addAll(authHeaders);
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: guessMime(filename),
      ),
    );
    if (takenAt != null) request.fields['taken_at'] = takenAt;
    if (folderId != null) request.fields['folder_id'] = folderId;
    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw ApiException(
        ApiErrorKind.server,
        'upload ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final list = jsonDecode(body) as List;
    if (list.isEmpty) return null;
    final j = list.first as Map<String, dynamic>;
    return UploadResult(item: MediaItem.fromJson(j), dedup: j['dedup'] == true);
  }

  Future<Uint8List> downloadBytes(String id) async {
    // 先查缓存
    // 注：cachedMediaSync 在 DiskCache 里，避免耦合，这里直接走 http
    final resp = await Api.instance.client.get(
      Uri.parse('$_base/v1/media/$id'),
      headers: authHeaders,
    );
    if (resp.statusCode != 200) {
      throw ApiException(ApiErrorKind.server, 'download ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  Future<void> delete(String id) => Api.instance.delete('/v1/media/$id');

  Future<void> batchDelete(List<String> ids) =>
      Api.instance.postJson('/v1/media/batch-delete', body: {'ids': ids});

  Future<void> restore(String id) =>
      Api.instance.postJson('/v1/media/$id/restore');

  /// PATCH 返回更新后的完整 MediaItem
  Future<MediaItem?> updateFields(
    String id,
    Map<String, dynamic> fields,
  ) async {
    final json = await Api.instance.patchJson('/v1/media/$id', body: fields);
    if (json == null) return null;
    return MediaItem.fromJson(json as Map<String, dynamic>);
  }

  /// 单个文件的流式下载响应（不缓存到内存，供逐块落盘）。
  /// 头部（含 content-disposition）在读 body 前即可拿到。
  Future<http.StreamedResponse> downloadStream(String id) {
    final req = http.Request('GET', Uri.parse('$_base/v1/media/$id/download'));
    req.headers.addAll(authHeaders);
    return Api.instance.client.send(req);
  }

  Future<File> downloadBatch(
    List<String> ids, {
    required String savePath,
  }) async {
    final request = http.Request('POST', Uri.parse('$_base/v1/media/download'));
    request.headers['Content-Type'] = 'application/json';
    request.headers.addAll(authHeaders);
    request.body = jsonEncode({'ids': ids});

    final response = await Api.instance.client.send(request);
    if (response.statusCode != 200) {
      await response.stream.drain();
      throw ApiException(
        ApiErrorKind.server,
        'zip ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final file = File(savePath);
    final sink = file.openWrite();
    try {
      await response.stream.pipe(sink);
    } catch (e) {
      // 传到一半断了：删掉半截 zip，别让用户拿到一个打不开的包
      await sink.close().catchError((_) {});
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    }
    await sink.close();
    return file;
  }

  Future<DownloadReport> downloadIndividual(
    List<String> ids, {
    required String saveDir,
    void Function(int completed, int total)? onProgress,
  }) async {
    var ok = 0, failed = 0;
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      try {
        final resp = await downloadStream(id);
        if (resp.statusCode == 200) {
          final filename = parseContentDispositionFilename(
            resp.headers['content-disposition'],
            id,
          );
          final file = uniqueFile(saveDir, filename);
          final sink = file.openWrite();
          try {
            await resp.stream.pipe(sink);
          } catch (e) {
            // 写到一半断了：删掉半截文件，不留下打不开的残骸
            await sink.close().catchError((_) {});
            try {
              await file.delete();
            } catch (_) {}
            rethrow;
          }
          await sink.close();
          final takenAt = resp.headers['x-taken-at'];
          if (takenAt != null) {
            final dt = DateTime.tryParse(takenAt);
            if (dt != null) {
              try {
                await file.setLastModified(dt);
              } catch (_) {}
            }
          }
          await DownloadService.instance.saveToGallery(file, filename);
          ok++;
        } else {
          await resp.stream.drain();
          failed++;
        }
      } catch (_) {
        // 单个失败不中断整批，但要计数 —— 旧实现全吞掉，
        // 5 个挂 2 个也照样提示"已下载 5 个"
        failed++;
      }
      onProgress?.call(i + 1, ids.length);
    }
    return DownloadReport(ok: ok, failed: failed);
  }

  Future<ServerStats> fetchInfo() async {
    final json = await Api.instance.getJson('/v1/info') as Map<String, dynamic>;
    return ServerStats.fromJson(json);
  }

  // ── Folders ──

  Future<List<FolderItem>> listFolders({String? parentId}) async {
    final list =
        await Api.instance.getJson(
              '/v1/folders',
              query: parentId != null ? {'parent_id': parentId} : null,
            )
            as List;
    return list
        .map((e) => FolderItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<FolderItem> createFolder({
    required String name,
    String? parentId,
  }) async {
    final json =
        await Api.instance.postJson(
              '/v1/folders',
              body: {'name': name, if (parentId != null) 'parent_id': parentId},
            )
            as Map<String, dynamic>;
    return FolderItem.fromJson(json);
  }

  Future<void> renameFolder(String id, String name) =>
      Api.instance.patchJson('/v1/folders/$id', body: {'name': name});

  Future<void> moveFolder(String id, {String? parentId}) => Api.instance
      .patchJson('/v1/folders/$id', body: {'parent_id': parentId ?? ''});

  Future<void> deleteFolder(String id) =>
      Api.instance.delete('/v1/folders/$id');

  Future<void> setFolderPassword(String id, String? password) =>
      Api.instance.patchJson('/v1/folders/$id', body: {'password': password ?? ''});

  Future<bool> unlockFolder(String id, String password) async {
    try {
      await Api.instance.postJson(
        '/v1/folders/$id/unlock',
        body: {'password': password},
      );
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 401) return false;
      rethrow;
    }
  }

  Future<int> batchMove(List<String> ids, {String? folderId}) async {
    final json =
        await Api.instance.postJson(
              '/v1/media/batch-move',
              body: {'ids': ids, 'folder_id': folderId},
            )
            as Map<String, dynamic>;
    return (json['moved'] as num?)?.toInt() ?? 0;
  }

  Future<int> batchFavorite(List<String> ids, {required bool favorite}) async {
    final json =
        await Api.instance.postJson(
              '/v1/media/batch-favorite',
              body: {'ids': ids, 'favorite': favorite},
            )
            as Map<String, dynamic>;
    return (json['updated'] as num?)?.toInt() ?? 0;
  }
}

/// 从 content-disposition 解析原始文件名（支持 RFC 5987 filename*）
String parseContentDispositionFilename(String? disposition, String fallback) {
  if (disposition == null) return fallback;
  final utf8 = RegExp(
    r"filename\*=UTF-8''([^;]+)",
    caseSensitive: false,
  ).firstMatch(disposition);
  if (utf8 != null) return Uri.decodeComponent(utf8.group(1)!);
  final m = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
  if (m != null) return m.group(1)!;
  return fallback;
}

/// 目标目录里取一个不冲突的文件名：`a.jpg` 已存在就用 `a (1).jpg`。
///
/// 直接覆盖是"静默毁数据"：用户下载两张同名照片，第二张会把第一张盖掉，
/// 而且全程没有任何提示。系统下载器都是这个 `(n)` 规则。
File uniqueFile(String dir, String filename) {
  final sep = Platform.pathSeparator;
  var candidate = File('$dir$sep$filename');
  if (!candidate.existsSync()) return candidate;

  final dot = filename.lastIndexOf('.');
  final stem = dot > 0 ? filename.substring(0, dot) : filename;
  final ext = dot > 0 ? filename.substring(dot) : '';
  for (var n = 1; n < 1000; n++) {
    candidate = File('$dir$sep$stem ($n)$ext');
    if (!candidate.existsSync()) return candidate;
  }
  // 1000 个重名还没排开，用时间戳兜底，总之不覆盖
  return File('$dir$sep$stem ${DateTime.now().millisecondsSinceEpoch}$ext');
}
